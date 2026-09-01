const std = @import("std");
const job_mod = @import("job.zig");

pub const AutomaticStart = struct {
    selection: job_mod.Selection,
    delivery: job_mod.Delivery,
};

pub const LockedJob = struct {
    job: *job_mod.Job,

    pub fn unlock(locked: LockedJob) void {
        locked.job.unlock();
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_root: []u8,
    jobs_root: []u8,
    quarantine_root: []u8,
    slots: []?*job_mod.Job,
    mutex: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, data_root: []const u8, capacity: usize) !Registry {
        if (capacity == 0 or capacity > 4096) return error.InvalidRegistryCapacity;
        const owned_root = try allocator.dupe(u8, data_root);
        errdefer allocator.free(owned_root);
        const jobs_root = try std.fs.path.join(allocator, &.{ data_root, "jobs" });
        errdefer allocator.free(jobs_root);
        const quarantine_root = try std.fs.path.join(allocator, &.{ data_root, "quarantine" });
        errdefer allocator.free(quarantine_root);
        try std.Io.Dir.cwd().createDirPath(io, jobs_root);
        try std.Io.Dir.cwd().createDirPath(io, quarantine_root);
        const slots = try allocator.alloc(?*job_mod.Job, capacity);
        errdefer allocator.free(slots);
        @memset(slots, null);
        var registry = Registry{
            .allocator = allocator,
            .io = io,
            .data_root = owned_root,
            .jobs_root = jobs_root,
            .quarantine_root = quarantine_root,
            .slots = slots,
        };
        try registry.scan();
        return registry;
    }

    pub fn deinit(registry: *Registry) void {
        for (registry.slots) |slot| if (slot) |job| job.release();
        registry.allocator.free(registry.slots);
        registry.allocator.free(registry.quarantine_root);
        registry.allocator.free(registry.jobs_root);
        registry.allocator.free(registry.data_root);
    }

    pub fn storageBytes(registry: *Registry) !u64 {
        var total: u64 = 0;
        inline for (.{ registry.jobs_root, registry.quarantine_root }) |root_path| {
            var root = try std.Io.Dir.cwd().openDir(registry.io, root_path, .{ .iterate = true, .follow_symlinks = false });
            defer root.close(registry.io);
            var walker = try root.walk(registry.allocator);
            defer walker.deinit();
            while (try walker.next(registry.io)) |entry| {
                if (entry.kind == .directory and entry.depth() >= 8) {
                    walker.leave(registry.io);
                    continue;
                }
                if (entry.kind != .file) continue;
                const stat = try entry.dir.statFile(registry.io, entry.basename, .{ .follow_symlinks = false });
                total = std.math.add(u64, total, stat.size) catch return error.StorageSizeOverflow;
            }
        }
        return total;
    }

    pub fn create(registry: *Registry, source_url: []const u8, intent: job_mod.Intent, now: i64) !*job_mod.Job {
        var random: [job_mod.id_bytes]u8 = undefined;
        try registry.io.randomSecure(&random);
        const id = std.fmt.bytesToHex(random, .lower);

        registry.lock();
        const slot_index = for (registry.slots, 0..) |slot, index| {
            if (slot == null) break index;
        } else {
            registry.unlock();
            return error.RegistryFull;
        };
        for (registry.slots) |slot| if (slot) |existing| {
            if (std.mem.eql(u8, existing.data.id, &id)) {
                registry.unlock();
                return error.RandomIdCollision;
            }
        };
        const job = job_mod.Job.create(registry.allocator, &id, source_url, intent, now) catch |err| {
            registry.unlock();
            return err;
        };
        registry.slots[slot_index] = job;
        registry.unlock();
        errdefer {
            registry.lock();
            registry.slots[slot_index] = null;
            registry.unlock();
            job.release();
        }

        const directory = try registry.jobPath(registry.allocator, job.data.id, "");
        defer registry.allocator.free(directory);
        errdefer std.Io.Dir.cwd().deleteTree(registry.io, directory) catch {};
        try std.Io.Dir.cwd().createDirPath(registry.io, directory);
        inline for (.{ "source", "output", "work" }) |child| {
            const path = try registry.jobPath(registry.allocator, job.data.id, child);
            defer registry.allocator.free(path);
            try std.Io.Dir.cwd().createDirPath(registry.io, path);
        }
        job.lock();
        defer job.unlock();
        try registry.persistLocked(job);
        return job;
    }

    pub fn findLocked(registry: *Registry, id: []const u8) ?LockedJob {
        if (!job_mod.validId(id)) return null;
        registry.lock();
        defer registry.unlock();
        for (registry.slots) |slot| if (slot) |job| {
            if (std.mem.eql(u8, job.data.id, id)) {
                job.lock();
                return .{ .job = job };
            }
        };
        return null;
    }

    pub fn retain(registry: *Registry, id: []const u8) ?*job_mod.Job {
        if (!job_mod.validId(id)) return null;
        registry.lock();
        defer registry.unlock();
        for (registry.slots) |slot| if (slot) |job| {
            if (std.mem.eql(u8, job.data.id, id)) {
                job.retain();
                return job;
            }
        };
        return null;
    }

    pub fn snapshot(registry: *Registry, allocator: std.mem.Allocator, id: []const u8) !?job_mod.Snapshot {
        const locked = registry.findLocked(id) orelse return null;
        defer locked.unlock();
        return try locked.job.snapshot(allocator);
    }

    pub fn transition(registry: *Registry, id: []const u8, next: job_mod.State, now: i64, terminal_ttl_seconds: i64) !bool {
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        try locked.job.transition(next, now, terminal_ttl_seconds);
        try registry.persistLocked(locked.job);
        return true;
    }

    pub fn completeProbe(registry: *Registry, id: []const u8, probe: job_mod.Probe, automatic_start: ?AutomaticStart, now: i64) !bool {
        try job_mod.validateProbe(probe);
        if (automatic_start) |start| try job_mod.validateStart(probe, start.selection, start.delivery);
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        const job = locked.job;
        if (job.data.state != .probing) return false;
        job.data.probe = try job_mod.cloneProbe(job.arena.allocator(), probe);
        if (automatic_start) |start| {
            job.data.selection = try job_mod.cloneSelection(job.arena.allocator(), start.selection);
            job.data.delivery = start.delivery;
            try job.transition(.queued, now, 0);
            job.progress = .{ .phase = .queued, .label = "Queued", .updated_at = now };
        } else {
            try job.transition(.awaiting_choice, now, 0);
            job.progress = .{ .phase = .probing, .label = "Ready for your choice", .updated_at = now };
        }
        try registry.persistLocked(job);
        return true;
    }

    pub fn beginAcquisition(registry: *Registry, id: []const u8, now: i64) !bool {
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        const job = locked.job;
        if (job.data.state == .acquiring) return true;
        if (job.data.state != .queued) return false;
        try job.transition(.acquiring, now, 0);
        job.progress = .{ .phase = .source_download, .label = "Starting download", .attempt = job.progress.attempt + 1, .updated_at = now };
        try registry.persistLocked(job);
        return true;
    }

    pub fn updateProgress(registry: *Registry, id: []const u8, progress: job_mod.Progress) bool {
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        if (locked.job.data.state != .acquiring and locked.job.data.state != .preparing) return false;
        locked.job.progress = progress;
        locked.job.revision +%= 1;
        return true;
    }

    pub fn finishAcquisition(registry: *Registry, id: []const u8, artifacts: []const job_mod.Artifact, output_artifacts: []const job_mod.Artifact, now: i64, terminal_ttl_seconds: i64) !bool {
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        const job = locked.job;
        if (job.data.state != .acquiring) return false;
        job.data.source_artifacts = try job_mod.cloneArtifacts(job.arena.allocator(), artifacts);
        job.data.output_artifacts = try job_mod.cloneArtifacts(job.arena.allocator(), output_artifacts);
        const delivery = job.data.delivery orelse return error.MissingDelivery;
        if (delivery.mode == .original) {
            try job.transition(.ready, now, terminal_ttl_seconds);
            job.progress = .{ .phase = .ready, .label = "Ready", .fraction = 1, .updated_at = now };
        } else {
            try job.transition(.preparing, now, 0);
            job.progress = .{ .phase = .source_probe, .label = "Source ready", .fraction = 1, .updated_at = now };
        }
        try registry.persistLocked(job);
        return true;
    }

    pub fn beginPreparation(registry: *Registry, id: []const u8, now: i64) !bool {
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        const job = locked.job;
        if (job.data.state != .preparing or job.data.source_artifacts.len == 0) return false;
        const delivery = job.data.delivery orelse return error.MissingDelivery;
        if (delivery.mode == .original) return false;
        job.cancel_requested.store(false, .release);
        job.data.updated_at = now;
        job.progress = .{
            .phase = .source_probe,
            .label = "Inspecting downloaded media",
            .attempt = job.progress.attempt + 1,
            .updated_at = now,
        };
        job.revision +%= 1;
        try registry.persistLocked(job);
        return true;
    }

    pub fn finishPreparation(registry: *Registry, id: []const u8, artifacts: []const job_mod.Artifact, now: i64, terminal_ttl_seconds: i64) !bool {
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        const job = locked.job;
        if (job.data.state != .preparing) return false;
        job.data.output_artifacts = try job_mod.cloneArtifacts(job.arena.allocator(), artifacts);
        try job.transition(.ready, now, terminal_ttl_seconds);
        job.progress = .{ .phase = .ready, .label = "Ready", .fraction = 1, .updated_at = now };
        try registry.persistLocked(job);
        return true;
    }

    pub fn discardSourcesAfterPreparation(registry: *Registry, id: []const u8, now: i64) !bool {
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        const job = locked.job;
        if (job.data.state != .ready or job.data.output_artifacts.len == 0 or job.data.source_artifacts.len == 0) return false;
        job.data.source_artifacts = &.{};
        job.data.updated_at = now;
        job.revision +%= 1;
        try registry.persistLocked(job);
        return true;
    }

    pub fn fallbackToOriginal(registry: *Registry, id: []const u8, warning: []const u8, now: i64, terminal_ttl_seconds: i64) !bool {
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        const job = locked.job;
        if (job.data.state != .preparing or job.data.source_artifacts.len == 0) return false;
        const allocator = job.arena.allocator();
        job.data.delivery = .{ .mode = .original };
        job.data.output_artifacts = &.{};
        job.data.warning = try allocator.dupe(u8, warning);
        try job.transition(.ready, now, terminal_ttl_seconds);
        job.progress = .{ .phase = .ready, .label = "Ready with original", .fraction = 1, .updated_at = now };
        try registry.persistLocked(job);
        return true;
    }

    pub fn useOriginal(registry: *Registry, id: []const u8, now: i64, terminal_ttl_seconds: i64) !bool {
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        const job = locked.job;
        if (job.data.state == .ready and job.data.delivery != null and job.data.delivery.?.mode == .original) return true;
        if (job.data.state != .preparing or job.data.source_artifacts.len == 0) return error.OriginalUnavailable;
        job.cancel_requested.store(true, .release);
        job.data.delivery = .{ .mode = .original };
        job.data.output_artifacts = &.{};
        try job.transition(.ready, now, terminal_ttl_seconds);
        job.progress = .{ .phase = .ready, .label = "Ready with original", .fraction = 1, .updated_at = now };
        try registry.persistLocked(job);
        return true;
    }

    pub fn fail(registry: *Registry, id: []const u8, code: []const u8, message: []const u8, now: i64, terminal_ttl_seconds: i64) !bool {
        const locked = registry.findLocked(id) orelse return false;
        defer locked.unlock();
        const job = locked.job;
        if (job.data.state != .probing and job.data.state != .acquiring) return false;
        const allocator = job.arena.allocator();
        job.data.failure = .{
            .code = try allocator.dupe(u8, code),
            .message = try allocator.dupe(u8, message),
        };
        try job.transition(.failed, now, terminal_ttl_seconds);
        job.progress = .{ .phase = .ready, .label = "Failed", .updated_at = now };
        try registry.persistLocked(job);
        return true;
    }

    pub fn idsInState(registry: *Registry, allocator: std.mem.Allocator, state: job_mod.State) ![][job_mod.id_length]u8 {
        var ids: std.ArrayList([job_mod.id_length]u8) = .empty;
        defer ids.deinit(allocator);
        registry.lock();
        defer registry.unlock();
        for (registry.slots) |slot| if (slot) |job| {
            job.lock();
            if (job.data.state == state) {
                var id: [job_mod.id_length]u8 = undefined;
                @memcpy(&id, job.data.id);
                job.unlock();
                try ids.append(allocator, id);
            } else {
                job.unlock();
            }
        };
        return try ids.toOwnedSlice(allocator);
    }

    pub fn persistLocked(registry: *Registry, job: *job_mod.Job) !void {
        try job_mod.validateData(job.data, job.data.id);
        const temporary = try registry.jobPath(registry.allocator, job.data.id, "job.json.tmp");
        defer registry.allocator.free(temporary);
        const destination = try registry.jobPath(registry.allocator, job.data.id, "job.json");
        defer registry.allocator.free(destination);
        std.Io.Dir.cwd().deleteFile(registry.io, temporary) catch {};
        errdefer std.Io.Dir.cwd().deleteFile(registry.io, temporary) catch {};
        const file = try std.Io.Dir.cwd().createFile(registry.io, temporary, .{
            .read = true,
            .exclusive = true,
            .permissions = @fromBackingInt(@intCast(0o600)),
        });
        defer file.close(registry.io);
        var buffer: [16 * 1024]u8 = undefined;
        var writer = file.writer(registry.io, &buffer);
        try std.json.Stringify.value(job.data, .{ .whitespace = .indent_2 }, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.flush();
        try file.sync(registry.io);
        try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), destination, registry.io);
    }

    pub fn delete(registry: *Registry, id: []const u8) !bool {
        if (!job_mod.validId(id)) return false;
        registry.lock();
        var removed: ?*job_mod.Job = null;
        for (registry.slots) |*slot| if (slot.*) |job| {
            if (std.mem.eql(u8, job.data.id, id)) {
                job.lock();
                if (job.references.load(.acquire) != 1) {
                    job.unlock();
                    registry.unlock();
                    return error.JobBusy;
                }
                removed = job;
                slot.* = null;
                break;
            }
        };
        registry.unlock();
        const job = removed orelse return false;
        job.cancel_requested.store(true, .release);
        const directory = try registry.jobPath(registry.allocator, id, "");
        defer registry.allocator.free(directory);
        std.Io.Dir.cwd().deleteTree(registry.io, directory) catch |err| {
            job.unlock();
            job.release();
            return err;
        };
        job.unlock();
        job.release();
        return true;
    }

    pub fn jobDirectoryAbsent(registry: *Registry, id: []const u8) !bool {
        if (!job_mod.validId(id)) return error.InvalidJobId;
        const directory = try registry.jobPath(registry.allocator, id, "");
        defer registry.allocator.free(directory);
        _ = std.Io.Dir.cwd().statFile(registry.io, directory, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => return err,
        };
        return false;
    }

    pub fn pruneExpired(registry: *Registry, now: i64) !usize {
        var deleted: usize = 0;
        while (true) {
            var expired_id: ?[job_mod.id_length]u8 = null;
            registry.lock();
            for (registry.slots) |slot| if (slot) |job| {
                job.lock();
                const due = job.data.expires_at != null and job.data.expires_at.? <= now;
                if (due) {
                    var id: [job_mod.id_length]u8 = undefined;
                    @memcpy(&id, job.data.id);
                    expired_id = id;
                    job.unlock();
                    break;
                }
                job.unlock();
            };
            registry.unlock();
            const id = expired_id orelse break;
            if (try registry.delete(&id)) deleted += 1;
        }
        return deleted;
    }

    fn scan(registry: *Registry) !void {
        var directory = try std.Io.Dir.cwd().openDir(registry.io, registry.jobs_root, .{ .iterate = true });
        defer directory.close(registry.io);
        var iterator = directory.iterate();
        while (try iterator.next(registry.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (!job_mod.validId(entry.name)) {
                try registry.quarantine(entry.name);
                continue;
            }
            const slot_index = for (registry.slots, 0..) |slot, index| {
                if (slot == null) break index;
            } else return error.RegistryFull;
            const loaded = registry.load(entry.name) catch {
                try registry.quarantine(entry.name);
                continue;
            };
            registry.slots[slot_index] = loaded;
        }
    }

    fn load(registry: *Registry, id: []const u8) !*job_mod.Job {
        var arena = std.heap.ArenaAllocator.init(registry.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const path = try registry.jobPath(allocator, id, "job.json");
        const bytes = try std.Io.Dir.cwd().readFileAlloc(registry.io, path, allocator, .limited(512 * 1024));
        var data = try std.json.parseFromSliceLeaky(job_mod.Data, allocator, bytes, .{ .ignore_unknown_fields = false });
        try job_mod.validateData(data, id);
        var reacquire = false;
        for (data.source_artifacts) |artifact| registry.verifyArtifact(allocator, id, artifact) catch {
            if (data.state != .preparing) return error.ArtifactMismatch;
            reacquire = true;
            break;
        };
        if (reacquire) {
            data.state = .acquiring;
            data.source_artifacts = &.{};
            data.output_artifacts = &.{};
            data.expires_at = null;
        } else {
            for (data.output_artifacts) |artifact| try registry.verifyArtifact(allocator, id, artifact);
        }
        const job = try job_mod.Job.fromParsed(registry.allocator, arena, data);
        errdefer job.release();
        if (reacquire) {
            job.lock();
            defer job.unlock();
            try registry.persistLocked(job);
        }
        return job;
    }

    fn verifyArtifact(registry: *Registry, allocator: std.mem.Allocator, id: []const u8, artifact: job_mod.Artifact) !void {
        const artifact_path = try registry.jobPath(allocator, id, artifact.path);
        const stat = try std.Io.Dir.cwd().statFile(registry.io, artifact_path, .{ .follow_symlinks = false });
        if (stat.kind != .file or stat.size != artifact.size_bytes) return error.ArtifactMismatch;
    }

    fn quarantine(registry: *Registry, name: []const u8) !void {
        var suffix: [8]u8 = undefined;
        registry.io.random(&suffix);
        const suffix_hex = std.fmt.bytesToHex(suffix, .lower);
        const source = try std.fs.path.join(registry.allocator, &.{ registry.jobs_root, name });
        defer registry.allocator.free(source);
        const destination_name = try std.fmt.allocPrint(registry.allocator, "{s}-{s}", .{ name, &suffix_hex });
        defer registry.allocator.free(destination_name);
        const destination = try std.fs.path.join(registry.allocator, &.{ registry.quarantine_root, destination_name });
        defer registry.allocator.free(destination);
        try std.Io.Dir.cwd().rename(source, std.Io.Dir.cwd(), destination, registry.io);
    }

    fn jobPath(registry: *Registry, allocator: std.mem.Allocator, id: []const u8, child: []const u8) ![]u8 {
        return if (child.len == 0)
            std.fs.path.join(allocator, &.{ registry.jobs_root, id })
        else
            std.fs.path.join(allocator, &.{ registry.jobs_root, id, child });
    }

    pub fn jobPathAlloc(registry: *Registry, allocator: std.mem.Allocator, id: []const u8, child: []const u8) ![]u8 {
        if (!job_mod.validId(id)) return error.InvalidJobId;
        if (child.len > 0 and !job_mod.validRelativePath(child)) return error.InvalidRelativePath;
        return registry.jobPath(allocator, id, child);
    }

    fn lock(registry: *Registry) void {
        while (registry.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(registry: *Registry) void {
        registry.mutex.store(false, .release);
    }
};

test "terminal expiry deletes the complete job directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", temporary.sub_path[0..], "expiry-data" });
    defer allocator.free(root);
    var registry = try Registry.init(allocator, io, root, 4);
    defer registry.deinit();
    const created = try registry.create("https://example.com/media", .inspect, 1_800_000_000);
    var id: [job_mod.id_length]u8 = undefined;
    @memcpy(&id, created.data.id);
    try std.testing.expect(try registry.transition(&id, .failed, 1_800_000_001, 10));
    try std.testing.expectEqual(@as(usize, 0), try registry.pruneExpired(1_800_000_010));
    try std.testing.expectEqual(@as(usize, 1), try registry.pruneExpired(1_800_000_011));
    try std.testing.expect((try registry.snapshot(allocator, &id)) == null);
}

test "active work prevents job deletion" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", temporary.sub_path[0..], "active-data" });
    defer allocator.free(root);
    var registry = try Registry.init(allocator, io, root, 4);
    defer registry.deinit();
    const created = try registry.create("https://example.com/media", .inspect, 1_800_000_000);
    var id: [job_mod.id_length]u8 = undefined;
    @memcpy(&id, created.data.id);
    created.retain();
    try std.testing.expectError(error.JobBusy, registry.delete(&id));
    created.release();
    try std.testing.expect(try registry.delete(&id));
}

test "deletion succeeds when prior cleanup already removed the job directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", temporary.sub_path[0..], "already-absent-data" });
    defer allocator.free(root);
    var registry = try Registry.init(allocator, io, root, 4);
    defer registry.deinit();
    const created = try registry.create("https://example.com/media", .inspect, 1_800_000_000);
    var id: [job_mod.id_length]u8 = undefined;
    @memcpy(&id, created.data.id);
    const directory = try registry.jobPath(allocator, &id, "");
    defer allocator.free(directory);
    try std.Io.Dir.cwd().deleteTree(io, directory);
    try std.testing.expect(try registry.jobDirectoryAbsent(&id));
    try std.testing.expect(try registry.delete(&id));
    try std.testing.expect(!(try registry.delete(&id)));
}

test "probe and automatic Original selection commit directly to queued" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", temporary.sub_path[0..], "automatic-data" });
    defer allocator.free(root);
    var registry = try Registry.init(allocator, io, root, 4);
    defer registry.deinit();
    const created = try registry.create("https://example.com/media", .save_original, 1_800_000_000);
    var id: [job_mod.id_length]u8 = undefined;
    @memcpy(&id, created.data.id);
    const variants = [_]job_mod.Variant{.{ .id = "best", .label = "Best" }};
    const probe = job_mod.Probe{
        .engine = .ytdlp,
        .title = "Video",
        .source_host = "example.com",
        .media_kind = .video,
        .variants = &variants,
        .video_count = 1,
    };
    try std.testing.expect(try registry.completeProbe(&id, probe, .{
        .selection = .{ .kind = .video, .variant_id = "best", .label = "Best original video" },
        .delivery = .{ .mode = .original },
    }, 1_800_000_001));
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const snapshot = (try registry.snapshot(arena_state.allocator(), &id)).?;
    try std.testing.expectEqual(job_mod.State.queued, snapshot.data.state);
    try std.testing.expectEqual(job_mod.Intent.save_original, snapshot.data.intent);
    try std.testing.expectEqualStrings("best", snapshot.data.selection.?.variant_id.?);
    try std.testing.expectEqual(job_mod.DeliveryMode.original, snapshot.data.delivery.?.mode);
}

test "manifest v1 directories are quarantined on scan" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", temporary.sub_path[0..], "v1-data" });
    defer allocator.free(root);
    const id = "0123456789abcdef0123456789abcdef";
    const job_directory = try std.fs.path.join(allocator, &.{ root, "jobs", id });
    defer allocator.free(job_directory);
    try std.Io.Dir.cwd().createDirPath(io, job_directory);
    const manifest_path = try std.fs.path.join(allocator, &.{ job_directory, "job.json" });
    defer allocator.free(manifest_path);
    const manifest = try std.Io.Dir.cwd().createFile(io, manifest_path, .{ .permissions = @fromBackingInt(@intCast(0o600)) });
    {
        defer manifest.close(io);
        var buffer: [1024]u8 = undefined;
        var writer = manifest.writer(io, &buffer);
        try writer.interface.writeAll("{\"version\":1,\"id\":\"0123456789abcdef0123456789abcdef\",\"source_url\":\"https://example.com/media\",\"intent\":\"inspect\",\"created_at\":1800000000,\"updated_at\":1800000000}\n");
        try writer.flush();
    }

    var registry = try Registry.init(allocator, io, root, 4);
    defer registry.deinit();
    try std.testing.expect((try registry.snapshot(allocator, id)) == null);
    const quarantine_path = try std.fs.path.join(allocator, &.{ root, "quarantine" });
    defer allocator.free(quarantine_path);
    var quarantine = try std.Io.Dir.cwd().openDir(io, quarantine_path, .{ .iterate = true });
    defer quarantine.close(io);
    var iterator = quarantine.iterate();
    const entry = (try iterator.next(io)).?;
    try std.testing.expect(std.mem.startsWith(u8, entry.name, id));
    try std.testing.expect((try iterator.next(io)) == null);
}
