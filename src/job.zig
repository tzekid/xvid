const std = @import("std");

pub const manifest_version: u32 = 2;
pub const id_bytes: usize = 16;
pub const id_length: usize = id_bytes * 2;
pub const max_media_items: usize = 8;
pub const max_poster_bytes: u64 = 8 * 1024 * 1024;

pub const State = enum {
    probing,
    awaiting_choice,
    queued,
    acquiring,
    preparing,
    ready,
    failed,
    cancelled,

    pub fn terminal(state: State) bool {
        return state == .ready or state == .failed or state == .cancelled;
    }
};

pub const Intent = enum { inspect, save_original };
pub const SourceEngine = enum { x_native, ytdlp };
pub const MediaKind = enum { video, audio, image, mixed, unknown };
pub const SelectionKind = enum { all, video, audio, image };
pub const XMediaKind = enum { photo, video, animated_gif };
pub const DeliveryMode = enum { original, optimise, downscale };
pub const TotalKind = enum { exact, approximate };

pub const Variant = struct {
    id: []const u8,
    label: []const u8,
    height: ?u32 = null,
    estimated_size_bytes: ?u64 = null,
    estimated_size_kind: ?TotalKind = null,
};

pub const XVideoVariant = struct {
    url: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
    bitrate: ?u64 = null,
};

pub const XPlanItem = struct {
    id: []const u8,
    ordinal: u8,
    kind: XMediaKind,
    photo_url: ?[]const u8 = null,
    thumbnail_url: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    video_variants: []const XVideoVariant = &.{},
};

pub const XPlan = struct {
    status_id: []const u8,
    resolved_at: i64,
    items: []const XPlanItem,
};

pub const Probe = struct {
    engine: SourceEngine,
    title: []const u8,
    source_host: []const u8,
    media_kind: MediaKind,
    duration_seconds: ?u64 = null,
    thumbnail_url: ?[]const u8 = null,
    source_height: ?u32 = null,
    variants: []const Variant = &.{},
    audio_available: bool = false,
    item_count: u8 = 1,
    video_count: u8 = 0,
    image_count: u8 = 0,
    x_plan: ?XPlan = null,
};

pub const Acquisition = struct {
    artifacts: []const Artifact,
    output_artifacts: []const Artifact = &.{},
    total_bytes: u64,
};

pub const Selection = struct {
    kind: SelectionKind,
    variant_id: ?[]const u8 = null,
    label: []const u8,
};

pub const Delivery = struct {
    mode: DeliveryMode,
    target_height: ?u32 = null,
};

pub const Artifact = struct {
    id: []const u8,
    path: []const u8,
    filename: []const u8,
    media_kind: MediaKind,
    mime_type: []const u8,
    size_bytes: u64,
    primary: bool = false,
    poster: ?Poster = null,
};

pub const Poster = struct {
    path: []const u8,
    mime_type: []const u8,
    size_bytes: u64,
};

pub const Failure = struct {
    code: []const u8,
    message: []const u8,
};

pub const Data = struct {
    version: u32 = manifest_version,
    id: []const u8,
    source_url: []const u8,
    intent: Intent,
    created_at: i64,
    updated_at: i64,
    state: State = .probing,
    probe: ?Probe = null,
    selection: ?Selection = null,
    delivery: ?Delivery = null,
    source_artifacts: []const Artifact = &.{},
    output_artifacts: []const Artifact = &.{},
    failure: ?Failure = null,
    warning: ?[]const u8 = null,
    expires_at: ?i64 = null,
};

pub const ProgressPhase = enum {
    probing,
    queued,
    source_download,
    source_merge,
    source_probe,
    encoding,
    packaging,
    ready,
};

pub const Progress = struct {
    phase: ProgressPhase = .probing,
    label: []const u8 = "Inspecting media",
    attempt: u32 = 0,
    bytes_downloaded: ?u64 = null,
    bytes_total: ?u64 = null,
    bytes_total_kind: ?TotalKind = null,
    bytes_output: ?u64 = null,
    media_seconds_processed: ?f64 = null,
    media_seconds_total: ?f64 = null,
    fraction: ?f64 = null,
    speed_bytes_per_second: ?f64 = null,
    media_speed_ratio: ?f64 = null,
    eta_seconds: ?u64 = null,
    item_index: ?u8 = null,
    item_count: ?u8 = null,
    updated_at: ?i64 = null,
};

pub const Snapshot = struct {
    data: Data,
    revision: u64,
    progress: Progress,
    source_available: bool,
};

pub const Job = struct {
    owner: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    data: Data,
    revision: u64 = 1,
    progress: Progress = .{},
    cancel_requested: std.atomic.Value(bool) = .init(false),
    references: std.atomic.Value(usize) = .init(1),
    mutex: std.atomic.Value(bool) = .init(false),

    pub fn create(owner: std.mem.Allocator, id: []const u8, source_url: []const u8, intent: Intent, now: i64) !*Job {
        const pointer = try owner.create(Job);
        errdefer owner.destroy(pointer);
        var arena = std.heap.ArenaAllocator.init(owner);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const owned_id = try allocator.dupe(u8, id);
        const owned_source_url = try allocator.dupe(u8, source_url);
        pointer.* = .{
            .owner = owner,
            .arena = arena,
            .data = .{
                .id = owned_id,
                .source_url = owned_source_url,
                .intent = intent,
                .created_at = now,
                .updated_at = now,
            },
        };
        return pointer;
    }

    pub fn fromParsed(owner: std.mem.Allocator, arena: std.heap.ArenaAllocator, data: Data) !*Job {
        const pointer = try owner.create(Job);
        pointer.* = .{ .owner = owner, .arena = arena, .data = data };
        pointer.recoverRuntime();
        return pointer;
    }

    pub fn deinit(job: *Job) void {
        const owner = job.owner;
        job.arena.deinit();
        owner.destroy(job);
    }

    pub fn retain(job: *Job) void {
        _ = job.references.fetchAdd(1, .acq_rel);
    }

    pub fn release(job: *Job) void {
        const previous = job.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous == 1) job.deinit();
    }

    pub fn lock(job: *Job) void {
        while (job.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(job: *Job) void {
        job.mutex.store(false, .release);
    }

    pub fn transition(job: *Job, next: State, now: i64, terminal_ttl_seconds: i64) !void {
        if (!transitionAllowed(job.data.state, next)) return error.InvalidStateTransition;
        job.data.state = next;
        job.data.updated_at = now;
        job.data.expires_at = if (next.terminal()) now + terminal_ttl_seconds else null;
        if (next == .cancelled) job.cancel_requested.store(true, .release);
        job.revision +%= 1;
    }

    pub fn snapshot(job: *const Job, allocator: std.mem.Allocator) !Snapshot {
        return .{
            .data = try cloneData(allocator, job.data),
            .revision = job.revision,
            .progress = try cloneProgress(allocator, job.progress),
            .source_available = job.data.source_artifacts.len > 0,
        };
    }

    fn recoverRuntime(job: *Job) void {
        job.progress = switch (job.data.state) {
            .probing => .{ .phase = .probing, .label = "Inspecting media" },
            .awaiting_choice => .{ .phase = .probing, .label = "Ready for your choice" },
            .queued => .{ .phase = .queued, .label = "Queued" },
            .acquiring => .{ .phase = .source_download, .label = "Recovering download" },
            .preparing => .{ .phase = .encoding, .label = "Recovering preparation" },
            .ready => .{ .phase = .ready, .label = "Ready", .fraction = 1 },
            .failed => .{ .phase = .ready, .label = "Failed" },
            .cancelled => .{ .phase = .ready, .label = "Cancelled" },
        };
    }
};

fn transitionAllowed(current: State, next: State) bool {
    if (current == next) return false;
    return switch (current) {
        .probing => next == .awaiting_choice or next == .queued or next == .failed,
        .awaiting_choice => next == .queued or next == .cancelled,
        .queued => next == .acquiring or next == .cancelled,
        .acquiring => next == .preparing or next == .ready or next == .failed or next == .cancelled,
        .preparing => next == .ready or next == .cancelled,
        .ready, .failed, .cancelled => false,
    };
}

pub fn validId(id: []const u8) bool {
    if (id.len != id_length) return false;
    for (id) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

pub fn validRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\r\n\x00\\") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn validateData(data: Data, directory_id: []const u8) !void {
    if (data.version != manifest_version) return error.UnsupportedManifestVersion;
    if (!validId(data.id) or !std.mem.eql(u8, data.id, directory_id)) return error.InvalidJobId;
    if (data.source_url.len == 0 or data.source_url.len > 4096) return error.InvalidSourceUrl;
    if (data.created_at <= 0 or data.updated_at < data.created_at) return error.InvalidTimestamp;
    if (data.probe) |probe| try validateProbe(probe);
    if ((data.selection == null) != (data.delivery == null) or (data.selection != null and data.probe == null)) return error.InvalidSelection;
    if (data.selection) |selection| try validateStart(data.probe.?, selection, data.delivery.?);
    if ((data.state == .probing or data.state == .awaiting_choice) and data.selection != null) return error.InvalidSelection;
    if ((data.state == .queued or data.state == .acquiring or data.state == .preparing or data.state == .ready) and data.selection == null) return error.InvalidSelection;
    if (data.source_artifacts.len > max_media_items or data.output_artifacts.len > max_media_items + 1) return error.TooManyArtifacts;
    if (data.state == .ready and data.source_artifacts.len == 0 and data.output_artifacts.len == 0) return error.MissingReadyArtifact;
    for (data.source_artifacts) |artifact| try validateArtifact(artifact);
    for (data.output_artifacts) |artifact| try validateArtifact(artifact);
    if (data.state.terminal() != (data.expires_at != null)) return error.InvalidExpiry;
}

pub fn validateProbe(probe: Probe) !void {
    if (probe.title.len == 0 or probe.title.len > 1024 or probe.source_host.len == 0 or probe.source_host.len > 253) return error.InvalidProbe;
    if (!std.unicode.utf8ValidateSlice(probe.title)) return error.InvalidProbe;
    if (probe.item_count == 0 or probe.item_count > max_media_items or probe.variants.len > 32) return error.InvalidProbe;
    for (probe.variants) |variant| if (variant.id.len == 0 or variant.id.len > 128 or variant.label.len == 0 or variant.label.len > 256) return error.InvalidProbe;
    if (@as(usize, probe.video_count) + @as(usize, probe.image_count) > probe.item_count) return error.InvalidProbe;
    if (probe.thumbnail_url) |thumbnail_url| if (!validPersistedUrl(thumbnail_url)) return error.InvalidProbe;
    switch (probe.engine) {
        .x_native => try validateXProbe(probe),
        .ytdlp => if (probe.x_plan != null) return error.InvalidProbe,
    }
}

fn validateXProbe(probe: Probe) !void {
    const plan = probe.x_plan orelse return error.InvalidProbe;
    if (!validStatusId(plan.status_id) or plan.resolved_at <= 0 or plan.items.len == 0 or plan.items.len > max_media_items or plan.items.len != probe.item_count) return error.InvalidProbe;
    var video_count: usize = 0;
    var image_count: usize = 0;
    for (plan.items, 0..) |item, index| {
        if (@as(usize, item.ordinal) != index + 1 or !validXMediaId(item.id)) return error.InvalidProbe;
        if (item.thumbnail_url) |thumbnail_url| if (!validPersistedUrl(thumbnail_url)) return error.InvalidProbe;
        if (item.width) |width| if (width == 0) return error.InvalidProbe;
        if (item.height) |height| if (height == 0) return error.InvalidProbe;
        switch (item.kind) {
            .photo => {
                image_count += 1;
                const photo_url = item.photo_url orelse return error.InvalidProbe;
                if (!validPersistedUrl(photo_url) or item.video_variants.len != 0) return error.InvalidProbe;
            },
            .video, .animated_gif => {
                video_count += 1;
                if (item.photo_url != null or item.video_variants.len == 0 or item.video_variants.len > 8) return error.InvalidProbe;
                for (item.video_variants) |variant| {
                    if (!validPersistedUrl(variant.url)) return error.InvalidProbe;
                    if (variant.width) |width| if (width == 0) return error.InvalidProbe;
                    if (variant.height) |height| if (height == 0) return error.InvalidProbe;
                }
            },
        }
    }
    if (video_count + image_count != probe.item_count or video_count != probe.video_count or image_count != probe.image_count) return error.InvalidProbe;
    const expected_kind: MediaKind = if (video_count > 0 and image_count > 0)
        .mixed
    else if (video_count > 0)
        .video
    else
        .image;
    if (probe.media_kind != expected_kind) return error.InvalidProbe;
}

pub fn validateStart(probe: Probe, selection: Selection, delivery: Delivery) !void {
    try validateSelection(probe, selection);
    if (delivery.mode == .downscale) {
        const target = delivery.target_height orelse return error.InvalidDelivery;
        if (target < 144 or probe.source_height == null or target >= probe.source_height.?) return error.InvalidDelivery;
    } else if (delivery.target_height != null) return error.InvalidDelivery;
    if ((selection.kind == .all or selection.kind == .image or probe.item_count > 1) and delivery.mode != .original) return error.InvalidDelivery;
}

fn validateSelection(probe: Probe, selection: Selection) !void {
    if (selection.label.len == 0 or selection.label.len > 256) return error.InvalidSelection;
    switch (selection.kind) {
        .all => if (probe.engine != .x_native or probe.item_count < 2 or probe.media_kind != .mixed) return error.InvalidSelection,
        .video => {
            if (probe.media_kind != .video or probe.variants.len == 0) return error.InvalidSelection;
            const variant_id = selection.variant_id orelse return error.InvalidSelection;
            for (probe.variants) |variant| if (std.mem.eql(u8, variant.id, variant_id)) return;
            return error.InvalidSelection;
        },
        .audio => if (!probe.audio_available or selection.variant_id != null) return error.InvalidSelection,
        .image => if (probe.image_count == 0 or selection.variant_id != null) return error.InvalidSelection,
    }
    if (selection.kind != .video and selection.variant_id != null) return error.InvalidSelection;
}

fn validPersistedUrl(value: []const u8) bool {
    return value.len > 0 and value.len <= 2048 and
        (std.ascii.startsWithIgnoreCase(value, "https://") or std.ascii.startsWithIgnoreCase(value, "http://")) and
        std.mem.indexOfAny(u8, value, "\r\n\x00") == null;
}

fn validStatusId(value: []const u8) bool {
    if (value.len == 0 or value.len > 24) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validXMediaId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

fn validateArtifact(artifact: Artifact) !void {
    if (artifact.id.len == 0 or artifact.id.len > 64 or artifact.filename.len == 0 or artifact.filename.len > 255 or artifact.mime_type.len == 0 or artifact.mime_type.len > 255 or artifact.size_bytes == 0 or !validRelativePath(artifact.path)) return error.InvalidArtifact;
    if (std.mem.indexOfAny(u8, artifact.id, "\r\n\x00/\\\"") != null or std.mem.indexOfAny(u8, artifact.filename, "\r\n\x00\\\"") != null or std.mem.indexOfAny(u8, artifact.mime_type, "\r\n\x00") != null) return error.InvalidArtifact;
    if (artifact.poster) |poster| {
        if (artifact.media_kind != .video or poster.size_bytes == 0 or poster.size_bytes > max_poster_bytes or !validRelativePath(poster.path) or !std.mem.startsWith(u8, poster.path, "preview/")) return error.InvalidArtifact;
        if (!validPosterMimeType(poster.mime_type) or std.mem.indexOfAny(u8, poster.mime_type, "\r\n\x00") != null) return error.InvalidArtifact;
    }
}

fn validPosterMimeType(value: []const u8) bool {
    return std.mem.eql(u8, value, "image/jpeg") or
        std.mem.eql(u8, value, "image/png") or
        std.mem.eql(u8, value, "image/webp") or
        std.mem.eql(u8, value, "image/gif");
}

fn cloneData(allocator: std.mem.Allocator, data: Data) !Data {
    return .{
        .version = data.version,
        .id = try allocator.dupe(u8, data.id),
        .source_url = try allocator.dupe(u8, data.source_url),
        .intent = data.intent,
        .created_at = data.created_at,
        .updated_at = data.updated_at,
        .state = data.state,
        .probe = if (data.probe) |value| try cloneProbe(allocator, value) else null,
        .selection = if (data.selection) |value| try cloneSelection(allocator, value) else null,
        .delivery = data.delivery,
        .source_artifacts = try cloneArtifacts(allocator, data.source_artifacts),
        .output_artifacts = try cloneArtifacts(allocator, data.output_artifacts),
        .failure = if (data.failure) |value| .{
            .code = try allocator.dupe(u8, value.code),
            .message = try allocator.dupe(u8, value.message),
        } else null,
        .warning = if (data.warning) |value| try allocator.dupe(u8, value) else null,
        .expires_at = data.expires_at,
    };
}

pub fn cloneProbe(allocator: std.mem.Allocator, probe: Probe) !Probe {
    const variants = try allocator.alloc(Variant, probe.variants.len);
    for (probe.variants, 0..) |variant, index| variants[index] = .{
        .id = try allocator.dupe(u8, variant.id),
        .label = try allocator.dupe(u8, variant.label),
        .height = variant.height,
        .estimated_size_bytes = variant.estimated_size_bytes,
        .estimated_size_kind = variant.estimated_size_kind,
    };
    return .{
        .engine = probe.engine,
        .title = try allocator.dupe(u8, probe.title),
        .source_host = try allocator.dupe(u8, probe.source_host),
        .media_kind = probe.media_kind,
        .duration_seconds = probe.duration_seconds,
        .thumbnail_url = if (probe.thumbnail_url) |value| try allocator.dupe(u8, value) else null,
        .source_height = probe.source_height,
        .variants = variants,
        .audio_available = probe.audio_available,
        .item_count = probe.item_count,
        .video_count = probe.video_count,
        .image_count = probe.image_count,
        .x_plan = if (probe.x_plan) |plan| try cloneXPlan(allocator, plan) else null,
    };
}

pub fn cloneSelection(allocator: std.mem.Allocator, selection: Selection) !Selection {
    return .{
        .kind = selection.kind,
        .variant_id = if (selection.variant_id) |value| try allocator.dupe(u8, value) else null,
        .label = try allocator.dupe(u8, selection.label),
    };
}

fn cloneXPlan(allocator: std.mem.Allocator, plan: XPlan) !XPlan {
    const items = try allocator.alloc(XPlanItem, plan.items.len);
    for (plan.items, 0..) |item, index| {
        const video_variants = try allocator.alloc(XVideoVariant, item.video_variants.len);
        for (item.video_variants, 0..) |variant, variant_index| video_variants[variant_index] = .{
            .url = try allocator.dupe(u8, variant.url),
            .width = variant.width,
            .height = variant.height,
            .bitrate = variant.bitrate,
        };
        items[index] = .{
            .id = try allocator.dupe(u8, item.id),
            .ordinal = item.ordinal,
            .kind = item.kind,
            .photo_url = if (item.photo_url) |value| try allocator.dupe(u8, value) else null,
            .thumbnail_url = if (item.thumbnail_url) |value| try allocator.dupe(u8, value) else null,
            .duration_ms = item.duration_ms,
            .width = item.width,
            .height = item.height,
            .video_variants = video_variants,
        };
    }
    return .{
        .status_id = try allocator.dupe(u8, plan.status_id),
        .resolved_at = plan.resolved_at,
        .items = items,
    };
}

pub fn defaultOriginalSelection(allocator: std.mem.Allocator, probe: Probe) !Selection {
    return switch (probe.media_kind) {
        .mixed => .{
            .kind = .all,
            .label = try allocator.dupe(u8, "All original media"),
        },
        .image => .{
            .kind = .image,
            .label = try allocator.dupe(u8, "Original photos"),
        },
        .video => blk: {
            const best = for (probe.variants) |variant| {
                if (std.mem.eql(u8, variant.id, "best")) break variant;
            } else return error.VariantUnavailable;
            break :blk .{
                .kind = .video,
                .variant_id = try allocator.dupe(u8, best.id),
                .label = try allocator.dupe(u8, "Best original video"),
            };
        },
        .audio => .{
            .kind = .audio,
            .label = try allocator.dupe(u8, "Original audio"),
        },
        .unknown => error.InvalidSelection,
    };
}

pub fn cloneArtifacts(allocator: std.mem.Allocator, artifacts: []const Artifact) ![]const Artifact {
    const copy = try allocator.alloc(Artifact, artifacts.len);
    for (artifacts, 0..) |artifact, index| copy[index] = .{
        .id = try allocator.dupe(u8, artifact.id),
        .path = try allocator.dupe(u8, artifact.path),
        .filename = try allocator.dupe(u8, artifact.filename),
        .media_kind = artifact.media_kind,
        .mime_type = try allocator.dupe(u8, artifact.mime_type),
        .size_bytes = artifact.size_bytes,
        .primary = artifact.primary,
        .poster = if (artifact.poster) |poster| .{
            .path = try allocator.dupe(u8, poster.path),
            .mime_type = try allocator.dupe(u8, poster.mime_type),
            .size_bytes = poster.size_bytes,
        } else null,
    };
    return copy;
}

fn cloneProgress(allocator: std.mem.Allocator, progress: Progress) !Progress {
    var copy = progress;
    copy.label = try allocator.dupe(u8, progress.label);
    return copy;
}

test "state transitions are explicit and terminal states stop" {
    try std.testing.expect(transitionAllowed(.probing, .awaiting_choice));
    try std.testing.expect(transitionAllowed(.probing, .queued));
    try std.testing.expect(transitionAllowed(.probing, .failed));
    try std.testing.expect(!transitionAllowed(.probing, .ready));
    try std.testing.expect(transitionAllowed(.preparing, .ready));
    try std.testing.expect(!transitionAllowed(.ready, .queued));
}

test "manifest v2 validates and deep clones a bounded X plan" {
    const items = [_]XPlanItem{.{
        .id = "2041707173428748594-1",
        .ordinal = 1,
        .kind = .photo,
        .photo_url = "https://pbs.twimg.com/media/example.jpg?name=orig",
        .thumbnail_url = "https://pbs.twimg.com/media/example.jpg?name=orig",
    }};
    const probe = Probe{
        .engine = .x_native,
        .title = "X photo",
        .source_host = "x.com",
        .media_kind = .image,
        .thumbnail_url = items[0].thumbnail_url,
        .item_count = 1,
        .image_count = 1,
        .x_plan = .{
            .status_id = "2041707173428748594",
            .resolved_at = 1_800_000_000,
            .items = &items,
        },
    };
    try validateData(.{
        .id = "0123456789abcdef0123456789abcdef",
        .source_url = "https://x.com/i/status/2041707173428748594",
        .intent = .inspect,
        .created_at = 1_800_000_000,
        .updated_at = 1_800_000_000,
        .state = .awaiting_choice,
        .probe = probe,
    }, "0123456789abcdef0123456789abcdef");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const copy = try cloneProbe(arena_state.allocator(), probe);
    try std.testing.expectEqualStrings(probe.x_plan.?.status_id, copy.x_plan.?.status_id);
    try std.testing.expectEqualStrings(probe.x_plan.?.items[0].photo_url.?, copy.x_plan.?.items[0].photo_url.?);
    try std.testing.expect(probe.x_plan.?.items.ptr != copy.x_plan.?.items.ptr);

    var invalid_items = items;
    invalid_items[0].ordinal = 2;
    var invalid_probe = probe;
    invalid_probe.x_plan.?.items = &invalid_items;
    try std.testing.expectError(error.InvalidProbe, validateXProbe(invalid_probe));
}

test "default Original selection is explicit for video and mixed media" {
    const variants = [_]Variant{.{ .id = "best", .label = "Best" }};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const video = try defaultOriginalSelection(allocator, .{
        .engine = .ytdlp,
        .title = "Video",
        .source_host = "example.com",
        .media_kind = .video,
        .variants = &variants,
        .video_count = 1,
    });
    try std.testing.expectEqual(SelectionKind.video, video.kind);
    try std.testing.expectEqualStrings("best", video.variant_id.?);
    try std.testing.expectEqualStrings("Best original video", video.label);

    const mixed = try defaultOriginalSelection(allocator, .{
        .engine = .x_native,
        .title = "Mixed",
        .source_host = "x.com",
        .media_kind = .mixed,
        .item_count = 2,
        .video_count = 1,
        .image_count = 1,
    });
    try std.testing.expectEqual(SelectionKind.all, mixed.kind);
    try std.testing.expectEqualStrings("All original media", mixed.label);
}

test "job IDs and artifact paths are traversal resistant" {
    try std.testing.expect(validId("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!validId("0123456789ABCDEF0123456789ABCDEF"));
    try std.testing.expect(validRelativePath("source/item-001.mp4"));
    try std.testing.expect(!validRelativePath("../secret"));
    try std.testing.expect(!validRelativePath("source//item.mp4"));
    try std.testing.expect(!validRelativePath("/etc/passwd"));
}
