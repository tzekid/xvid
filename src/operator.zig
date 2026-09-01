const std = @import("std");
const job_mod = @import("job.zig");

pub fn list(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, data_root: []const u8) !void {
    const ids = try jobIds(allocator, io, data_root);
    defer allocator.free(ids);
    for (ids) |id| {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const data = load(arena_state.allocator(), io, data_root, &id) catch {
            try std.json.Stringify.value(.{
                .id = @as([]const u8, &id),
                .error_code = "INVALID_MANIFEST",
            }, .{}, writer);
            try writer.writeByte('\n');
            continue;
        };
        try std.json.Stringify.value(.{
            .id = data.id,
            .state = data.state,
            .updated_at = data.updated_at,
            .expires_at = data.expires_at,
            .title = if (data.probe) |probe| probe.title else null,
            .source_host = if (data.probe) |probe| probe.source_host else null,
            .source_artifacts = data.source_artifacts.len,
            .output_artifacts = data.output_artifacts.len,
        }, .{}, writer);
        try writer.writeByte('\n');
    }
}

pub fn inspect(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, data_root: []const u8, id: []const u8) !void {
    if (!job_mod.validId(id)) return error.InvalidJobId;
    const data = try load(allocator, io, data_root, id);
    const probe = if (data.probe) |value| .{
        .engine = value.engine,
        .title = value.title,
        .source_host = value.source_host,
        .media_kind = value.media_kind,
        .duration_seconds = value.duration_seconds,
        .source_height = value.source_height,
        .variants = value.variants,
        .audio_available = value.audio_available,
        .item_count = value.item_count,
        .video_count = value.video_count,
        .image_count = value.image_count,
        .thumbnail_available = value.thumbnail_url != null,
    } else null;
    const view = .{
        .version = data.version,
        .id = data.id,
        .intent = data.intent,
        .created_at = data.created_at,
        .updated_at = data.updated_at,
        .state = data.state,
        .probe = probe,
        .selection = data.selection,
        .delivery = data.delivery,
        .source_artifacts = data.source_artifacts,
        .output_artifacts = data.output_artifacts,
        .failure = data.failure,
        .warning = data.warning,
        .expires_at = data.expires_at,
    };
    try std.json.Stringify.value(view, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

pub fn prune(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, data_root: []const u8, apply: bool, now: i64) !usize {
    var ownership: ?std.Io.File = null;
    if (apply) ownership = try acquireOwnership(allocator, io, data_root);
    defer if (ownership) |file| file.close(io);
    const ids = try jobIds(allocator, io, data_root);
    defer allocator.free(ids);
    var count: usize = 0;
    for (ids) |id| {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const data = load(arena_state.allocator(), io, data_root, &id) catch continue;
        if (data.expires_at == null or data.expires_at.? > now) continue;
        count += 1;
        try writer.print("{s} {s}\n", .{ if (apply) "deleted" else "would-delete", &id });
        if (apply) {
            const directory = try std.fs.path.join(allocator, &.{ data_root, "jobs", &id });
            defer allocator.free(directory);
            try std.Io.Dir.cwd().deleteTree(io, directory);
        }
    }
    try writer.print("{s}: {d}\n", .{ if (apply) "deleted" else "candidates", count });
    return count;
}

pub fn acquireOwnership(allocator: std.mem.Allocator, io: std.Io, data_root: []const u8) !std.Io.File {
    const path = try std.fs.path.join(allocator, &.{ data_root, ".xvid.lock" });
    defer allocator.free(path);
    return std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = @fromBackingInt(@intCast(0o600)),
    }) catch |err| switch (err) {
        error.WouldBlock => error.DataDirectoryInUse,
        else => |other| other,
    };
}

fn load(allocator: std.mem.Allocator, io: std.Io, data_root: []const u8, id: []const u8) !job_mod.Data {
    const path = try std.fs.path.join(allocator, &.{ data_root, "jobs", id, "job.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024));
    const data = try std.json.parseFromSliceLeaky(job_mod.Data, allocator, bytes, .{ .ignore_unknown_fields = false });
    try job_mod.validateData(data, id);
    return data;
}

fn jobIds(allocator: std.mem.Allocator, io: std.Io, data_root: []const u8) ![][job_mod.id_length]u8 {
    const path = try std.fs.path.join(allocator, &.{ data_root, "jobs" });
    defer allocator.free(path);
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer directory.close(io);
    var ids: std.ArrayList([job_mod.id_length]u8) = .empty;
    defer ids.deinit(allocator);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory or !job_mod.validId(entry.name)) continue;
        var id: [job_mod.id_length]u8 = undefined;
        @memcpy(&id, entry.name);
        try ids.append(allocator, id);
    }
    std.mem.sort([job_mod.id_length]u8, ids.items, {}, lessThanId);
    return ids.toOwnedSlice(allocator);
}

fn lessThanId(_: void, left: [job_mod.id_length]u8, right: [job_mod.id_length]u8) bool {
    return std.mem.order(u8, &left, &right) == .lt;
}
