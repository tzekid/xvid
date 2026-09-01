const std = @import("std");
const builtin = @import("builtin");

pub const Limits = struct {
    stdout_bytes: usize,
    stderr_bytes: usize,
    timeout_seconds: u32,
    inactivity_seconds: u32 = 0,
    terminate_grace_seconds: u32 = 2,
};

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
    cancelled: bool,
    timed_out: bool,

    pub fn deinit(result: Result, allocator: std.mem.Allocator) void {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
};

pub const LineCallback = struct {
    context: *anyopaque,
    on_line: *const fn (context: *anyopaque, line: []const u8) anyerror!void,
};

pub const StreamingResult = struct {
    stderr: []u8,
    term: std.process.Child.Term,
    cancelled: bool,
    timed_out: bool,

    pub fn deinit(result: StreamingResult, allocator: std.mem.Allocator) void {
        allocator.free(result.stderr);
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: []const u8,
    environment: *const std.process.Environ.Map,
    limits: Limits,
    cancel: ?*const std.atomic.Value(bool),
) !Result {
    if (argv.len == 0 or limits.stdout_bytes == 0 or limits.stderr_bytes == 0 or limits.timeout_seconds == 0) return error.InvalidProcessOptions;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = environment,
        .expand_arg0 = .no_expand,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    errdefer {
        signalGroup(child, .KILL);
        child.kill(io);
    }
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(limits.timeout_seconds), .clock = .awake });
    var stopping_deadline: ?std.Io.Clock.Timestamp = null;
    var cancelled = false;
    var timed_out = false;
    var killed = false;

    while (true) {
        multi_reader.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {},
            else => |other| return other,
        };
        if (stdout_reader.buffered().len > limits.stdout_bytes or stderr_reader.buffered().len > limits.stderr_bytes) {
            signalGroup(child, .KILL);
            child.kill(io);
            killed = true;
            return error.StreamTooLong;
        }
        const current = std.Io.Clock.Timestamp.now(io, .awake);
        if (deadline.compare(.lte, current) and stopping_deadline == null) {
            timed_out = true;
            stopping_deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(limits.terminate_grace_seconds), .clock = .awake });
            signalGroup(child, .TERM);
        }
        if (!cancelled and cancel != null and cancel.?.load(.acquire)) {
            cancelled = true;
            stopping_deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(limits.terminate_grace_seconds), .clock = .awake });
            signalGroup(child, .TERM);
        }
        if (stopping_deadline) |grace| if (grace.compare(.lte, current)) {
            signalGroup(child, .KILL);
            child.kill(io);
            killed = true;
            break;
        };
    }
    try multi_reader.checkAnyError();
    if (cancelled or timed_out) signalGroup(child, .KILL);
    const term = if (killed) std.process.Child.Term{ .signal = .KILL } else try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{ .stdout = stdout, .stderr = stderr, .term = term, .cancelled = cancelled, .timed_out = timed_out };
}

fn signalGroup(child: std.process.Child, signal: std.posix.SIG) void {
    if (builtin.os.tag == .windows) return;
    if (child.id) |id| {
        const process_id: std.posix.pid_t = @intCast(id);
        std.posix.kill(-process_id, signal) catch std.posix.kill(process_id, signal) catch {};
    }
}

pub fn runLines(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: []const u8,
    environment: *const std.process.Environ.Map,
    limits: Limits,
    maximum_line_bytes: usize,
    callback: LineCallback,
    cancel: ?*const std.atomic.Value(bool),
) !StreamingResult {
    if (argv.len == 0 or limits.stderr_bytes == 0 or limits.timeout_seconds == 0 or maximum_line_bytes == 0) return error.InvalidProcessOptions;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = environment,
        .expand_arg0 = .no_expand,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    errdefer {
        signalGroup(child, .KILL);
        child.kill(io);
    }
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    var stderr_capture: std.ArrayList(u8) = .empty;
    defer stderr_capture.deinit(allocator);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(limits.timeout_seconds), .clock = .awake });
    var inactivity_deadline: ?std.Io.Clock.Timestamp = if (limits.inactivity_seconds > 0) std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(limits.inactivity_seconds), .clock = .awake }) else null;
    var stopping_deadline: ?std.Io.Clock.Timestamp = null;
    var cancelled = false;
    var timed_out = false;
    var killed = false;
    var ended = false;

    while (!ended) {
        const stdout_before = stdout_reader.bufferedLen();
        const stderr_before = stderr_reader.bufferedLen();
        multi_reader.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => ended = true,
            error.Timeout => {},
            else => |other| return other,
        };
        if (stdout_reader.bufferedLen() > stdout_before or stderr_reader.bufferedLen() > stderr_before) {
            if (limits.inactivity_seconds > 0) inactivity_deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(limits.inactivity_seconds), .clock = .awake });
        }
        try drainLines(stdout_reader, maximum_line_bytes, callback, ended);
        try captureStderr(allocator, &stderr_capture, stderr_reader, limits.stderr_bytes);
        const current = std.Io.Clock.Timestamp.now(io, .awake);
        if (deadline.compare(.lte, current) and stopping_deadline == null) {
            timed_out = true;
            stopping_deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(limits.terminate_grace_seconds), .clock = .awake });
            signalGroup(child, .TERM);
        }
        if (inactivity_deadline) |idle| if (idle.compare(.lte, current) and stopping_deadline == null) {
            timed_out = true;
            stopping_deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(limits.terminate_grace_seconds), .clock = .awake });
            signalGroup(child, .TERM);
        };
        if (!cancelled and cancel != null and cancel.?.load(.acquire)) {
            cancelled = true;
            stopping_deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(limits.terminate_grace_seconds), .clock = .awake });
            signalGroup(child, .TERM);
        }
        if (stopping_deadline) |grace| if (grace.compare(.lte, current)) {
            signalGroup(child, .KILL);
            child.kill(io);
            killed = true;
            break;
        };
    }
    try multi_reader.checkAnyError();
    if (cancelled or timed_out) signalGroup(child, .KILL);
    const term = if (killed) std.process.Child.Term{ .signal = .KILL } else try child.wait(io);
    return .{
        .stderr = try stderr_capture.toOwnedSlice(allocator),
        .term = term,
        .cancelled = cancelled,
        .timed_out = timed_out,
    };
}

fn drainLines(reader: *std.Io.Reader, maximum: usize, callback: LineCallback, ended: bool) !void {
    while (std.mem.indexOfScalar(u8, reader.buffered(), '\n')) |newline| {
        const raw = reader.buffered()[0..newline];
        const line = std.mem.trimEnd(u8, raw, "\r");
        try callback.on_line(callback.context, line);
        reader.toss(newline + 1);
    }
    if (reader.bufferedLen() > maximum) return error.LineTooLong;
    if (ended and reader.bufferedLen() > 0) {
        const line = std.mem.trimEnd(u8, reader.buffered(), "\r");
        try callback.on_line(callback.context, line);
        reader.tossBuffered();
    }
}

fn captureStderr(allocator: std.mem.Allocator, capture: *std.ArrayList(u8), reader: *std.Io.Reader, maximum: usize) !void {
    const bytes = reader.buffered();
    if (bytes.len == 0) return;
    if (bytes.len >= maximum) {
        capture.clearRetainingCapacity();
        try capture.appendSlice(allocator, bytes[bytes.len - maximum ..]);
    } else {
        if (capture.items.len + bytes.len > maximum) {
            const discard = capture.items.len + bytes.len - maximum;
            std.mem.copyForwards(u8, capture.items[0 .. capture.items.len - discard], capture.items[discard..]);
            capture.shrinkRetainingCapacity(capture.items.len - discard);
        }
        try capture.appendSlice(allocator, bytes);
    }
    reader.tossBuffered();
}
