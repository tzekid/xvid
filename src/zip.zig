const std = @import("std");
const job_mod = @import("job.zig");

const CentralEntry = struct {
    name: []const u8,
    crc32: u32,
    size: u32,
    local_offset: u32,
};

pub fn createBundle(
    result_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    io: std.Io,
    job_root: []const u8,
    artifacts: []const job_mod.Artifact,
    title: []const u8,
    maximum_bytes: u64,
) !job_mod.Artifact {
    if (artifacts.len < 2 or artifacts.len > job_mod.max_media_items) return error.InvalidBundleItemCount;
    const output_directory = try std.fs.path.join(scratch_allocator, &.{ job_root, "output" });
    defer scratch_allocator.free(output_directory);
    std.Io.Dir.cwd().deleteTree(io, output_directory) catch {};
    try std.Io.Dir.cwd().createDirPath(io, output_directory);
    const temporary_path = try std.fs.path.join(scratch_allocator, &.{ output_directory, "bundle.tmp.zip" });
    defer scratch_allocator.free(temporary_path);
    const final_path = try std.fs.path.join(scratch_allocator, &.{ output_directory, "bundle.zip" });
    defer scratch_allocator.free(final_path);
    const output = try std.Io.Dir.cwd().createFile(io, temporary_path, .{
        .read = true,
        .exclusive = true,
        .permissions = @fromBackingInt(@intCast(0o600)),
    });
    defer output.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, temporary_path) catch {};
    var writer_buffer: [64 * 1024]u8 = undefined;
    var output_writer = output.writer(io, &writer_buffer);
    const writer = &output_writer.interface;
    var entries: [job_mod.max_media_items]CentralEntry = undefined;
    var offset: u64 = 0;

    for (artifacts, 0..) |artifact, index| {
        if (artifact.size_bytes > std.math.maxInt(u32) or artifact.filename.len > std.math.maxInt(u16)) return error.Zip32Limit;
        const source_path = try std.fs.path.join(scratch_allocator, &.{ job_root, artifact.path });
        defer scratch_allocator.free(source_path);
        const crc = try crcFile(io, source_path, artifact.size_bytes);
        if (offset > std.math.maxInt(u32)) return error.Zip32Limit;
        entries[index] = .{
            .name = artifact.filename,
            .crc32 = crc,
            .size = @intCast(artifact.size_bytes),
            .local_offset = @intCast(offset),
        };
        try writeLocalHeader(writer, entries[index]);
        try copyFile(io, source_path, writer, artifact.size_bytes);
        offset += 30 + artifact.filename.len + artifact.size_bytes;
        if (offset > maximum_bytes) return error.OutputTooLarge;
    }

    const central_offset = offset;
    for (entries[0..artifacts.len]) |entry| {
        try writeCentralHeader(writer, entry);
        offset += 46 + entry.name.len;
        if (offset > maximum_bytes or offset > std.math.maxInt(u32)) return error.OutputTooLarge;
    }
    const central_size = offset - central_offset;
    if (central_offset > std.math.maxInt(u32) or central_size > std.math.maxInt(u32)) return error.Zip32Limit;
    try writeEndRecord(writer, @intCast(artifacts.len), @intCast(central_size), @intCast(central_offset));
    offset += 22;
    if (offset > maximum_bytes) return error.OutputTooLarge;
    try output_writer.flush();
    try output.sync(io);
    const stat = try output.stat(io);
    if (stat.kind != .file or stat.size != offset) return error.BundleSizeMismatch;
    try std.Io.Dir.cwd().rename(temporary_path, std.Io.Dir.cwd(), final_path, io);

    const safe_title = try safeFilenameBase(result_allocator, title);
    return .{
        .id = "bundle",
        .path = "output/bundle.zip",
        .filename = try std.fmt.allocPrint(result_allocator, "{s}-all.zip", .{safe_title}),
        .media_kind = .unknown,
        .mime_type = "application/zip",
        .size_bytes = stat.size,
    };
}

fn writeLocalHeader(writer: *std.Io.Writer, entry: CentralEntry) !void {
    try writer.writeInt(u32, 0x04034b50, .little);
    try writer.writeInt(u16, 20, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u32, entry.crc32, .little);
    try writer.writeInt(u32, entry.size, .little);
    try writer.writeInt(u32, entry.size, .little);
    try writer.writeInt(u16, @intCast(entry.name.len), .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeAll(entry.name);
}

fn writeCentralHeader(writer: *std.Io.Writer, entry: CentralEntry) !void {
    try writer.writeInt(u32, 0x02014b50, .little);
    try writer.writeInt(u16, 20, .little);
    try writer.writeInt(u16, 20, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u32, entry.crc32, .little);
    try writer.writeInt(u32, entry.size, .little);
    try writer.writeInt(u32, entry.size, .little);
    try writer.writeInt(u16, @intCast(entry.name.len), .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeInt(u32, entry.local_offset, .little);
    try writer.writeAll(entry.name);
}

fn writeEndRecord(writer: *std.Io.Writer, count: u16, central_size: u32, central_offset: u32) !void {
    try writer.writeInt(u32, 0x06054b50, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, count, .little);
    try writer.writeInt(u16, count, .little);
    try writer.writeInt(u32, central_size, .little);
    try writer.writeInt(u32, central_offset, .little);
    try writer.writeInt(u16, 0, .little);
}

fn crcFile(io: std.Io, path: []const u8, expected_size: u64) !u32 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != expected_size) return error.ArtifactMismatch;
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var crc = std.hash.Crc32.init();
    var buffer: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const count = reader.interface.readSliceShort(&buffer) catch return reader.err.?;
        if (count == 0) break;
        crc.update(buffer[0..count]);
        total += count;
    }
    if (total != expected_size) return error.ArtifactMismatch;
    return crc.final();
}

fn copyFile(io: std.Io, path: []const u8, writer: *std.Io.Writer, expected_size: u64) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var buffer: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const count = reader.interface.readSliceShort(&buffer) catch return reader.err.?;
        if (count == 0) break;
        try writer.writeAll(buffer[0..count]);
        total += count;
    }
    if (total != expected_size) return error.ArtifactMismatch;
}

fn safeFilenameBase(allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
    const maximum = @min(title.len, 80);
    const output = try allocator.alloc(u8, maximum + 5);
    var length: usize = 0;
    var dash = false;
    for (title[0..maximum]) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-') {
            output[length] = std.ascii.toLower(byte);
            length += 1;
            dash = false;
        } else if (!dash and length > 0) {
            output[length] = '-';
            length += 1;
            dash = true;
        }
    }
    while (length > 0 and output[length - 1] == '-') length -= 1;
    if (length == 0) {
        @memcpy(output[0..5], "media");
        length = 5;
    }
    return output[0..length];
}
