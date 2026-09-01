const std = @import("std");
const App = @import("app.zig").App;
const job_mod = @import("job.zig");
const render = @import("render.zig");
const media_url = @import("url.zig");
const range_mod = @import("range.zig");
const usage = @import("usage.zig");
const x = @import("x.zig");

const app_css = @embedFile("app_css");
const app_js = @embedFile("app_js");
const retire_sw = @embedFile("retire_sw");
const manifest = @embedFile("manifest");
const icon = @embedFile("icon");
const icon_180 = @embedFile("icon_180");
const icon_192 = @embedFile("icon_192");
const icon_512 = @embedFile("icon_512");
const max_form_bytes: u64 = 16 * 1024;
const maximum_share_bytes = 64 * 1024 * 1024;
const asset_version = "3";

pub const ClientContext = struct {
    peer_key: u64,
    peer_is_loopback: bool,
};

const JobRoute = struct { id: []const u8, action: []const u8 };
const Form = struct {
    url: ?[]const u8 = null,
    advanced: ?[]const u8 = null,
    artifacts: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    delivery: ?[]const u8 = null,
    target_height: ?[]const u8 = null,
};

pub fn dispatch(app: *App, request: *std.http.Server.Request, client: ClientContext) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path_end = std.mem.indexOfScalar(u8, request.head.target, '?') orelse request.head.target.len;
    const path = request.head.target[0..path_end];

    if (request.head.method.requestHasBody() and !mutationAllowed(request, app.config.public_origin)) {
        return problem(request, .forbidden, "Request blocked", "Open xvid directly and repeat the action from this site.");
    }

    if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.eql(u8, path, "/")) return respondStatic(request, .ok, "text/html; charset=utf-8", render.home, "no-store");
    if ((request.head.method == .GET or request.head.method == .HEAD) and isLegacyNavigation(path)) return redirectLegacyNavigation(request);
    if (std.mem.eql(u8, path, "/api") or std.mem.startsWith(u8, path, "/api/")) return retiredApi(request);
    if (request.head.method == .POST and std.mem.eql(u8, path, "/jobs")) return createJob(app, arena, request, client);
    if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.eql(u8, path, "/healthz")) return respondStatic(request, .ok, "application/json; charset=utf-8", "{\"ok\":true,\"version\":\"1.0.0-native-x\"}\n", "no-store");
    if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.eql(u8, path, "/readyz")) return respondStatic(request, .ok, "application/json; charset=utf-8", "{\"ready\":true}\n", "no-store");
    if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.eql(u8, path, "/assets/app.css")) return respondStatic(request, .ok, "text/css; charset=utf-8", app_css, if (std.mem.eql(u8, request.head.target, "/assets/app.css?v=" ++ asset_version)) "public, max-age=31536000, immutable" else "no-store");
    if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.eql(u8, path, "/assets/app.js")) return respondStatic(request, .ok, "text/javascript; charset=utf-8", app_js, if (std.mem.eql(u8, request.head.target, "/assets/app.js?v=" ++ asset_version)) "public, max-age=31536000, immutable" else "no-store");
    if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.eql(u8, path, "/sw.js")) return respondRetirementWorker(request);
    if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.eql(u8, path, "/manifest.webmanifest")) return respondStatic(request, .ok, "application/manifest+json; charset=utf-8", manifest, "public, max-age=0, must-revalidate");
    if ((request.head.method == .GET or request.head.method == .HEAD) and (std.mem.eql(u8, path, "/assets/icon.svg") or std.mem.eql(u8, path, "/favicon.ico"))) return respondStatic(request, .ok, "image/svg+xml", icon, "public, max-age=3600");
    if ((request.head.method == .GET or request.head.method == .HEAD) and (std.mem.eql(u8, path, "/assets/icon-180.png") or std.mem.eql(u8, path, "/apple-touch-icon.png") or std.mem.eql(u8, path, "/apple-touch-icon-precomposed.png"))) return respondStatic(request, .ok, "image/png", icon_180, "public, max-age=3600");
    if ((request.head.method == .GET or request.head.method == .HEAD) and (std.mem.eql(u8, path, "/assets/icon-192.png") or std.mem.eql(u8, path, "/favicon.png"))) return respondStatic(request, .ok, "image/png", icon_192, "public, max-age=3600");
    if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.eql(u8, path, "/assets/icon-512.png")) return respondStatic(request, .ok, "image/png", icon_512, "public, max-age=3600");

    if (parseJobRoute(path)) |route| {
        if ((request.head.method == .GET or request.head.method == .HEAD) and route.action.len == 0) return jobPage(app, arena, request, route.id);
        if (request.head.method == .GET and std.mem.eql(u8, route.action, "events")) return jobEvents(app, request, route.id);
        if ((request.head.method == .GET or request.head.method == .HEAD) and std.mem.startsWith(u8, route.action, "artifact/")) return artifact(app, arena, request, route.id, route.action["artifact/".len..]);
        if (request.head.method == .POST and std.mem.eql(u8, route.action, "start")) return startJob(app, arena, request, route.id);
        if (request.head.method == .POST and std.mem.eql(u8, route.action, "cancel")) return cancelJob(app, request, route.id);
        if (request.head.method == .POST and std.mem.eql(u8, route.action, "delete")) return deleteJob(app, request, route.id);
        if (request.head.method == .POST and std.mem.eql(u8, route.action, "use-original")) return useOriginal(app, request, route.id);
        if (request.head.method == .POST and std.mem.eql(u8, route.action, "shared")) return shareCompleted(app, arena, request, route.id);
    }
    return problem(request, .not_found, "Not found", "This temporary job or page no longer exists.");
}

fn createJob(app: *App, arena: std.mem.Allocator, request: *std.http.Server.Request, client: ClientContext) !void {
    const rate_key = clientRateKey(request, client);
    const form = parseRequestForm(arena, request) catch |err| switch (err) {
        error.BodyTooLarge => return problem(request, .payload_too_large, "Link too long", "Submit one public X status link no longer than 4096 characters."),
        else => return problem(request, .bad_request, "Invalid form", "Submit one public X or Twitter status link."),
    };
    const source_url = form.url orelse return problem(request, .bad_request, "Missing link", "Paste one public X or Twitter status link.");
    const advanced = if (form.advanced) |value|
        if (std.mem.eql(u8, value, "1")) true else return problem(request, .unprocessable_entity, "Invalid choice mode", "Use the normal save action or Choose quality or format.")
    else
        false;
    var host_buffer: [512]u8 = undefined;
    const validated = media_url.validate(source_url, &host_buffer) catch return problem(request, .unprocessable_entity, "That link is not allowed", "Use a public X or Twitter status link without credentials or a private network address.");
    if (!x.matches(source_url)) return problem(request, .unprocessable_entity, "This link is not supported", "xvid currently accepts public X and Twitter status links only.");
    if (!(app.hasMinimumFreeSpace() catch false)) return problem(request, .service_unavailable, "Storage is unavailable", "xvid is preserving its configured free-space floor. Try again after existing jobs expire.");
    switch (app.rate_limiter.allow(rate_key, now(app.io))) {
        .allowed => {},
        .probes_limited => return problem(request, .too_many_requests, "Too many link checks", "Wait about a minute before checking another X post."),
        .jobs_limited => return problem(request, .too_many_requests, "Too many downloads", "This address has reached the bounded hourly download allowance."),
        .table_full => return problem(request, .service_unavailable, "The service is busy", "Try again after inactive client entries expire."),
    }
    const intent = if (advanced) job_mod.Intent.inspect else job_mod.Intent.save_original;
    const job = app.registry.create(source_url, intent, now(app.io)) catch |err| switch (err) {
        error.RegistryFull => return problem(request, .service_unavailable, "xvid is full", "Try again after existing temporary jobs expire."),
        else => return err,
    };
    app.usage_store.recordCreated(job.data.id, job.data.created_at, validated.host, intent) catch |err| {
        var id: [job_mod.id_length]u8 = undefined;
        @memcpy(&id, job.data.id);
        _ = app.registry.delete(&id) catch false;
        std.log.warn("usage job create failed job_id={s} error={s}", .{ &id, @errorName(err) });
        return problem(request, .service_unavailable, "Usage records are unavailable", "xvid could not durably record this job. Try again shortly.");
    };
    if (!try app.enqueueProbe(job.data.id)) {
        _ = try app.registry.fail(job.data.id, "QUEUE_FULL", "The link-check queue was full before this job could start.", now(app.io), app.config.terminal_ttl_seconds);
        app.syncUsage(job.data.id);
        _ = try app.registry.delete(job.data.id);
        return problem(request, .service_unavailable, "Link checks are full", "Try again after an existing check completes.");
    }
    std.log.info("job_created job_id={s} source_host={s} state=probing intent={s}", .{ job.data.id, validated.host, @tagName(intent) });
    return redirectCreatedJob(request, job.data.id, intent == .save_original);
}

fn jobPage(app: *App, arena: std.mem.Allocator, request: *std.http.Server.Request, id: []const u8) !void {
    const snapshot = (try app.registry.snapshot(arena, id)) orelse return redirect(request, "/");
    return respondJobPage(request, snapshot, hasQueryFlag(request.head.target, "auto=1"));
}

fn jobEvents(app: *App, request: *std.http.Server.Request, id: []const u8) !void {
    const previous = app.open_sse.fetchAdd(1, .acq_rel);
    if (previous >= app.config.max_open_sse) {
        _ = app.open_sse.fetchSub(1, .acq_rel);
        return problem(request, .service_unavailable, "Live updates are full", "The page will retry shortly.");
    }
    defer _ = app.open_sse.fetchSub(1, .acq_rel);
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-cache, no-transform" },
        .{ .name = "x-accel-buffering", .value = "no" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    if (app.registry.findLocked(id)) |locked| locked.unlock() else return request.respond("event: deleted\ndata: deleted\n\n", .{ .status = .ok, .extra_headers = &headers });
    const resume_revision: u64 = if (header(request, "last-event-id")) |value| std.fmt.parseInt(u64, value, 10) catch 0 else 0;

    var response_buffer: [8 * 1024]u8 = undefined;
    var response = try request.respondStreaming(&response_buffer, .{ .respond_options = .{ .status = .ok, .extra_headers = &headers } });
    var last_revision = resume_revision;
    var ticks: u16 = 0;
    while (ticks < 1200) : (ticks += 1) {
        var arena_state = std.heap.ArenaAllocator.init(app.allocator);
        defer arena_state.deinit();
        const snapshot = (try app.registry.snapshot(arena_state.allocator(), id)) orelse {
            try response.writer.writeAll("event: deleted\ndata: deleted\n\n");
            try response.writer.flush();
            break;
        };
        if (snapshot.revision != last_revision) {
            var fragment_buffer: [64 * 1024]u8 = undefined;
            var fragment: std.Io.Writer = .fixed(&fragment_buffer);
            try render.jobState(&fragment, snapshot);
            try response.writer.print("event: job\nid: {d}\n", .{snapshot.revision});
            try writeSseData(&response.writer, fragment.buffered());
            try response.writer.writeByte('\n');
            try response.writer.flush();
            last_revision = snapshot.revision;
            if (snapshot.data.state.terminal()) {
                try response.writer.writeAll("event: done\ndata: done\n\n");
                try response.writer.flush();
                break;
            }
        } else if (ticks > 0 and ticks % 200 == 0) {
            try response.writer.writeAll(": keep-alive\n\n");
            try response.writer.flush();
        }
        sleepMilliseconds(50);
    }
    try response.end();
}

fn artifact(app: *App, arena: std.mem.Allocator, request: *std.http.Server.Request, id: []const u8, artifact_id: []const u8) !void {
    const previous = app.open_artifacts.fetchAdd(1, .acq_rel);
    if (previous >= app.config.max_artifact_streams) {
        _ = app.open_artifacts.fetchSub(1, .acq_rel);
        return problem(request, .service_unavailable, "Downloads are full", "Try this file again in a moment.");
    }
    defer _ = app.open_artifacts.fetchSub(1, .acq_rel);
    if (artifact_id.len == 0 or artifact_id.len > 64 or std.mem.indexOfAny(u8, artifact_id, "/\\\r\n\x00") != null) return problem(request, .not_found, "File not found", "This artifact is not listed for the job.");
    const snapshot = (try app.registry.snapshot(arena, id)) orelse return problem(request, .not_found, "Job not found", "It may have expired or been deleted.");
    const artifact_value = findArtifact(snapshot, artifact_id) orelse return problem(request, .not_found, "File not found", "This artifact is not listed for the job.");
    const poster_requested = wantsPoster(request.head.target);
    const ServedFile = struct { path: []const u8, mime_type: []const u8, size: u64 };
    const served: ServedFile = if (poster_requested) blk: {
        const poster = artifact_value.poster orelse return problem(request, .not_found, "Preview unavailable", "This video does not have a local preview image.");
        break :blk .{ .path = poster.path, .mime_type = poster.mime_type, .size = poster.size_bytes };
    } else .{ .path = artifact_value.path, .mime_type = artifact_value.mime_type, .size = artifact_value.size_bytes };
    const path = try app.registry.jobPathAlloc(arena, id, served.path);
    const file = std.Io.Dir.cwd().openFile(app.io, path, .{ .allow_directory = false, .follow_symlinks = false }) catch return problem(request, .not_found, "File unavailable", "The recorded artifact is no longer on disk.");
    defer file.close(app.io);
    const stat = try file.stat(app.io);
    if (stat.kind != .file or stat.size != served.size) return problem(request, .internal_server_error, "File verification failed", "The artifact no longer matches its manifest.");

    const requested_range = if (header(request, "range")) |value| range_mod.parse(value, stat.size) catch return rangeProblem(request, stat.size) else null;
    const selected = requested_range orelse range_mod.ByteRange{ .start = 0, .end = stat.size - 1 };
    var content_range_buffer: [128]u8 = undefined;
    const content_range = if (requested_range != null) try std.fmt.bufPrint(&content_range_buffer, "bytes {d}-{d}/{d}", .{ selected.start, selected.end, stat.size }) else "";
    var disposition_buffer: [512]u8 = undefined;
    const disposition = try std.fmt.bufPrint(&disposition_buffer, "{s}; filename=\"{s}\"", .{ if (wantsDownload(request.head.target)) "attachment" else "inline", artifact_value.filename });
    var headers: [8]std.http.Header = undefined;
    var header_count: usize = 0;
    headers[header_count] = .{ .name = "content-type", .value = served.mime_type };
    header_count += 1;
    if (!poster_requested) {
        headers[header_count] = .{ .name = "content-disposition", .value = disposition };
        header_count += 1;
    }
    headers[header_count] = .{ .name = "accept-ranges", .value = "bytes" };
    header_count += 1;
    headers[header_count] = .{ .name = "cache-control", .value = "private, no-store" };
    header_count += 1;
    headers[header_count] = .{ .name = "x-content-type-options", .value = "nosniff" };
    header_count += 1;
    if (requested_range != null) {
        headers[header_count] = .{ .name = "content-range", .value = content_range };
        header_count += 1;
    }
    var response_buffer: [16 * 1024]u8 = undefined;
    var response = try request.respondStreaming(&response_buffer, .{
        .content_length = selected.length(),
        .respond_options = .{
            .status = if (requested_range != null) .partial_content else .ok,
            .extra_headers = headers[0..header_count],
        },
    });
    if (request.head.method == .HEAD) {
        var virtual_remaining = selected.length();
        while (virtual_remaining > 0) {
            const count: usize = @intCast(@min(virtual_remaining, std.math.maxInt(usize)));
            try response.writer.splatByteAll(0, count);
            virtual_remaining -= count;
        }
    } else {
        var reader_buffer: [32 * 1024]u8 = undefined;
        var reader = file.reader(app.io, &reader_buffer);
        try reader.seekTo(selected.start);
        var transfer_buffer: [64 * 1024]u8 = undefined;
        var remaining = selected.length();
        while (remaining > 0) {
            const wanted: usize = @intCast(@min(remaining, transfer_buffer.len));
            const read = reader.interface.readSliceShort(transfer_buffer[0..wanted]) catch return reader.err.?;
            if (read == 0) return error.UnexpectedArtifactEof;
            try response.writer.writeAll(transfer_buffer[0..read]);
            remaining -= @intCast(read);
        }
    }
    try response.end();
    if (!poster_requested and request.head.method == .GET and requested_range == null and wantsDownload(request.head.target)) {
        app.usage_store.recordDelivery(id, .download_response_complete, artifact_value.id, 1, artifact_value.size_bytes, now(app.io)) catch |err| {
            std.log.warn("usage delivery write failed job_id={s} kind=download_response_complete error={s}", .{ id, @errorName(err) });
        };
    }
}

fn findArtifact(snapshot: job_mod.Snapshot, id: []const u8) ?job_mod.Artifact {
    for (snapshot.data.output_artifacts) |candidate| if (std.mem.eql(u8, candidate.id, id)) return candidate;
    for (snapshot.data.source_artifacts) |candidate| if (std.mem.eql(u8, candidate.id, id)) return candidate;
    return null;
}

fn wantsDownload(target: []const u8) bool {
    return hasQueryFlag(target, "download=1");
}

fn wantsPoster(target: []const u8) bool {
    return hasQueryFlag(target, "poster=1");
}

fn hasQueryFlag(target: []const u8, flag: []const u8) bool {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    var parameters = std.mem.splitScalar(u8, target[question + 1 ..], '&');
    while (parameters.next()) |parameter| if (std.mem.eql(u8, parameter, flag)) return true;
    return false;
}

fn rangeProblem(request: *std.http.Server.Request, size: u64) !void {
    var value_buffer: [64]u8 = undefined;
    const value = try std.fmt.bufPrint(&value_buffer, "bytes */{d}", .{size});
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "content-range", .value = value },
        .{ .name = "accept-ranges", .value = "bytes" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond("range not satisfiable\n", .{ .status = .range_not_satisfiable, .extra_headers = &headers });
}

fn startJob(app: *App, arena: std.mem.Allocator, request: *std.http.Server.Request, id: []const u8) !void {
    const form = parseRequestForm(arena, request) catch return problem(request, .bad_request, "Invalid choice", "Choose available media and one file treatment.");
    const locked = app.registry.findLocked(id) orelse return redirect(request, "/");
    defer locked.unlock();
    const job = locked.job;
    if (job.data.state != .awaiting_choice) return redirectJob(request, id);
    const probe = job.data.probe orelse return problem(request, .conflict, "The link check is incomplete", "Refresh and use the actions currently shown.");
    if (probe.engine != .x_native) return problem(request, .gone, "This source path was retired", "Check the public X link again with the current native resolver.");

    const kind = if (form.kind) |value| std.meta.stringToEnum(job_mod.SelectionKind, value) orelse return problem(request, .unprocessable_entity, "Invalid media choice", "Choose one available media option.") else switch (probe.media_kind) {
        .mixed => job_mod.SelectionKind.all,
        .image => job_mod.SelectionKind.image,
        .video => job_mod.SelectionKind.video,
        else => return problem(request, .unprocessable_entity, "Unsupported media", "This native X media shape cannot be selected."),
    };
    if (kind == .audio) return problem(request, .unprocessable_entity, "Audio-only is unavailable", "The native X-only release saves the attached video or photos.");
    if (kind == .image and probe.media_kind != .image) return problem(request, .unprocessable_entity, "Photos are unavailable", "Choose the available X media.");
    if (kind == .all and probe.media_kind != .mixed) return problem(request, .unprocessable_entity, "All media is unavailable", "Choose the available X media.");
    if (kind == .video and probe.video_count == 0) return problem(request, .unprocessable_entity, "Video is unavailable", "Choose the available X media.");

    var selected_label: []const u8 = switch (kind) {
        .all => "All attached media",
        .video => "Best available video",
        .audio => unreachable,
        .image => "Original photos",
    };
    var selected_variant: ?[]const u8 = null;
    var selected_height: ?u32 = null;
    if (kind == .video) {
        const wanted = form.variant orelse return problem(request, .unprocessable_entity, "Choose video quality", "Choose one available video quality.");
        const variant = for (probe.variants) |candidate| {
            if (std.mem.eql(u8, candidate.id, wanted)) break candidate;
        } else return problem(request, .unprocessable_entity, "Video quality changed", "Refresh and choose one of the current options.");
        selected_variant = wanted;
        selected_label = variant.label;
        selected_height = variant.height orelse probe.source_height;
    }

    const mode = if (form.delivery) |value| std.meta.stringToEnum(job_mod.DeliveryMode, value) orelse return problem(request, .unprocessable_entity, "Invalid file preparation", "Choose Keep source file, Compatible MP4, or Smaller MP4.") else job_mod.DeliveryMode.original;
    if ((kind == .image or kind == .all or probe.item_count > 1) and mode != .original) return problem(request, .unprocessable_entity, "These files stay original", "Multi-item and photo jobs are delivered as source files.");
    if (!(app.canStartMedia(probe.item_count, mode) catch false)) return problem(request, .service_unavailable, "Not enough bounded storage", "This job cannot start without crossing the configured storage budget or free-space floor.");

    const target_height = if (mode == .downscale) blk: {
        const raw = form.target_height orelse return problem(request, .unprocessable_entity, "Choose a target resolution", "Smaller MP4 requires a lower output resolution.");
        const target = std.fmt.parseInt(u32, raw, 10) catch return problem(request, .unprocessable_entity, "Invalid target resolution", "Choose one of the lower resolutions shown.");
        const ceiling = selected_height orelse return problem(request, .unprocessable_entity, "Unknown source resolution", "This video cannot be safely downscaled without a known source height.");
        if (target >= ceiling or target < 144) return problem(request, .unprocessable_entity, "Invalid target resolution", "The target must be lower than the selected source quality.");
        break :blk target;
    } else null;

    const allocator = job.arena.allocator();
    job.data.selection = .{
        .kind = kind,
        .variant_id = if (selected_variant) |value| try allocator.dupe(u8, value) else null,
        .label = try allocator.dupe(u8, selected_label),
    };
    job.data.delivery = .{ .mode = mode, .target_height = target_height };
    try job.transition(.queued, now(app.io), app.config.terminal_ttl_seconds);
    job.progress = .{ .phase = .queued, .label = "Waiting to start", .updated_at = now(app.io) };
    try app.registry.persistLocked(job);
    if (!try app.enqueueMedia(id)) std.log.warn("media_queue_full job_id={s} state=queued recovery=scheduled", .{id});
    std.log.info("job_started job_id={s} source_host={s} state=queued delivery={s} items={d}", .{ id, probe.source_host, @tagName(mode), probe.item_count });
    return redirectJob(request, id);
}

fn cancelJob(app: *App, request: *std.http.Server.Request, id: []const u8) !void {
    const now_value = now(app.io);
    const initial = app.registry.findLocked(id) orelse return redirect(request, "/");
    if (initial.job.data.state == .probing) {
        const job = initial.job;
        job.cancel_requested.store(true, .release);
        job.data.state = .cancelled;
        job.data.updated_at = now_value;
        job.data.expires_at = now_value + @as(i64, @intCast(app.config.terminal_ttl_seconds));
        job.progress = .{ .phase = .ready, .label = "Cancelled", .updated_at = now_value };
        job.revision +%= 1;
        try app.registry.persistLocked(job);
        initial.unlock();
        app.syncUsage(id);
        std.log.info("job_cancelled job_id={s} state=cancelled phase=probing", .{id});
        return redirectJob(request, id);
    }
    initial.unlock();

    const changed = app.registry.transition(id, .cancelled, now_value, app.config.terminal_ttl_seconds) catch |err| switch (err) {
        error.InvalidStateTransition => return redirectJob(request, id),
        else => return err,
    };
    if (!changed) return redirect(request, "/");
    app.syncUsage(id);
    std.log.info("job_cancelled job_id={s} state=cancelled", .{id});
    return redirectJob(request, id);
}

fn deleteJob(app: *App, request: *std.http.Server.Request, id: []const u8) !void {
    const deleted = deletion: {
        for (0..60) |_| {
            const value = app.registry.delete(id) catch |err| switch (err) {
                error.JobBusy => {
                    sleepMilliseconds(50);
                    continue;
                },
                else => return err,
            };
            break :deletion value;
        }
        return problem(request, .conflict, "Job is still stopping", "Cancel active work first, then retry after the current network or media operation exits.");
    };
    if (deleted) {
        std.log.info("job_deleted job_id={s}", .{id});
    } else {
        for (0..60) |_| {
            if (try app.registry.jobDirectoryAbsent(id)) return redirect(request, "/");
            sleepMilliseconds(50);
        }
        return problem(request, .service_unavailable, "Files could not be deleted", "The job record is gone, but its files are still present. Try again shortly.");
    }
    return redirect(request, "/");
}

fn useOriginal(app: *App, request: *std.http.Server.Request, id: []const u8) !void {
    const changed = app.registry.useOriginal(id, now(app.io), app.config.terminal_ttl_seconds) catch |err| switch (err) {
        error.OriginalUnavailable => return problem(request, .conflict, "The source file is not ready", "Wait until source acquisition completes."),
        else => return err,
    };
    if (!changed) return redirect(request, "/");
    app.syncUsage(id);
    std.log.info("job_use_original job_id={s} state=ready delivery=original", .{id});
    return redirectJob(request, id);
}

fn shareCompleted(app: *App, arena: std.mem.Allocator, request: *std.http.Server.Request, id: []const u8) !void {
    const form = parseRequestForm(arena, request) catch return problem(request, .bad_request, "Invalid share record", "The completed save handoff could not be recorded.");
    const raw_ids = form.artifacts orelse return problem(request, .bad_request, "Invalid share record", "The completed save handoff did not identify its files.");
    if (raw_ids.len == 0 or raw_ids.len > 8 * 65) return problem(request, .unprocessable_entity, "Invalid share record", "The completed save handoff identified too many files.");
    const snapshot = (try app.registry.snapshot(arena, id)) orelse return problem(request, .not_found, "Job not found", "It may have expired or been deleted.");
    if (snapshot.data.state != .ready and !(snapshot.data.state == .preparing and snapshot.source_available)) return problem(request, .conflict, "Save is not ready", "Only closed, ready files can be recorded as handed to the operating system.");
    var seen: [8][]const u8 = undefined;
    var count: u8 = 0;
    var bytes: u64 = 0;
    var ids = std.mem.splitScalar(u8, raw_ids, ',');
    while (ids.next()) |artifact_id| {
        if (count == seen.len or artifact_id.len == 0 or artifact_id.len > 64) return problem(request, .unprocessable_entity, "Invalid share record", "The save handoff identified too many files.");
        for (seen[0..count]) |existing| if (std.mem.eql(u8, existing, artifact_id)) return problem(request, .unprocessable_entity, "Invalid share record", "The save handoff repeated a file.");
        const artifact_value = findArtifact(snapshot, artifact_id) orelse return problem(request, .unprocessable_entity, "Invalid share record", "The save handoff identified an unavailable file.");
        if (artifact_value.media_kind == .unknown or artifact_value.size_bytes > maximum_share_bytes) return problem(request, .unprocessable_entity, "Invalid share record", "The save handoff identified an unsupported file.");
        bytes = std.math.add(u64, bytes, artifact_value.size_bytes) catch return problem(request, .unprocessable_entity, "Invalid share record", "The save handoff was too large.");
        if (bytes > maximum_share_bytes) return problem(request, .unprocessable_entity, "Invalid share record", "The save handoff was too large.");
        seen[count] = artifact_id;
        count += 1;
    }
    if (count == 0) return problem(request, .unprocessable_entity, "Invalid share record", "The save handoff did not identify its files.");
    app.usage_store.recordDelivery(id, usage.DeliveryKind.share_handoff, raw_ids, count, bytes, now(app.io)) catch |err| {
        std.log.warn("usage delivery write failed job_id={s} kind=share_handoff error={s}", .{ id, @errorName(err) });
        return problem(request, .service_unavailable, "Usage records are unavailable", "The operating-system handoff completed, but xvid could not durably record it.");
    };
    return respondStatic(request, .no_content, "text/plain; charset=utf-8", "", "no-store");
}

fn parseJobRoute(path: []const u8) ?JobRoute {
    if (!std.mem.startsWith(u8, path, "/j/")) return null;
    const remaining = path[3..];
    const slash = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
    const id = remaining[0..slash];
    if (!job_mod.validId(id)) return null;
    return .{ .id = id, .action = if (slash == remaining.len) "" else remaining[slash + 1 ..] };
}

fn parseRequestForm(allocator: std.mem.Allocator, request: *std.http.Server.Request) !Form {
    const content_type = header(request, "content-type") orelse return error.InvalidContentType;
    if (!std.ascii.startsWithIgnoreCase(content_type, "application/x-www-form-urlencoded")) return error.InvalidContentType;
    const body = try readBody(allocator, request, max_form_bytes);
    var form = Form{};
    var remaining = body;
    var count: usize = 0;
    while (remaining.len > 0) {
        if (count == 16) return error.TooManyFields;
        count += 1;
        const end = std.mem.indexOfScalar(u8, remaining, '&') orelse remaining.len;
        const pair = remaining[0..end];
        remaining = if (end == remaining.len) "" else remaining[end + 1 ..];
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const name = try decodeComponent(allocator, pair[0..equals]);
        const value = try decodeComponent(allocator, if (equals == pair.len) "" else pair[equals + 1 ..]);
        if (std.mem.eql(u8, name, "url")) try setOnce(&form.url, value) else if (std.mem.eql(u8, name, "advanced")) try setOnce(&form.advanced, value) else if (std.mem.eql(u8, name, "artifacts")) try setOnce(&form.artifacts, value) else if (std.mem.eql(u8, name, "kind")) try setOnce(&form.kind, value) else if (std.mem.eql(u8, name, "variant")) try setOnce(&form.variant, value) else if (std.mem.eql(u8, name, "delivery")) try setOnce(&form.delivery, value) else if (std.mem.eql(u8, name, "target_height")) try setOnce(&form.target_height, value);
    }
    return form;
}

fn setOnce(target: *?[]const u8, value: []const u8) !void {
    if (target.* != null) return error.DuplicateField;
    target.* = value;
}

fn decodeComponent(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(output);
    var source_index: usize = 0;
    var destination: usize = 0;
    while (source_index < encoded.len) {
        if (encoded[source_index] == '%') {
            if (source_index + 2 >= encoded.len) return error.InvalidEncoding;
            const high = std.fmt.charToDigit(encoded[source_index + 1], 16) catch return error.InvalidEncoding;
            const low = std.fmt.charToDigit(encoded[source_index + 2], 16) catch return error.InvalidEncoding;
            output[destination] = @intCast(high * 16 + low);
            source_index += 3;
        } else {
            output[destination] = if (encoded[source_index] == '+') ' ' else encoded[source_index];
            source_index += 1;
        }
        if (output[destination] == 0) return error.InvalidEncoding;
        destination += 1;
    }
    if (destination == output.len) return output;
    return try allocator.realloc(output, destination);
}

fn readBody(allocator: std.mem.Allocator, request: *std.http.Server.Request, maximum: u64) ![]u8 {
    if (!request.head.method.requestHasBody()) return error.MissingBody;
    if (request.head.content_length) |length| if (length > maximum) return error.BodyTooLarge;
    var transfer_buffer: [8 * 1024]u8 = undefined;
    const reader = try request.readerExpectContinue(&transfer_buffer);
    return reader.allocRemaining(allocator, .limited(maximum)) catch |err| switch (err) {
        error.StreamTooLong => error.BodyTooLarge,
        else => err,
    };
}

fn header(request: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var iterator = request.iterateHeaders();
    while (iterator.next()) |entry| if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    return null;
}

fn mutationAllowed(request: *const std.http.Server.Request, public_origin: []const u8) bool {
    return originAllowed(header(request, "sec-fetch-site"), header(request, "origin"), public_origin);
}

fn originAllowed(fetch_site: ?[]const u8, origin: ?[]const u8, public_origin: []const u8) bool {
    if (fetch_site) |site| {
        if (!std.ascii.eqlIgnoreCase(site, "same-origin") and !std.ascii.eqlIgnoreCase(site, "none")) return false;
    }
    if (origin) |value| return std.mem.eql(u8, value, public_origin);
    return true;
}

fn clientRateKey(request: *const std.http.Server.Request, client: ClientContext) u64 {
    if (!client.peer_is_loopback) return client.peer_key;
    const forwarded = header(request, "x-forwarded-for") orelse return client.peer_key;
    const comma = std.mem.lastIndexOfScalar(u8, forwarded, ',');
    const start = if (comma) |index| index + 1 else 0;
    const candidate = std.mem.trim(u8, forwarded[start..], " \t");
    if (candidate.len == 0 or candidate.len > 64) return client.peer_key;
    var separator = false;
    for (candidate) |byte| {
        if (byte == '.' or byte == ':') separator = true else if (!std.ascii.isHex(byte)) return client.peer_key;
    }
    if (!separator) return client.peer_key;
    return std.hash.Wyhash.hash(0x78766964, candidate);
}

fn redirectJob(request: *std.http.Server.Request, id: []const u8) !void {
    var location_buffer: [64]u8 = undefined;
    const location = try std.fmt.bufPrint(&location_buffer, "/j/{s}", .{id});
    return redirect(request, location);
}

fn redirectCreatedJob(request: *std.http.Server.Request, id: []const u8, automatic_delivery: bool) !void {
    if (!automatic_delivery) return redirectJob(request, id);
    var location_buffer: [72]u8 = undefined;
    const location = try std.fmt.bufPrint(&location_buffer, "/j/{s}?auto=1", .{id});
    return redirect(request, location);
}

fn writeSseData(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll("data: ");
    var index: usize = 0;
    while (index < value.len) : (index += 1) switch (value[index]) {
        '\r' => {
            if (index + 1 < value.len and value[index + 1] == '\n') index += 1;
            try writer.writeAll("\ndata: ");
        },
        '\n' => try writer.writeAll("\ndata: "),
        else => try writer.writeByte(value[index]),
    };
    try writer.writeByte('\n');
}

fn redirect(request: *std.http.Server.Request, location: []const u8) !void {
    const headers = [_]std.http.Header{
        .{ .name = "location", .value = location },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    try request.respond("", .{ .status = .see_other, .extra_headers = &headers });
}

fn isLegacyNavigation(path: []const u8) bool {
    return std.mem.eql(u8, path, "/app") or std.mem.eql(u8, path, "/app/") or std.mem.eql(u8, path, "/incoming-share") or std.mem.eql(u8, path, "/incoming-share/") or std.mem.eql(u8, path, "/job") or std.mem.startsWith(u8, path, "/job/");
}

fn redirectLegacyNavigation(request: *std.http.Server.Request) !void {
    const headers = [_]std.http.Header{
        .{ .name = "location", .value = "/" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "clear-site-data", .value = "\"cache\", \"storage\"" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "referrer-policy", .value = "no-referrer" },
    };
    try request.respond("", .{ .status = .see_other, .extra_headers = &headers });
}

fn retiredApi(request: *std.http.Server.Request) !void {
    const body = "{\"detail\":\"xvid was updated. Reload this page to continue.\"}\n";
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "clear-site-data", .value = "\"cache\", \"storage\"" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "referrer-policy", .value = "no-referrer" },
        .{ .name = "x-frame-options", .value = "DENY" },
        .{ .name = "content-security-policy", .value = "default-src 'none'; frame-ancestors 'none'" },
    };
    try request.respond(body, .{ .status = .gone, .extra_headers = &headers });
}

fn respondRetirementWorker(request: *std.http.Server.Request) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/javascript; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "service-worker-allowed", .value = "/" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "referrer-policy", .value = "no-referrer" },
        .{ .name = "content-security-policy", .value = "default-src 'self'; connect-src 'self'; script-src 'self'" },
    };
    try request.respond(retire_sw, .{ .status = .ok, .extra_headers = &headers });
}

fn respondStatic(request: *std.http.Server.Request, status: std.http.Status, content_type: []const u8, body: []const u8, cache_control: []const u8) !void {
    const headers = responseHeaders(content_type, cache_control);
    try request.respond(body, .{ .status = status, .extra_headers = &headers });
}

fn respondJobPage(request: *std.http.Server.Request, snapshot: job_mod.Snapshot, automatic_navigation: bool) !void {
    var buffer: [16 * 1024]u8 = undefined;
    const headers = responseHeaders("text/html; charset=utf-8", "no-store");
    var response = try request.respondStreaming(&buffer, .{ .respond_options = .{ .status = .ok, .extra_headers = &headers } });
    try render.jobPage(&response.writer, snapshot, automatic_navigation);
    try response.end();
}

fn problem(request: *std.http.Server.Request, status: std.http.Status, title: []const u8, message: []const u8) !void {
    var buffer: [8 * 1024]u8 = undefined;
    const headers = responseHeaders("text/html; charset=utf-8", "no-store");
    var response = try request.respondStreaming(&buffer, .{ .respond_options = .{ .status = status, .extra_headers = &headers } });
    try render.errorPage(&response.writer, title, message);
    try response.end();
}

fn responseHeaders(content_type: []const u8, cache_control: []const u8) [7]std.http.Header {
    return .{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = cache_control },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "referrer-policy", .value = "no-referrer" },
        .{ .name = "x-frame-options", .value = "DENY" },
        .{ .name = "permissions-policy", .value = "camera=(), microphone=(), geolocation=(), clipboard-read=(self), clipboard-write=(self)" },
        .{ .name = "content-security-policy", .value = "default-src 'self'; base-uri 'none'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self'; manifest-src 'self'" },
    };
}

fn now(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

fn sleepMilliseconds(milliseconds: u32) void {
    var request: std.c.timespec = .{ .sec = @intCast(milliseconds / 1000), .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms) };
    var remaining: std.c.timespec = undefined;
    _ = std.c.nanosleep(&request, &remaining);
}

test "job route parsing is strict" {
    const route = parseJobRoute("/j/0123456789abcdef0123456789abcdef/start").?;
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", route.id);
    try std.testing.expectEqualStrings("start", route.action);
    try std.testing.expect(parseJobRoute("/j/../delete") == null);
}

test "form component decoding is bounded and strict" {
    const allocator = std.testing.allocator;
    const decoded = try decodeComponent(allocator, "https%3A%2F%2Fx.com%2Fu%2Fstatus%2F1");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("https://x.com/u/status/1", decoded);
    try std.testing.expectError(error.InvalidEncoding, decodeComponent(allocator, "%GG"));
}

test "cross-site browser mutations are rejected while direct clients remain usable" {
    try std.testing.expect(originAllowed("same-origin", "https://xvid.example", "https://xvid.example"));
    try std.testing.expect(!originAllowed("cross-site", "https://evil.example", "https://xvid.example"));
    try std.testing.expect(!originAllowed("same-site", null, "https://xvid.example"));
    try std.testing.expect(originAllowed(null, null, "https://xvid.example"));
}
