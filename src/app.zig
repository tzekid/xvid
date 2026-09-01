const std = @import("std");
const Config = @import("config.zig").Config;
const disk = @import("disk.zig");
const ffmpeg = @import("ffmpeg.zig");
const job_store = @import("job_store.zig");
const job_mod = @import("job.zig");
const Queue = @import("queue.zig").Queue;
const rate_limit = @import("rate_limit.zig");
const server = @import("server.zig");
const source = @import("source.zig");
const usage = @import("usage.zig");
const media_url = @import("url.zig");
const work_claims = @import("work_claims.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    ownership_file: std.Io.File,
    registry: job_store.Registry,
    usage_store: usage.Store,
    rate_limiter: rate_limit.Limiter,
    claims: work_claims.Claims,
    child_environment: std.process.Environ.Map,
    source_shared: source.Shared = .{},
    probe_queue: Queue,
    probe_threads: []?std.Thread,
    media_queue: Queue,
    media_threads: []?std.Thread,
    stop_background: std.atomic.Value(bool) = .init(false),
    open_sse: std.atomic.Value(u8) = .init(0),
    open_artifacts: std.atomic.Value(u8) = .init(0),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !App {
        try config.validate();
        try std.Io.Dir.cwd().createDirPath(io, config.data_dir);
        const temp_directory = try std.fs.path.join(allocator, &.{ config.data_dir, "tmp" });
        defer allocator.free(temp_directory);
        try std.Io.Dir.cwd().createDirPath(io, temp_directory);
        const ownership_path = try std.fs.path.join(allocator, &.{ config.data_dir, ".xvid.lock" });
        defer allocator.free(ownership_path);
        const ownership_file = std.Io.Dir.cwd().createFile(io, ownership_path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = @fromBackingInt(@intCast(0o600)),
        }) catch |err| switch (err) {
            error.WouldBlock => return error.DataDirectoryInUse,
            else => return err,
        };
        errdefer ownership_file.close(io);
        var registry = try job_store.Registry.init(allocator, io, config.data_dir, config.max_loaded_jobs);
        errdefer registry.deinit();
        var usage_store = try usage.Store.init(allocator, io, config.data_dir);
        errdefer usage_store.deinit();
        var rate_limiter = try rate_limit.Limiter.init(allocator, config.rate_limit_capacity, config.probes_per_minute, config.jobs_per_hour);
        errdefer rate_limiter.deinit();
        var claims = try work_claims.Claims.init(allocator, config.max_loaded_jobs);
        errdefer claims.deinit();
        var probe_queue = try Queue.init(allocator, config.max_queued_probes);
        errdefer probe_queue.deinit();
        var media_queue = try Queue.init(allocator, config.max_queued_media);
        errdefer media_queue.deinit();
        const probe_threads = try allocator.alloc(?std.Thread, config.probe_workers);
        errdefer allocator.free(probe_threads);
        @memset(probe_threads, null);
        const media_threads = try allocator.alloc(?std.Thread, config.media_workers);
        errdefer allocator.free(media_threads);
        @memset(media_threads, null);
        var child_environment = std.process.Environ.Map.init(allocator);
        errdefer child_environment.deinit();
        try child_environment.put("PATH", "/usr/local/bin:/usr/bin:/bin");
        try child_environment.put("HOME", config.data_dir);
        try child_environment.put("TMPDIR", temp_directory);
        try child_environment.put("LANG", "C.UTF-8");
        var app: App = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .ownership_file = ownership_file,
            .registry = registry,
            .usage_store = usage_store,
            .rate_limiter = rate_limiter,
            .claims = claims,
            .child_environment = child_environment,
            .probe_queue = probe_queue,
            .probe_threads = probe_threads,
            .media_queue = media_queue,
            .media_threads = media_threads,
        };
        try app.backfillUsage();
        return app;
    }

    pub fn deinit(app: *App) void {
        app.allocator.free(app.media_threads);
        app.media_queue.deinit();
        app.allocator.free(app.probe_threads);
        app.probe_queue.deinit();
        app.child_environment.deinit();
        app.claims.deinit();
        app.rate_limiter.deinit();
        app.usage_store.deinit();
        app.registry.deinit();
        app.ownership_file.close(app.io);
    }

    pub fn enqueueProbe(app: *App, id: []const u8) !bool {
        return app.probe_queue.tryPush(id);
    }

    pub fn enqueueMedia(app: *App, id: []const u8) !bool {
        return app.media_queue.tryPush(id);
    }

    pub fn hasMinimumFreeSpace(app: *App) !bool {
        return try disk.availableBytes(app.allocator, app.config.data_dir) >= app.config.minimum_free_bytes;
    }

    pub fn canStartMedia(app: *App, item_count: u8, mode: job_mod.DeliveryMode) !bool {
        const output_reserve = if (mode != .original or item_count > 1) app.config.max_output_bytes else 0;
        const reserve = std.math.add(u64, app.config.max_download_bytes, output_reserve) catch return false;
        const used = try app.registry.storageBytes();
        if (used > app.config.job_storage_budget_bytes or reserve > app.config.job_storage_budget_bytes - used) return false;
        const available = try disk.availableBytes(app.allocator, app.config.data_dir);
        return available >= app.config.minimum_free_bytes and reserve <= available - app.config.minimum_free_bytes;
    }

    pub fn syncUsage(app: *App, id: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(app.allocator);
        defer arena_state.deinit();
        const snapshot = (app.registry.snapshot(arena_state.allocator(), id) catch |err| {
            std.log.warn("usage snapshot failed job_id={s} error={s}", .{ id, @errorName(err) });
            return;
        }) orelse return;
        var host_buffer: [512]u8 = undefined;
        const source_host = if (snapshot.data.probe) |probe|
            probe.source_host
        else
            (media_url.validate(snapshot.data.source_url, &host_buffer) catch return).host;
        app.usage_store.recordCreated(snapshot.data.id, snapshot.data.created_at, source_host, snapshot.data.intent) catch |err| {
            std.log.warn("usage job sync failed job_id={s} error={s}", .{ id, @errorName(err) });
            return;
        };
        app.usage_store.recordSnapshot(snapshot.data) catch |err| {
            std.log.warn("usage job sync failed job_id={s} error={s}", .{ id, @errorName(err) });
        };
    }

    fn backfillUsage(app: *App) !void {
        inline for (.{
            job_mod.State.probing,
            job_mod.State.awaiting_choice,
            job_mod.State.queued,
            job_mod.State.acquiring,
            job_mod.State.preparing,
            job_mod.State.ready,
            job_mod.State.failed,
            job_mod.State.cancelled,
        }) |state| {
            const ids = try app.registry.idsInState(app.allocator, state);
            defer app.allocator.free(ids);
            for (ids) |id| {
                var arena_state = std.heap.ArenaAllocator.init(app.allocator);
                defer arena_state.deinit();
                const snapshot = (try app.registry.snapshot(arena_state.allocator(), &id)) orelse continue;
                var host_buffer: [512]u8 = undefined;
                const source_host = if (snapshot.data.probe) |probe|
                    probe.source_host
                else
                    (media_url.validate(snapshot.data.source_url, &host_buffer) catch continue).host;
                try app.usage_store.recordCreated(snapshot.data.id, snapshot.data.created_at, source_host, snapshot.data.intent);
                try app.usage_store.recordSnapshot(snapshot.data);
            }
        }
    }

    pub fn serve(app: *App) !void {
        app.stop_background.store(false, .release);
        try app.enqueueRecoveryProbes();
        try app.enqueueRecoveryMedia();
        var started: usize = 0;
        errdefer {
            app.stop_background.store(true, .release);
            for (app.probe_threads[0..started]) |thread| if (thread) |item| item.join();
        }
        for (app.probe_threads) |*slot| {
            slot.* = try std.Thread.spawn(.{}, probeMain, .{app});
            started += 1;
        }
        var media_started: usize = 0;
        errdefer {
            app.stop_background.store(true, .release);
            for (app.media_threads[0..media_started]) |thread| if (thread) |item| item.join();
        }
        for (app.media_threads) |*slot| {
            slot.* = try std.Thread.spawn(.{}, mediaMain, .{app});
            media_started += 1;
        }
        const cleanup = try std.Thread.spawn(.{}, cleanupMain, .{app});
        defer {
            app.stop_background.store(true, .release);
            cleanup.join();
            for (app.probe_threads) |*slot| {
                if (slot.*) |thread| thread.join();
                slot.* = null;
            }
            for (app.media_threads) |*slot| {
                if (slot.*) |thread| thread.join();
                slot.* = null;
            }
        }
        try server.serve(app);
    }

    fn cleanupMain(app: *App) void {
        while (!app.stop_background.load(.acquire)) {
            var elapsed: u16 = 0;
            while (elapsed < app.config.cleanup_interval_seconds * 10 and !app.stop_background.load(.acquire)) : (elapsed += 1) {
                sleepMilliseconds(100);
            }
            if (app.stop_background.load(.acquire)) break;
            const now_value = std.Io.Clock.real.now(app.io).toSeconds();
            app.expireAbandonedChoices(now_value) catch |err| std.log.warn("choice expiry scan failed: {s}", .{@errorName(err)});
            app.enqueueRecoveryProbes() catch |err| std.log.warn("probe recovery scan failed: {s}", .{@errorName(err)});
            app.enqueueRecoveryMedia() catch |err| std.log.warn("media recovery scan failed: {s}", .{@errorName(err)});
            _ = app.registry.pruneExpired(now_value) catch |err| blk: {
                std.log.warn("job cleanup failed: {s}", .{@errorName(err)});
                break :blk 0;
            };
        }
    }

    fn expireAbandonedChoices(app: *App, now_value: i64) !void {
        const ids = try app.registry.idsInState(app.allocator, .awaiting_choice);
        defer app.allocator.free(ids);
        for (ids) |id| {
            var arena_state = std.heap.ArenaAllocator.init(app.allocator);
            defer arena_state.deinit();
            const snapshot = (try app.registry.snapshot(arena_state.allocator(), &id)) orelse continue;
            if (snapshot.data.state != .awaiting_choice) continue;
            if (now_value - snapshot.data.updated_at < @as(i64, @intCast(app.config.choice_ttl_seconds))) continue;
            const changed = app.registry.transition(&id, .cancelled, now_value, app.config.terminal_ttl_seconds) catch |err| switch (err) {
                error.InvalidStateTransition => continue,
                else => return err,
            };
            if (!changed) continue;
            app.syncUsage(&id);
            _ = app.registry.delete(&id) catch |err| switch (err) {
                error.JobBusy => false,
                else => return err,
            };
            std.log.info("choice_expired job_id={s}", .{&id});
        }
    }

    fn enqueueRecoveryProbes(app: *App) !void {
        const ids = try app.registry.idsInState(app.allocator, .probing);
        defer app.allocator.free(ids);
        for (ids) |id| {
            if (app.claims.contains(.probe, &id)) continue;
            if (!try app.probe_queue.tryPush(&id)) break;
        }
    }

    fn enqueueRecoveryMedia(app: *App) !void {
        inline for (.{ job_mod.State.queued, job_mod.State.acquiring, job_mod.State.preparing }) |state| {
            const ids = try app.registry.idsInState(app.allocator, state);
            defer app.allocator.free(ids);
            for (ids) |id| {
                if (app.claims.contains(.media, &id)) continue;
                if (!try app.media_queue.tryPush(&id)) break;
            }
        }
    }

    fn probeMain(app: *App) void {
        var source_context = source.Context.init(app.allocator, app.io, &app.config, &app.child_environment, &app.source_shared);
        defer source_context.deinit();
        while (!app.stop_background.load(.acquire)) {
            const id = app.probe_queue.pop() orelse {
                sleepMilliseconds(10);
                continue;
            };
            app.runProbe(&source_context, &id) catch |err| std.log.warn("probe worker failed job_id={s} error={s}", .{ &id, @errorName(err) });
        }
    }

    fn runProbe(app: *App, source_context: *source.Context, id: []const u8) !void {
        if (!try app.claims.claim(.probe, id)) return;
        defer app.claims.release(.probe, id);
        const retained = app.registry.retain(id) orelse return;
        defer retained.release();
        const started = std.Io.Clock.Timestamp.now(app.io, .awake);
        var arena_state = std.heap.ArenaAllocator.init(app.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const snapshot = (try app.registry.snapshot(arena, id)) orelse return;
        if (snapshot.data.state != .probing) return;
        const probe_result = source.probe(arena, source_context, id, snapshot.data.source_url, &retained.cancel_requested) catch |err| {
            if (err == error.Cancelled) return;
            const failure = probeFailure(err);
            _ = try app.registry.fail(id, failure.code, failure.message, std.Io.Clock.real.now(app.io).toSeconds(), app.config.terminal_ttl_seconds);
            app.syncUsage(id);
            std.log.warn("probe_failed job_id={s} error_code={s} cause={s}", .{ id, failure.code, @errorName(err) });
            return;
        };
        if (retained.cancel_requested.load(.acquire)) return;
        var automatic_start: ?job_store.AutomaticStart = null;
        if (snapshot.data.intent == .save_original) {
            if (!(app.canStartMedia(probe_result.item_count, .original) catch false)) {
                _ = try app.registry.fail(id, "STORAGE_UNAVAILABLE", "This job cannot start without crossing the configured storage limit.", std.Io.Clock.real.now(app.io).toSeconds(), app.config.terminal_ttl_seconds);
                app.syncUsage(id);
                std.log.warn("probe_failed job_id={s} error_code=STORAGE_UNAVAILABLE cause=bounded_storage", .{id});
                return;
            }
            const selection = job_mod.defaultOriginalSelection(arena, probe_result) catch |err| {
                const failure = probeFailure(err);
                _ = try app.registry.fail(id, failure.code, failure.message, std.Io.Clock.real.now(app.io).toSeconds(), app.config.terminal_ttl_seconds);
                app.syncUsage(id);
                std.log.warn("probe_failed job_id={s} error_code={s} cause={s}", .{ id, failure.code, @errorName(err) });
                return;
            };
            automatic_start = .{ .selection = selection, .delivery = .{ .mode = .original } };
        }
        const completed = app.registry.completeProbe(id, probe_result, automatic_start, std.Io.Clock.real.now(app.io).toSeconds()) catch |err| {
            const failure = probeFailure(err);
            _ = try app.registry.fail(id, failure.code, failure.message, std.Io.Clock.real.now(app.io).toSeconds(), app.config.terminal_ttl_seconds);
            app.syncUsage(id);
            std.log.warn("probe_failed job_id={s} error_code={s} cause={s}", .{ id, failure.code, @errorName(err) });
            return;
        };
        if (!completed) return;
        app.syncUsage(id);
        if (automatic_start != null and !try app.enqueueMedia(id)) {
            std.log.warn("media_queue_full job_id={s} state=queued recovery=scheduled", .{id});
        }
        std.log.info("probe_complete job_id={s} source_host={s} source_engine={s} items={d} duration_ms={d}", .{ id, probe_result.source_host, @tagName(probe_result.engine), probe_result.item_count, started.untilNow(app.io).raw.toMilliseconds() });
    }

    fn mediaMain(app: *App) void {
        var source_context = source.Context.init(app.allocator, app.io, &app.config, &app.child_environment, &app.source_shared);
        defer source_context.deinit();
        while (!app.stop_background.load(.acquire)) {
            const id = app.media_queue.pop() orelse {
                sleepMilliseconds(10);
                continue;
            };
            app.runMedia(&source_context, &id) catch |err| std.log.warn("media worker failed job_id={s} error={s}", .{ &id, @errorName(err) });
        }
    }

    fn runMedia(app: *App, source_context: *source.Context, id: []const u8) !void {
        if (!try app.claims.claim(.media, id)) return;
        defer app.claims.release(.media, id);
        const retained = app.registry.retain(id) orelse return;
        defer retained.release();
        const state = blk: {
            const locked = app.registry.findLocked(id) orelse return;
            defer locked.unlock();
            break :blk locked.job.data.state;
        };
        if (state == .preparing) return app.runPreparation(id, retained);
        if (state != .queued and state != .acquiring) return;
        try app.runAcquisition(source_context, id, retained);
        try app.runPreparation(id, retained);
    }

    fn runAcquisition(app: *App, source_context: *source.Context, id: []const u8, retained: *job_mod.Job) !void {
        const started = std.Io.Clock.Timestamp.now(app.io, .awake);
        if (!try app.registry.beginAcquisition(id, std.Io.Clock.real.now(app.io).toSeconds())) return;
        var arena_state = std.heap.ArenaAllocator.init(app.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const snapshot = (try app.registry.snapshot(arena, id)) orelse return;
        const probe_result = snapshot.data.probe orelse return app.failMedia(id, error.MissingProbe);
        const selection = snapshot.data.selection orelse return app.failMedia(id, error.MissingSelection);
        const job_root = try app.registry.jobPathAlloc(arena, id, "");
        var progress_context = MediaProgress{ .app = app, .id = id };
        const result = source.acquire(arena, arena, source_context, id, job_root, snapshot.data.source_url, probe_result, selection, &retained.cancel_requested, .{ .context = &progress_context, .update = MediaProgress.update }) catch |err| {
            if (err == error.Cancelled) return;
            try app.failMedia(id, err);
            return;
        };
        _ = try app.registry.finishAcquisition(id, result.artifacts, result.output_artifacts, std.Io.Clock.real.now(app.io).toSeconds(), app.config.terminal_ttl_seconds);
        app.syncUsage(id);
        std.log.info("acquisition_complete job_id={s} source_host={s} source_engine={s} items={d} bytes={d} duration_ms={d}", .{ id, probe_result.source_host, @tagName(probe_result.engine), result.artifacts.len, result.total_bytes, started.untilNow(app.io).raw.toMilliseconds() });
    }

    fn runPreparation(app: *App, id: []const u8, retained: *job_mod.Job) !void {
        const started = std.Io.Clock.Timestamp.now(app.io, .awake);
        if (!try app.registry.beginPreparation(id, std.Io.Clock.real.now(app.io).toSeconds())) return;
        var arena_state = std.heap.ArenaAllocator.init(app.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const snapshot = (try app.registry.snapshot(arena, id)) orelse return;
        const delivery = snapshot.data.delivery orelse return app.fallbackPreparation(id, error.MissingDelivery);
        const job_root = try app.registry.jobPathAlloc(arena, id, "");
        var progress_context = MediaProgress{ .app = app, .id = id };
        const artifacts = ffmpeg.prepare(arena, arena, app.io, &app.config, &app.child_environment, job_root, snapshot.data.source_artifacts, delivery, &retained.cancel_requested, .{ .context = &progress_context, .update = MediaProgress.update }) catch |err| {
            app.clearJobDirectory(id, "output");
            if (err == error.Cancelled) return;
            try app.fallbackPreparation(id, err);
            return;
        };
        _ = try app.registry.finishPreparation(id, artifacts, std.Io.Clock.real.now(app.io).toSeconds(), app.config.terminal_ttl_seconds);
        if (artifacts.len > 0 and try app.registry.discardSourcesAfterPreparation(id, std.Io.Clock.real.now(app.io).toSeconds())) app.clearJobDirectory(id, "source");
        app.syncUsage(id);
        var output_bytes: u64 = 0;
        for (artifacts) |artifact| output_bytes += artifact.size_bytes;
        std.log.info("preparation_complete job_id={s} outputs={d} bytes={d} encoded={s} duration_ms={d}", .{ id, artifacts.len, output_bytes, if (artifacts.len > 0) "true" else "false", started.untilNow(app.io).raw.toMilliseconds() });
    }

    fn fallbackPreparation(app: *App, id: []const u8, err: anyerror) !void {
        const warning = preparationWarning(err);
        _ = try app.registry.fallbackToOriginal(id, warning, std.Io.Clock.real.now(app.io).toSeconds(), app.config.terminal_ttl_seconds);
        app.syncUsage(id);
        std.log.warn("preparation_fallback job_id={s} error_code={s} delivery=original", .{ id, @errorName(err) });
    }

    fn clearJobDirectory(app: *App, id: []const u8, child: []const u8) void {
        const path = app.registry.jobPathAlloc(app.allocator, id, child) catch |err| {
            std.log.warn("job path cleanup failed job_id={s} child={s} error={s}", .{ id, child, @errorName(err) });
            return;
        };
        defer app.allocator.free(path);
        std.Io.Dir.cwd().deleteTree(app.io, path) catch |err| std.log.warn("job directory cleanup failed job_id={s} child={s} error={s}", .{ id, child, @errorName(err) });
        std.Io.Dir.cwd().createDirPath(app.io, path) catch |err| std.log.warn("job directory recreation failed job_id={s} child={s} error={s}", .{ id, child, @errorName(err) });
    }

    fn failMedia(app: *App, id: []const u8, err: anyerror) !void {
        const failure = mediaFailure(err);
        _ = try app.registry.fail(id, failure.code, failure.message, std.Io.Clock.real.now(app.io).toSeconds(), app.config.terminal_ttl_seconds);
        app.syncUsage(id);
        std.log.warn("media_failed job_id={s} error_code={s} cause={s}", .{ id, failure.code, @errorName(err) });
        app.clearJobDirectory(id, "work");
    }
};

const MediaProgress = struct {
    app: *App,
    id: []const u8,

    fn update(raw_context: *anyopaque, progress: job_mod.Progress) !void {
        const context: *MediaProgress = @ptrCast(@alignCast(raw_context));
        _ = context.app.registry.updateProgress(context.id, progress);
    }
};

fn probeFailure(err: anyerror) struct { code: []const u8, message: []const u8 } {
    return switch (err) {
        error.XPostPrivate => .{ .code = "X_PRIVATE", .message = "This X post is private." },
        error.XLoginRequired => .{ .code = "X_LOGIN_REQUIRED", .message = "X requires a signed-in account for this post." },
        error.XPostUnavailable => .{ .code = "X_UNAVAILABLE", .message = "This X post is unavailable or was removed." },
        error.XNoMedia => .{ .code = "X_NO_MEDIA", .message = "No directly downloadable media was found in this post." },
        error.XRateLimited => .{ .code = "X_RATE_LIMITED", .message = "X temporarily limited media inspection. Try again shortly." },
        error.XProviderChanged, error.XInvalidMetadata, error.XMetadataMalformed => .{ .code = "X_CHANGED", .message = "X changed how this post is exposed. xvid needs a native resolver update." },
        error.XMetadataTimedOut => .{ .code = "PROBE_TIMEOUT", .message = "X did not answer after an automatic retry." },
        error.XMetadataTransportFailed, error.XMetadataServerError => .{ .code = "X_TEMPORARY", .message = "X did not complete media inspection after an automatic retry. Try again shortly." },
        error.XMetadataTooLarge, error.XMetadataRejected => .{ .code = "INVALID_METADATA", .message = "X did not return bounded usable metadata." },
        error.UnsupportedUrl, error.UnsupportedXShape, error.XNoDirectVideo, error.TooManyMediaItems, error.MediaTooLong => .{ .code = "UNSUPPORTED_URL", .message = "Use a public X or Twitter status link with supported attached media." },
        error.InvalidProbe, error.InvalidSelection, error.InvalidDelivery => .{ .code = "INVALID_METADATA", .message = "X returned metadata xvid could not safely normalize." },
        else => .{ .code = "PROBE_FAILED", .message = "The X post could not be inspected. Try again." },
    };
}

fn mediaFailure(err: anyerror) struct { code: []const u8, message: []const u8 } {
    return switch (err) {
        error.XMediaRejected => .{ .code = "SOURCE_REJECTED", .message = "X exposed the media, but its media server rejected the download." },
        error.XMediaRedirectRejected, error.XMediaHostRejected => .{ .code = "SOURCE_REJECTED", .message = "X redirected the media outside the reviewed media hosts." },
        error.XMediaTimedOut => .{ .code = "DOWNLOAD_TIMEOUT", .message = "X stopped responding before the media download completed." },
        error.XInvalidMediaOutput => .{ .code = "INVALID_OUTPUT", .message = "X did not return a closed, usable media file." },
        error.SourceEngineRetired, error.UnsupportedUrl => .{ .code = "UNSUPPORTED_URL", .message = "Only native public X or Twitter status links are supported." },
        error.DownloadTooLarge, error.OutputTooLarge => .{ .code = "MEDIA_TOO_LARGE", .message = "The media crossed this server's configured byte limit." },
        error.ToolMissing => .{ .code = "TOOL_MISSING", .message = "A configured FFmpeg tool is unavailable." },
        else => .{ .code = "DOWNLOAD_FAILED", .message = "The selected X media could not be downloaded. Try again." },
    };
}

fn preparationWarning(err: anyerror) []const u8 {
    return switch (err) {
        error.ToolMissing => "The configured FFmpeg tools are unavailable, so xvid kept the source file.",
        error.OutputTooLarge => "The prepared file crossed this server's output limit, so xvid kept the source file.",
        error.EncodeTimedOut => "Preparation stopped after its time limit, so xvid kept the source file.",
        error.UnsupportedMultiplePreparation => "This multi-file selection cannot be prepared as one video, so xvid kept the source files.",
        else => "Optional preparation did not produce a validated file, so xvid kept the source file.",
    };
}

fn sleepMilliseconds(milliseconds: u32) void {
    var request: std.c.timespec = .{ .sec = @intCast(milliseconds / 1000), .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms) };
    var remaining: std.c.timespec = undefined;
    _ = std.c.nanosleep(&request, &remaining);
}

test "native X failures map to stable user-facing codes" {
    try std.testing.expectEqualStrings("X_PRIVATE", probeFailure(error.XPostPrivate).code);
    try std.testing.expectEqualStrings("X_LOGIN_REQUIRED", probeFailure(error.XLoginRequired).code);
    try std.testing.expectEqualStrings("X_UNAVAILABLE", probeFailure(error.XPostUnavailable).code);
    try std.testing.expectEqualStrings("X_RATE_LIMITED", probeFailure(error.XRateLimited).code);
    try std.testing.expectEqualStrings("X_CHANGED", probeFailure(error.XProviderChanged).code);
    try std.testing.expectEqualStrings("PROBE_TIMEOUT", probeFailure(error.XMetadataTimedOut).code);
    try std.testing.expectEqualStrings("X_TEMPORARY", probeFailure(error.XMetadataTransportFailed).code);
    try std.testing.expectEqualStrings("UNSUPPORTED_URL", probeFailure(error.UnsupportedUrl).code);
    try std.testing.expectEqualStrings("SOURCE_REJECTED", mediaFailure(error.XMediaRejected).code);
    try std.testing.expectEqualStrings("INVALID_OUTPUT", mediaFailure(error.XInvalidMediaOutput).code);
}
