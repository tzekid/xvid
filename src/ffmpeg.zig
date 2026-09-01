const std = @import("std");
const Config = @import("config.zig").Config;
const job_mod = @import("job.zig");
const process = @import("process.zig");

pub const ProgressCallback = struct {
    context: *anyopaque,
    update: *const fn (context: *anyopaque, progress: job_mod.Progress) anyerror!void,
};

pub const MediaInfo = struct {
    duration_seconds: ?f64,
    width: ?u32,
    height: ?u32,
    video_codec: ?[]const u8,
    audio_codec: ?[]const u8,
    pixel_format: ?[]const u8,
};

pub fn prepare(
    result_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    environment: *const std.process.Environ.Map,
    job_root: []const u8,
    sources: []const job_mod.Artifact,
    delivery: job_mod.Delivery,
    cancel: *const std.atomic.Value(bool),
    progress_callback: ProgressCallback,
) ![]const job_mod.Artifact {
    if (delivery.mode == .original) return &.{};
    if (sources.len != 1) return error.UnsupportedMultiplePreparation;
    const source = sources[0];
    if (source.media_kind != .video) return &.{};
    const input_path = try std.fs.path.join(scratch_allocator, &.{ job_root, source.path });
    defer scratch_allocator.free(input_path);
    const input_info = try inspectVideo(result_allocator, io, config, environment, job_root, input_path, cancel);
    const target_height = if (delivery.mode == .downscale) delivery.target_height orelse return error.InvalidDelivery else null;
    if (!needsEncode(source.path, input_info, target_height)) return &.{};

    const output_directory = try std.fs.path.join(scratch_allocator, &.{ job_root, "output" });
    defer scratch_allocator.free(output_directory);
    std.Io.Dir.cwd().deleteTree(io, output_directory) catch {};
    try std.Io.Dir.cwd().createDirPath(io, output_directory);
    const temporary_path = try std.fs.path.join(scratch_allocator, &.{ output_directory, "item-001.tmp.mp4" });
    defer scratch_allocator.free(temporary_path);
    const final_path = try std.fs.path.join(scratch_allocator, &.{ output_directory, "item-001.mp4" });
    defer scratch_allocator.free(final_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(scratch_allocator);
    try argv.appendSlice(scratch_allocator, &.{
        config.ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-filter_threads",
        try std.fmt.allocPrint(scratch_allocator, "{d}", .{config.ffmpeg_threads}),
        "-y",
        "-i",
        input_path,
        "-map",
        "0:v:0",
        "-map",
        "0:a?",
    });
    if (target_height) |height| if (input_info.height == null or input_info.height.? > height) {
        try argv.appendSlice(scratch_allocator, &.{ "-vf", try std.fmt.allocPrint(scratch_allocator, "scale=-2:{d}", .{height}) });
    };
    try argv.appendSlice(scratch_allocator, &.{
        "-c:v",
        "libx264",
        "-preset",
        "medium",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
        "-threads",
        try std.fmt.allocPrint(scratch_allocator, "{d}", .{config.ffmpeg_threads}),
        "-c:a",
        "aac",
        "-b:a",
        "192k",
        "-movflags",
        "+faststart",
        "-progress",
        "pipe:1",
        "-nostats",
        temporary_path,
    });

    var parser = ProgressParser{
        .io = io,
        .callback = progress_callback,
        .duration_seconds = input_info.duration_seconds,
        .output_path = temporary_path,
        .maximum_bytes = config.max_output_bytes,
    };
    const result = process.runLines(scratch_allocator, io, argv.items, job_root, environment, .{
        .stdout_bytes = 1,
        .stderr_bytes = 128 * 1024,
        .timeout_seconds = config.encode_timeout_seconds,
        .inactivity_seconds = config.encode_inactivity_seconds,
    }, 16 * 1024, .{ .context = &parser, .on_line = ProgressParser.line }, cancel) catch |err| switch (err) {
        error.FileNotFound => return error.ToolMissing,
        error.LineTooLong => return error.EncodeOutputInvalid,
        else => return err,
    };
    defer result.deinit(scratch_allocator);
    if (result.cancelled) return error.Cancelled;
    if (result.timed_out) return error.EncodeTimedOut;
    if (!result.term.success()) return error.EncodeFailed;
    const stat = try std.Io.Dir.cwd().statFile(io, temporary_path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size == 0) return error.EncodeOutputInvalid;
    if (stat.size > config.max_output_bytes) return error.OutputTooLarge;
    const output_info = try inspectVideo(result_allocator, io, config, environment, job_root, temporary_path, cancel);
    if (!codecIs(output_info.video_codec, "h264") or (output_info.audio_codec != null and !codecIs(output_info.audio_codec, "aac")) or !compatiblePixelFormat(output_info.pixel_format)) return error.EncodeValidationFailed;
    if (target_height) |height| {
        if (output_info.height == null or output_info.height.? != height) return error.EncodeValidationFailed;
    } else {
        if (input_info.width != null and output_info.width != input_info.width) return error.EncodeValidationFailed;
        if (input_info.height != null and output_info.height != input_info.height) return error.EncodeValidationFailed;
    }
    try std.Io.Dir.cwd().rename(temporary_path, std.Io.Dir.cwd(), final_path, io);

    const artifacts = try result_allocator.alloc(job_mod.Artifact, 1);
    artifacts[0] = .{
        .id = "output-1",
        .path = "output/item-001.mp4",
        .filename = try outputFilename(result_allocator, source.filename),
        .media_kind = .video,
        .mime_type = "video/mp4",
        .size_bytes = stat.size,
        .primary = true,
        .poster = source.poster,
    };
    return artifacts;
}

pub fn inspectVideo(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    environment: *const std.process.Environ.Map,
    cwd: []const u8,
    path: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !MediaInfo {
    const argv = [_][]const u8{
        config.ffprobe,
        "-v",
        "error",
        "-show_entries",
        "stream=codec_type,codec_name,width,height,pix_fmt:format=duration",
        "-of",
        "json",
        path,
    };
    const result = process.run(allocator, io, &argv, cwd, environment, .{
        .stdout_bytes = 128 * 1024,
        .stderr_bytes = 64 * 1024,
        .timeout_seconds = config.ffprobe_timeout_seconds,
    }, cancel) catch |err| switch (err) {
        error.FileNotFound => return error.ToolMissing,
        error.StreamTooLong => return error.ProbeOutputTooLarge,
        else => return err,
    };
    defer result.deinit(allocator);
    if (result.cancelled) return error.Cancelled;
    if (result.timed_out) return error.ProbeTimedOut;
    if (!result.term.success()) return error.MediaProbeFailed;
    return parseProbe(allocator, result.stdout);
}

fn parseProbe(allocator: std.mem.Allocator, bytes: []const u8) !MediaInfo {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{ .max_value_len = 128 * 1024 }) catch return error.InvalidProbeOutput;
    const root = switch (parsed) {
        .object => |object| object,
        else => return error.InvalidProbeOutput,
    };
    var result = MediaInfo{ .duration_seconds = null, .width = null, .height = null, .video_codec = null, .audio_codec = null, .pixel_format = null };
    if (root.get("format")) |format_value| switch (format_value) {
        .object => |format| result.duration_seconds = numberF64(format.get("duration")),
        else => {},
    };
    if (root.get("streams")) |streams_value| switch (streams_value) {
        .array => |streams| for (streams.items) |stream_value| switch (stream_value) {
            .object => |stream| {
                const kind = stringValue(stream.get("codec_type")) orelse continue;
                if (std.mem.eql(u8, kind, "video") and result.video_codec == null) {
                    result.video_codec = if (stringValue(stream.get("codec_name"))) |value| try allocator.dupe(u8, value) else null;
                    result.width = numberU32(stream.get("width"));
                    result.height = numberU32(stream.get("height"));
                    result.pixel_format = if (stringValue(stream.get("pix_fmt"))) |value| try allocator.dupe(u8, value) else null;
                } else if (std.mem.eql(u8, kind, "audio") and result.audio_codec == null) {
                    result.audio_codec = if (stringValue(stream.get("codec_name"))) |value| try allocator.dupe(u8, value) else null;
                }
            },
            else => {},
        },
        else => {},
    };
    if (result.video_codec == null) return error.MissingVideoStream;
    return result;
}

const ProgressParser = struct {
    io: std.Io,
    callback: ProgressCallback,
    duration_seconds: ?f64,
    output_path: []const u8,
    maximum_bytes: u64,
    processed_seconds: ?f64 = null,
    speed_ratio: ?f64 = null,
    bytes_output: ?u64 = null,

    fn line(raw_context: *anyopaque, line_value: []const u8) !void {
        const parser: *ProgressParser = @ptrCast(@alignCast(raw_context));
        const equals = std.mem.indexOfScalar(u8, line_value, '=') orelse return;
        const key = line_value[0..equals];
        const value = line_value[equals + 1 ..];
        if (std.mem.eql(u8, key, "out_time_us") or std.mem.eql(u8, key, "out_time_ms")) {
            const raw = std.fmt.parseFloat(f64, value) catch return;
            parser.processed_seconds = @max(0, raw / 1_000_000);
        } else if (std.mem.eql(u8, key, "speed")) {
            parser.speed_ratio = std.fmt.parseFloat(f64, std.mem.trimEnd(u8, value, "x")) catch null;
        } else if (std.mem.eql(u8, key, "total_size")) {
            parser.bytes_output = std.fmt.parseInt(u64, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "progress")) {
            const fraction: ?f64 = if (parser.processed_seconds != null and parser.duration_seconds != null and parser.duration_seconds.? > 0) @min(1.0, parser.processed_seconds.? / parser.duration_seconds.?) else null;
            const eta: ?u64 = if (parser.speed_ratio != null and parser.speed_ratio.? > 0 and parser.processed_seconds != null and parser.duration_seconds != null and parser.processed_seconds.? < parser.duration_seconds.?) @intFromFloat((parser.duration_seconds.? - parser.processed_seconds.?) / parser.speed_ratio.?) else null;
            const stat_size: ?u64 = if (std.Io.Dir.cwd().statFile(parser.io, parser.output_path, .{})) |stat| stat.size else |_| parser.bytes_output;
            if (stat_size != null and stat_size.? > parser.maximum_bytes) return error.OutputTooLarge;
            try parser.callback.update(parser.callback.context, .{
                .phase = .encoding,
                .label = "Preparing H.264 MP4",
                .bytes_output = stat_size,
                .media_seconds_processed = parser.processed_seconds,
                .media_seconds_total = parser.duration_seconds,
                .fraction = if (std.mem.eql(u8, value, "end")) 1 else fraction,
                .media_speed_ratio = parser.speed_ratio,
                .eta_seconds = if (std.mem.eql(u8, value, "end")) 0 else eta,
                .updated_at = std.Io.Clock.real.now(parser.io).toSeconds(),
            });
        }
    }
};

fn needsEncode(path: []const u8, info: MediaInfo, target_height: ?u32) bool {
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".mp4")) return true;
    if (!codecIs(info.video_codec, "h264") or (info.audio_codec != null and !codecIs(info.audio_codec, "aac")) or !compatiblePixelFormat(info.pixel_format)) return true;
    if (target_height) |height| return info.height == null or info.height.? > height;
    return false;
}

fn compatiblePixelFormat(actual: ?[]const u8) bool {
    const value = actual orelse return false;
    return std.ascii.eqlIgnoreCase(value, "yuv420p") or std.ascii.eqlIgnoreCase(value, "yuvj420p");
}

fn codecIs(actual: ?[]const u8, expected: []const u8) bool {
    const value = actual orelse return false;
    if (std.ascii.eqlIgnoreCase(value, expected)) return true;
    return std.mem.eql(u8, expected, "h264") and std.ascii.eqlIgnoreCase(value, "avc1");
}

fn outputFilename(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const extension = std.fs.path.extension(source);
    const base = if (extension.len > 0) source[0 .. source.len - extension.len] else source;
    return std.fmt.allocPrint(allocator, "{s}-optimised.mp4", .{base});
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn numberF64(value: ?std.json.Value) ?f64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |number| @floatFromInt(number),
        .float => |number| if (std.math.isFinite(number)) number else null,
        .number_string, .string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

fn numberU32(value: ?std.json.Value) ?u32 {
    const number = numberF64(value) orelse return null;
    if (number < 0 or number > std.math.maxInt(u32)) return null;
    return @intFromFloat(@round(number));
}

test "parses FFprobe video and audio facts" {
    const payload = "{\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"h264\",\"width\":1920,\"height\":1080,\"pix_fmt\":\"yuv420p\"},{\"codec_type\":\"audio\",\"codec_name\":\"aac\"}],\"format\":{\"duration\":\"42.4\"}}";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const info = try parseProbe(arena_state.allocator(), payload);
    try std.testing.expectEqualStrings("h264", info.video_codec.?);
    try std.testing.expectEqualStrings("aac", info.audio_codec.?);
    try std.testing.expectEqual(@as(?u32, 1080), info.height);
    try std.testing.expectApproxEqAbs(@as(f64, 42.4), info.duration_seconds.?, 0.001);
}

test "compatible optimise inputs require a broadly playable pixel format" {
    const base = MediaInfo{
        .duration_seconds = 42,
        .width = 1920,
        .height = 1080,
        .video_codec = "h264",
        .audio_codec = "aac",
        .pixel_format = "yuv420p",
    };
    try std.testing.expect(!needsEncode("source.mp4", base, null));
    var high_bit_depth = base;
    high_bit_depth.pixel_format = "yuv420p10le";
    try std.testing.expect(needsEncode("source.mp4", high_bit_depth, null));
}
