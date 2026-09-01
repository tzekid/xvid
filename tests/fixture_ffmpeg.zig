const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--descendant")) return descendant(init);
    const input = argumentAfter(args, "-i") orelse return error.MissingInput;
    if (args.len < 2) return error.MissingOutput;
    const output_path = args[args.len - 1];
    const source = try readPrefix(init, input);
    const target_height = scaleHeight(args) orelse 1080;

    const invoked = try std.Io.Dir.cwd().createFile(init.io, ".fixture-ffmpeg-invoked", .{ .permissions = @fromBackingInt(@intCast(0o600)) });
    invoked.close(init.io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try progress(&stdout.interface, 8_000_000, 2048, "0.75x", "continue");
    try stdout.interface.flush();
    try init.io.sleep(.fromMilliseconds(125), .awake);

    if (std.mem.indexOf(u8, source, "encode-fail") != null) std.process.exit(23);
    if (std.mem.indexOf(u8, source, "encode-stall") != null) {
        const executable = try std.process.executablePathAlloc(init.io, init.arena.allocator());
        _ = try std.process.spawn(init.io, .{
            .argv = &.{ executable, "--descendant" },
            .expand_arg0 = .no_expand,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        while (true) try init.io.sleep(.fromSeconds(1), .awake);
    }
    const output = try std.Io.Dir.cwd().createFile(init.io, output_path, .{ .permissions = @fromBackingInt(@intCast(0o600)) });
    defer output.close(init.io);
    var output_buffer: [4096]u8 = undefined;
    var writer = output.writer(init.io, &output_buffer);
    var header: [128]u8 = undefined;
    const header_value = try std.fmt.bufPrint(&header, "fixture-output height={d}\n", .{target_height});
    try writer.interface.writeAll(header_value);
    try writer.interface.splatByteAll(0x4f, 8192 - header_value.len);
    try writer.flush();
    try output.sync(init.io);
    try progress(&stdout.interface, 42_400_000, 8192, "1.25x", "end");
    try stdout.interface.flush();
}

fn argumentAfter(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args[0 .. args.len - 1], 0..) |argument, index| {
        if (std.mem.eql(u8, argument, name)) return args[index + 1];
    }
    return null;
}

fn scaleHeight(args: []const []const u8) ?u32 {
    const scale = argumentAfter(args, "-vf") orelse return null;
    const colon = std.mem.lastIndexOfScalar(u8, scale, ':') orelse return null;
    return std.fmt.parseInt(u32, scale[colon + 1 ..], 10) catch null;
}

fn readPrefix(init: std.process.Init, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{ .allow_directory = false });
    defer file.close(init.io);
    var reader_buffer: [2048]u8 = undefined;
    var reader = file.reader(init.io, &reader_buffer);
    const storage = try init.arena.allocator().alloc(u8, 2048);
    const count = try reader.interface.readSliceShort(storage);
    return storage[0..count];
}

fn progress(writer: *std.Io.Writer, microseconds: u64, size: u64, speed: []const u8, state: []const u8) !void {
    try writer.print("out_time_us={d}\ntotal_size={d}\nspeed={s}\nprogress={s}\n", .{ microseconds, size, speed, state });
}

fn descendant(init: std.process.Init) !void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &action, null);
    const pid_file = try std.Io.Dir.cwd().createFile(init.io, "ffmpeg-descendant.pid", .{ .permissions = @fromBackingInt(@intCast(0o600)) });
    defer pid_file.close(init.io);
    var buffer: [64]u8 = undefined;
    var writer = pid_file.writer(init.io, &buffer);
    try writer.interface.print("{d}\n", .{std.c.getpid()});
    try writer.flush();
    while (true) try init.io.sleep(.fromSeconds(1), .awake);
}
