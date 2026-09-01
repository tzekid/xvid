const std = @import("std");
const builtin = @import("builtin");
const App = @import("app.zig").App;
const routes = @import("routes.zig");

const max_header_bytes = 16 * 1024;
var signal_requested: std.atomic.Value(bool) = .init(false);

const Runtime = struct {
    app: *App,
    queue: []?std.Io.net.Stream,
    workers: []?std.Thread,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    stopping: bool = false,
    mutex: std.atomic.Value(bool) = .init(false),

    fn lock(runtime: *Runtime) void {
        while (runtime.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(runtime: *Runtime) void {
        runtime.mutex.store(false, .release);
    }

    fn enqueue(runtime: *Runtime, stream: std.Io.net.Stream) bool {
        runtime.lock();
        defer runtime.unlock();
        if (runtime.stopping or runtime.count == runtime.queue.len) return false;
        runtime.queue[runtime.tail] = stream;
        runtime.tail = (runtime.tail + 1) % runtime.queue.len;
        runtime.count += 1;
        return true;
    }

    fn dequeue(runtime: *Runtime) ?std.Io.net.Stream {
        while (true) {
            runtime.lock();
            if (runtime.count > 0) {
                const stream = runtime.queue[runtime.head].?;
                runtime.queue[runtime.head] = null;
                runtime.head = (runtime.head + 1) % runtime.queue.len;
                runtime.count -= 1;
                runtime.unlock();
                return stream;
            }
            if (runtime.stopping) {
                runtime.unlock();
                return null;
            }
            runtime.unlock();
            sleepMillisecond();
        }
    }
};

pub fn serve(app: *App) !void {
    signal_requested.store(false, .release);
    const address = try std.Io.net.IpAddress.parseLiteral(app.config.listen);
    var listener = try address.listen(app.io, .{ .reuse_address = true });
    defer listener.deinit(app.io);

    const queue = try app.allocator.alloc(?std.Io.net.Stream, app.config.http_queue);
    defer app.allocator.free(queue);
    @memset(queue, null);
    const workers = try app.allocator.alloc(?std.Thread, app.config.http_workers);
    defer app.allocator.free(workers);
    @memset(workers, null);
    var runtime = Runtime{ .app = app, .queue = queue, .workers = workers };

    var old_interrupt: std.posix.Sigaction = undefined;
    var old_terminate: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, &old_interrupt);
    std.posix.sigaction(.TERM, &action, &old_terminate);
    defer {
        std.posix.sigaction(.INT, &old_interrupt, null);
        std.posix.sigaction(.TERM, &old_terminate, null);
    }

    var started: usize = 0;
    errdefer {
        runtime.lock();
        runtime.stopping = true;
        runtime.unlock();
        for (workers[0..started]) |thread| if (thread) |item| item.join();
    }
    for (workers) |*slot| {
        slot.* = try std.Thread.spawn(.{}, workerMain, .{&runtime});
        started += 1;
    }

    std.log.info("listening on {s}", .{app.config.listen});
    while (!signal_requested.load(.acquire)) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = @intCast(listener.socket.handle),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&poll_fds, 100) catch |err| {
            if (signal_requested.load(.acquire)) break;
            std.log.warn("listener poll failed: {s}", .{@errorName(err)});
            continue;
        };
        if (ready == 0) continue;
        const stream = listener.accept(app.io) catch |err| {
            if (signal_requested.load(.acquire)) break;
            std.log.warn("accept failed: {s}", .{@errorName(err)});
            sleepMillisecond();
            continue;
        };
        configureSocketTimeout(stream, app.config.http_inactivity_seconds) catch |err| {
            std.log.warn("connection timeout setup failed: {s}", .{@errorName(err)});
            stream.close(app.io);
            continue;
        };
        if (!runtime.enqueue(stream)) {
            respondBusy(app.io, stream) catch {};
            stream.close(app.io);
        }
    }

    runtime.lock();
    runtime.stopping = true;
    while (runtime.count > 0) {
        const stream = runtime.queue[runtime.head].?;
        runtime.queue[runtime.head] = null;
        runtime.head = (runtime.head + 1) % runtime.queue.len;
        runtime.count -= 1;
        stream.close(app.io);
    }
    runtime.unlock();
    for (workers) |*slot| {
        if (slot.*) |thread| thread.join();
        slot.* = null;
    }
}

fn workerMain(runtime: *Runtime) void {
    while (runtime.dequeue()) |stream| {
        serveConnection(runtime.app, stream) catch |err| switch (err) {
            error.HttpConnectionClosing, error.ReadFailed, error.WriteFailed => {},
            else => std.log.warn("connection failed: {s}", .{@errorName(err)}),
        };
        stream.close(runtime.app.io);
    }
}

fn serveConnection(app: *App, stream: std.Io.net.Stream) !void {
    var request_buffer: [max_header_bytes]u8 = undefined;
    var response_buffer: [16 * 1024]u8 = undefined;
    var connection_reader = stream.reader(app.io, &request_buffer);
    var connection_writer = stream.writer(app.io, &response_buffer);
    var http_server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);
    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpHeadersOversize => return writeHeaderTooLarge(&connection_writer.interface),
        else => return err,
    };
    request.head.keep_alive = false;
    try routes.dispatch(app, &request, clientContext(stream));
}

fn clientContext(stream: std.Io.net.Stream) routes.ClientContext {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return .{ .peer_key = 1, .peer_is_loopback = false };
    var storage: std.posix.sockaddr.storage = undefined;
    var length: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    std.posix.getpeername(stream.socket.handle, @ptrCast(&storage), &length) catch return .{ .peer_key = 1, .peer_is_loopback = false };
    if (storage.family == std.posix.AF.INET) {
        const address: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&storage));
        const bytes = std.mem.asBytes(&address.addr);
        return .{
            .peer_key = std.hash.Wyhash.hash(4, bytes),
            .peer_is_loopback = bytes[0] == 127,
        };
    }
    if (storage.family == std.posix.AF.INET6) {
        const address: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(&storage));
        const loopback = std.mem.allEqual(u8, address.addr[0..15], 0) and address.addr[15] == 1;
        const mapped_loopback = std.mem.allEqual(u8, address.addr[0..10], 0) and address.addr[10] == 0xff and address.addr[11] == 0xff and address.addr[12] == 127;
        return .{
            .peer_key = std.hash.Wyhash.hash(6, &address.addr),
            .peer_is_loopback = loopback or mapped_loopback,
        };
    }
    return .{ .peer_key = 1, .peer_is_loopback = false };
}

fn respondBusy(io: std.Io, stream: std.Io.net.Stream) !void {
    var buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll("HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 11\r\nRetry-After: 1\r\nConnection: close\r\n\r\nserver busy");
    try writer.interface.flush();
}

fn writeHeaderTooLarge(writer: *std.Io.Writer) !void {
    try writer.writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 25\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\nrequest headers too large");
    try writer.flush();
}

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    signal_requested.store(true, .release);
}

fn sleepMillisecond() void {
    var request: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
    var remaining: std.c.timespec = undefined;
    _ = std.c.nanosleep(&request, &remaining);
}

fn configureSocketTimeout(stream: std.Io.net.Stream, seconds: u16) !void {
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        const timeout: std.posix.timeval = .{ .sec = seconds, .usec = 0 };
        try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
    }
}
