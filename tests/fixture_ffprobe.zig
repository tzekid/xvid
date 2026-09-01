const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingInput;
    const input = args[args.len - 1];
    const file = try std.Io.Dir.cwd().openFile(init.io, input, .{ .allow_directory = false });
    defer file.close(init.io);
    var reader_buffer: [1024]u8 = undefined;
    var reader = file.reader(init.io, &reader_buffer);
    var content: [1024]u8 = undefined;
    const count = try reader.interface.readSliceShort(&content);
    const bytes = content[0..count];
    if (std.mem.indexOf(u8, bytes, "ffprobe-reject") != null) std.process.exit(9);

    const prepared = std.mem.indexOf(u8, bytes, "fixture-output") != null;
    const compatible = prepared or std.mem.indexOf(u8, bytes, "compatible") != null;
    const height = parseHeight(bytes) orelse 1080;
    const video_codec = if (compatible) "h264" else "vp9";
    const audio_codec = if (compatible) "aac" else "opus";

    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output.interface.print(
        "{{\"streams\":[{{\"codec_type\":\"video\",\"codec_name\":\"{s}\",\"width\":1920,\"height\":{d},\"pix_fmt\":\"yuv420p\"}},{{\"codec_type\":\"audio\",\"codec_name\":\"{s}\"}}],\"format\":{{\"duration\":\"42.4\"}}}}\n",
        .{ video_codec, height, audio_codec },
    );
    try output.interface.flush();
}

fn parseHeight(bytes: []const u8) ?u32 {
    const start = (std.mem.indexOf(u8, bytes, "height=") orelse return null) + "height=".len;
    var end = start;
    while (end < bytes.len and std.ascii.isDigit(bytes[end])) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u32, bytes[start..end], 10) catch null;
}
