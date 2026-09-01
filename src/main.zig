const std = @import("std");
const app_mod = @import("app.zig");
const config_mod = @import("config.zig");
const disk = @import("disk.zig");
const operator = @import("operator.zig");
const process = @import("process.zig");
const source = @import("source.zig");
const usage_db = @import("usage.zig");
const x = @import("x.zig");

const version = "1.0.0-native-x";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len == 2 and std.mem.eql(u8, args[1], "__doctor-child")) {
        while (true) try init.io.sleep(.fromSeconds(60), .awake);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout.interface.flush() catch {};

    if (args.len == 2 and std.mem.eql(u8, args[1], "version")) {
        try stdout.interface.print("xvid {s} native_x_upstream={s}\n", .{ version, x.upstream_revision });
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "serve")) {
        const config_path = try optionalNamedValue(args[2..], "--config");
        const config = if (config_path) |path| try config_mod.Config.load(allocator, init.io, path) else config_mod.Config{};
        try config.validate();
        var app = try app_mod.App.init(init.gpa, init.io, config);
        defer app.deinit();
        try app.serve();
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "doctor")) {
        const config_path = try optionalNamedValue(args[2..], "--config");
        const config = if (config_path) |path| try config_mod.Config.load(allocator, init.io, path) else config_mod.Config{};
        try config.validate();
        try doctor(allocator, init.io, &stdout.interface, config);
        return;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "x-probe")) {
        const options = try parseXProbeArgs(args[2..]);
        const config = if (options.config_path) |path| try config_mod.Config.load(allocator, init.io, path) else config_mod.Config{};
        try config.validate();

        var environment = std.process.Environ.Map.init(allocator);
        defer environment.deinit();
        try environment.put("PATH", "/usr/local/bin:/usr/bin:/bin");
        try environment.put("HOME", config.data_dir);
        try environment.put("LANG", "C.UTF-8");

        var shared = source.Shared{};
        var context = source.Context.init(init.gpa, init.io, &config, &environment, &shared);
        defer context.deinit();
        const diagnostic = try x.probeDiagnostic(allocator, &context.x_client, options.url);
        try x.writeDiagnostic(allocator, &stdout.interface, diagnostic, null, options.as_json);
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "jobs")) {
        const data_root = try requiredNamedValue(args[2..], "--data");
        try operator.list(allocator, init.io, &stdout.interface, data_root);
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "inspect")) {
        if (args.len != 5 or !std.mem.eql(u8, args[2], "--data")) return error.InvalidArguments;
        try operator.inspect(allocator, init.io, &stdout.interface, args[3], args[4]);
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "prune")) {
        if (args.len != 5 or !std.mem.eql(u8, args[2], "--data")) return error.InvalidArguments;
        const apply = if (std.mem.eql(u8, args[4], "--apply")) true else if (std.mem.eql(u8, args[4], "--dry-run")) false else return error.InvalidArguments;
        _ = try operator.prune(allocator, init.io, &stdout.interface, args[3], apply, std.Io.Clock.real.now(init.io).toSeconds());
        return;
    }
    try usage(&stdout.interface);
    return error.InvalidArguments;
}

fn optionalNamedValue(args: []const []const u8, name: []const u8) !?[]const u8 {
    if (args.len == 0) return null;
    if (args.len != 2 or !std.mem.eql(u8, args[0], name)) return error.InvalidArguments;
    return args[1];
}

fn requiredNamedValue(args: []const []const u8, name: []const u8) ![]const u8 {
    return (try optionalNamedValue(args, name)) orelse error.InvalidArguments;
}

const XProbeOptions = struct {
    url: []const u8,
    config_path: ?[]const u8 = null,
    as_json: bool = false,
};

fn parseXProbeArgs(args: []const []const u8) !XProbeOptions {
    if (args.len == 0 or args[0].len == 0 or args[0][0] == '-') return error.InvalidArguments;
    var options = XProbeOptions{ .url = args[0] };
    var index: usize = 1;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--json")) {
            if (options.as_json) return error.InvalidArguments;
            options.as_json = true;
            index += 1;
        } else if (std.mem.eql(u8, args[index], "--config")) {
            if (options.config_path != null or index + 1 >= args.len) return error.InvalidArguments;
            options.config_path = args[index + 1];
            index += 2;
        } else return error.InvalidArguments;
    }
    return options;
}

fn doctor(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, config: config_mod.Config) !void {
    var healthy = true;
    healthy = (try checkDataDirectory(allocator, io, writer, config.data_dir)) and healthy;
    const available = disk.availableBytes(allocator, config.data_dir) catch 0;
    const reserve = std.math.add(u64, config.max_download_bytes, config.max_output_bytes) catch std.math.maxInt(u64);
    const disk_ok = available >= config.minimum_free_bytes and reserve <= available - config.minimum_free_bytes;
    try writer.print("disk: {s} available={d} minimum_free={d} one_job_reserve={d}\n", .{ if (disk_ok) "ok" else "insufficient", available, config.minimum_free_bytes, reserve });
    healthy = disk_ok and healthy;

    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try environment.put("HOME", config.data_dir);
    try environment.put("LANG", "C.UTF-8");
    healthy = (try checkTool(allocator, io, writer, "ffmpeg", &.{ config.ffmpeg, "-version" }, config.data_dir, &environment)) and healthy;
    healthy = (try checkTool(allocator, io, writer, "ffprobe", &.{ config.ffprobe, "-version" }, config.data_dir, &environment)) and healthy;
    healthy = (try checkCancellation(allocator, io, writer, config.data_dir, &environment)) and healthy;
    healthy = (try checkOwnership(allocator, io, writer, config.data_dir)) and healthy;
    healthy = (try checkUsageDatabase(allocator, io, writer, config.data_dir)) and healthy;
    try writer.writeAll("source boundary: native public X status links only\n");
    try writer.print("X metadata timeout: {d}s\n", .{config.x_metadata_timeout_seconds});
    try writer.print("X photo hosts: {d}\n", .{config.x_photo_media_hosts.len});
    try writer.print("X video hosts: {d}\n", .{config.x_video_media_hosts.len});
    try writer.print("X upstream reference: {s}\n", .{x.upstream_revision});
    try writer.print("public origin: {s}\n", .{config.public_origin});
    try writer.print("configuration: listen={s} workers={d} queue={d} rate_keys={d} probe_rate={d}/min jobs_rate={d}/hour choice_ttl={d}s terminal_ttl={d}s\n", .{
        config.listen,
        config.http_workers,
        config.http_queue,
        config.rate_limit_capacity,
        config.probes_per_minute,
        config.jobs_per_hour,
        config.choice_ttl_seconds,
        config.terminal_ttl_seconds,
    });
    if (!healthy) return error.DoctorFailed;
}

fn checkDataDirectory(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch {
        try writer.print("data: missing ({s})\n", .{path});
        return false;
    };
    if (stat.kind != .directory) {
        try writer.print("data: not a directory ({s})\n", .{path});
        return false;
    }
    var random: [8]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const probe_path = try std.fs.path.join(allocator, &.{ path, &suffix });
    defer allocator.free(probe_path);
    const probe_file = std.Io.Dir.cwd().createFile(io, probe_path, .{ .exclusive = true, .permissions = @fromBackingInt(@intCast(0o600)) }) catch {
        try writer.print("data: not writable ({s})\n", .{path});
        return false;
    };
    probe_file.close(io);
    std.Io.Dir.cwd().deleteFile(io, probe_path) catch {};
    try writer.print("data: ok ({s})\n", .{path});
    return true;
}

fn checkTool(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, label: []const u8, argv: []const []const u8, cwd: []const u8, environment: *const std.process.Environ.Map) !bool {
    const result = process.run(allocator, io, argv, cwd, environment, .{ .stdout_bytes = 64 * 1024, .stderr_bytes = 64 * 1024, .timeout_seconds = 15 }, null) catch |err| {
        try writer.print("{s}: failed ({s})\n", .{ label, @errorName(err) });
        return false;
    };
    defer result.deinit(allocator);
    if (result.timed_out or !result.term.success()) {
        try writer.print("{s}: failed (exit)\n", .{label});
        return false;
    }
    const text = if (result.stdout.len > 0) result.stdout else result.stderr;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = std.mem.trim(u8, text[0..@min(end, 200)], " \t\r");
    try writer.print("{s}: ok ({s})\n", .{ label, if (line.len > 0) line else "version command succeeded" });
    return true;
}

const CancelContext = struct { flag: *std.atomic.Value(bool) };

fn cancelAfter(context: CancelContext) void {
    var request: std.c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    var remaining: std.c.timespec = undefined;
    _ = std.c.nanosleep(&request, &remaining);
    context.flag.store(true, .release);
}

fn checkCancellation(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, cwd: []const u8, environment: *const std.process.Environ.Map) !bool {
    const executable = try std.process.executablePathAlloc(io, allocator);
    var cancel: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, cancelAfter, .{CancelContext{ .flag = &cancel }});
    defer thread.join();
    const result = process.run(allocator, io, &.{ executable, "__doctor-child" }, cwd, environment, .{ .stdout_bytes = 1024, .stderr_bytes = 1024, .timeout_seconds = 5 }, &cancel) catch |err| {
        try writer.print("child cancellation: failed ({s})\n", .{@errorName(err)});
        return false;
    };
    defer result.deinit(allocator);
    try writer.print("child cancellation: {s}\n", .{if (result.cancelled) "ok" else "failed"});
    return result.cancelled;
}

fn checkOwnership(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, data_root: []const u8) !bool {
    const ownership = operator.acquireOwnership(allocator, io, data_root) catch |err| switch (err) {
        error.DataDirectoryInUse => {
            try writer.writeAll("data ownership: ok (active xvid owner)\n");
            return true;
        },
        else => {
            try writer.print("data ownership: failed ({s})\n", .{@errorName(err)});
            return false;
        },
    };
    ownership.close(io);
    try writer.writeAll("data ownership: ok (lock available)\n");
    return true;
}

fn checkUsageDatabase(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, data_root: []const u8) !bool {
    var store = usage_db.Store.init(allocator, io, data_root) catch |err| {
        try writer.print("usage database: failed ({s})\n", .{@errorName(err)});
        return false;
    };
    defer store.deinit();
    store.check() catch |err| {
        try writer.print("usage database: failed ({s})\n", .{@errorName(err)});
        return false;
    };
    try writer.print("usage database: ok ({s})\n", .{store.path()});
    return true;
}

fn usage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  xvid serve [--config PATH]
        \\  xvid doctor [--config PATH]
        \\  xvid x-probe <x-status-url> [--config PATH] [--json]
        \\  xvid jobs --data PATH
        \\  xvid inspect --data PATH <job-id>
        \\  xvid prune --data PATH --dry-run|--apply
        \\  xvid version
        \\
    );
}

test "x-probe arguments are bounded and unambiguous" {
    const parsed = try parseXProbeArgs(&.{ "https://x.com/i/status/123", "--json", "--config", "config.json" });
    try std.testing.expectEqualStrings("https://x.com/i/status/123", parsed.url);
    try std.testing.expectEqualStrings("config.json", parsed.config_path.?);
    try std.testing.expect(parsed.as_json);
    try std.testing.expectError(error.InvalidArguments, parseXProbeArgs(&.{}));
    try std.testing.expectError(error.InvalidArguments, parseXProbeArgs(&.{"--json"}));
    try std.testing.expectError(error.InvalidArguments, parseXProbeArgs(&.{ "https://x.com/i/status/123", "--json", "--json" }));
    try std.testing.expectError(error.InvalidArguments, parseXProbeArgs(&.{ "https://x.com/i/status/123", "--compare-ytdlp" }));
}
