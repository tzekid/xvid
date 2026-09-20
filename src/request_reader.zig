//! Bound incoming request waits without limiting outgoing media transfers.
const RequestReader = @This();
const std = @import("std");

io: std.Io,
stream: std.Io.net.Stream,
remaining: std.Io.Duration,
reader: std.Io.Reader,

pub fn init(io: std.Io, stream: std.Io.net.Stream, budget: std.Io.Duration, read_buffer: []u8) RequestReader {
    return .{
        .io = io,
        .stream = stream,
        .remaining = budget,
        .reader = .{ .vtable = &.{ .stream = read }, .buffer = read_buffer, .seek = 0, .end = 0 },
    };
}

fn wait(self: *RequestReader, events: i16, deadline: std.Io.Clock.Timestamp) error{NetworkTimeout}!void {
    var fds = [_]std.posix.pollfd{.{ .fd = self.stream.socket.handle, .events = events, .revents = 0 }};
    while (true) {
        const remaining = deadline.durationFromNow(self.io).raw.toMilliseconds();
        if (remaining <= 0) return error.NetworkTimeout;
        const rc = std.c.poll(&fds, fds.len, @intCast(remaining));
        switch (std.posix.errno(rc)) {
            .SUCCESS => if (rc > 0) return else return error.NetworkTimeout,
            .INTR => continue,
            else => return error.NetworkTimeout,
        }
    }
}

fn read(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *RequestReader = @alignCast(@fieldParentPtr("reader", reader));
    const data = limit.slice(try writer.writableSliceGreedy(1));
    if (data.len == 0) return 0;
    const started: std.Io.Clock.Timestamp = .now(self.io, .awake);
    defer self.remaining.nanoseconds -= started.untilNow(self.io).raw.nanoseconds;
    const deadline = started.addDuration(.{ .raw = self.remaining, .clock = .awake });
    while (true) {
        self.wait(std.posix.POLL.IN, deadline) catch return error.ReadFailed;
        const rc = std.c.recv(self.stream.socket.handle, data.ptr, data.len, std.posix.MSG.DONTWAIT);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.EndOfStream;
                const n: usize = @intCast(rc);
                writer.advance(n);
                return n;
            },
            .INTR, .AGAIN => continue,
            else => return error.ReadFailed,
        }
    }
}
