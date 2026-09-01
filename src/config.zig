const std = @import("std");

pub const Config = struct {
    listen: []const u8 = "127.0.0.1:8090",
    public_origin: []const u8 = "http://127.0.0.1:8090",
    data_dir: []const u8 = "./data",
    http_workers: u8 = 16,
    http_queue: u16 = 32,
    http_inactivity_seconds: u16 = 30,
    max_open_sse: u8 = 4,
    max_artifact_streams: u8 = 8,
    max_loaded_jobs: u16 = 256,
    rate_limit_capacity: u16 = 1024,
    probes_per_minute: u16 = 6,
    jobs_per_hour: u16 = 30,
    choice_ttl_seconds: u32 = 15 * 60,
    terminal_ttl_seconds: u32 = 30 * 60,
    cleanup_interval_seconds: u16 = 10,
    quarantine_ttl_seconds: u32 = 7 * 24 * 60 * 60,
    probe_workers: u8 = 2,
    max_queued_probes: u16 = 16,
    media_workers: u8 = 1,
    max_queued_media: u16 = 8,
    download_timeout_seconds: u32 = 4 * 60 * 60,
    download_inactivity_seconds: u16 = 120,
    ffprobe_timeout_seconds: u16 = 30,
    encode_timeout_seconds: u32 = 4 * 60 * 60,
    encode_inactivity_seconds: u16 = 120,
    ffmpeg_threads: u8 = 4,
    max_download_bytes: u64 = 4 * 1024 * 1024 * 1024,
    max_output_bytes: u64 = 4 * 1024 * 1024 * 1024,
    job_storage_budget_bytes: u64 = 16 * 1024 * 1024 * 1024,
    minimum_free_bytes: u64 = 2 * 1024 * 1024 * 1024,
    max_media_duration_seconds: u32 = 0,
    ffmpeg: []const u8 = "ffmpeg",
    ffprobe: []const u8 = "ffprobe",
    x_guest_endpoint: []const u8 = "https://api.x.com/1.1/guest/activate.json",
    x_graphql_endpoint: []const u8 = "https://x.com/i/api/graphql/2ICDjqPd81tulZcYrtpTuQ/TweetResultByRestId",
    x_syndication_endpoint: []const u8 = "https://cdn.syndication.twimg.com/tweet-result",
    x_metadata_timeout_seconds: u16 = 15,
    x_photo_media_hosts: []const []const u8 = &.{"pbs.twimg.com"},
    x_video_media_hosts: []const []const u8 = &.{"video.twimg.com"},

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024));
        return try std.json.parseFromSliceLeaky(Config, allocator, bytes, .{
            .ignore_unknown_fields = false,
        });
    }

    pub fn validate(config: Config) !void {
        if (config.listen.len == 0 or config.listen.len > 256) return error.InvalidListenAddress;
        _ = std.Io.net.IpAddress.parseLiteral(config.listen) catch return error.InvalidListenAddress;
        try validatePublicOrigin(config.public_origin);
        if (config.data_dir.len == 0 or config.data_dir.len > 4096) return error.InvalidDataDirectory;
        if (config.http_workers == 0 or config.http_workers > 64) return error.InvalidHttpWorkerCount;
        if (config.http_queue < config.http_workers or config.http_queue > 1024) return error.InvalidHttpQueueCapacity;
        if (config.http_inactivity_seconds < 10 or config.http_inactivity_seconds > 300) return error.InvalidHttpInactivityTimeout;
        if (config.max_open_sse >= config.http_workers or config.max_open_sse > 32) return error.InvalidSseCapacity;
        if (config.max_artifact_streams == 0 or config.max_artifact_streams > 32 or config.max_open_sse + config.max_artifact_streams >= config.http_workers) return error.InvalidArtifactStreamCapacity;
        if (config.max_loaded_jobs == 0 or config.max_loaded_jobs > 4096) return error.InvalidLoadedJobCapacity;
        if (config.rate_limit_capacity == 0 or config.rate_limit_capacity > 16384 or config.probes_per_minute == 0 or config.probes_per_minute > 1000 or config.jobs_per_hour == 0 or config.jobs_per_hour > 10000) return error.InvalidRateLimit;
        if (config.choice_ttl_seconds < 60 or config.choice_ttl_seconds > 24 * 60 * 60) return error.InvalidChoiceTtl;
        if (config.terminal_ttl_seconds == 0 or config.terminal_ttl_seconds > 7 * 24 * 60 * 60) return error.InvalidTerminalTtl;
        if (config.cleanup_interval_seconds == 0 or config.cleanup_interval_seconds > 3600) return error.InvalidCleanupInterval;
        if (config.quarantine_ttl_seconds < 60 * 60 or config.quarantine_ttl_seconds > 90 * 24 * 60 * 60) return error.InvalidQuarantineTtl;
        if (config.probe_workers == 0 or config.probe_workers > 4) return error.InvalidProbeWorkerCount;
        if (config.max_queued_probes < config.probe_workers or config.max_queued_probes > 256) return error.InvalidProbeQueueCapacity;
        // Storage admission is intentionally single-media-worker until reservations
        // are represented explicitly rather than inferred from current disk use.
        if (config.media_workers != 1) return error.InvalidMediaWorkerCount;
        if (config.max_queued_media < config.media_workers or config.max_queued_media > 64) return error.InvalidMediaQueueCapacity;
        if (config.download_timeout_seconds < 60 or config.download_timeout_seconds > 24 * 60 * 60) return error.InvalidDownloadTimeout;
        if (config.download_inactivity_seconds < 10 or config.download_inactivity_seconds > 3600) return error.InvalidInactivityTimeout;
        if (config.ffprobe_timeout_seconds == 0 or config.ffprobe_timeout_seconds > 300) return error.InvalidFfprobeTimeout;
        if (config.encode_timeout_seconds < 60 or config.encode_timeout_seconds > 24 * 60 * 60) return error.InvalidEncodeTimeout;
        if (config.encode_inactivity_seconds < 10 or config.encode_inactivity_seconds > 3600) return error.InvalidEncodeInactivityTimeout;
        if (config.ffmpeg_threads == 0 or config.ffmpeg_threads > 16) return error.InvalidFfmpegThreadCount;
        if (config.max_download_bytes == 0 or config.max_output_bytes == 0) return error.InvalidMediaByteLimit;
        const one_job_reserve = std.math.add(u64, config.max_download_bytes, config.max_output_bytes) catch return error.InvalidDiskBudget;
        if (config.job_storage_budget_bytes < one_job_reserve or config.minimum_free_bytes == 0) return error.InvalidDiskBudget;
        if (config.ffmpeg.len == 0 or config.ffprobe.len == 0) return error.InvalidToolPath;
        if (config.x_metadata_timeout_seconds == 0 or config.x_metadata_timeout_seconds > 120) return error.InvalidXMetadataTimeout;

        const fixture_mode = endpointIsLoopback(config.x_guest_endpoint) and
            endpointIsLoopback(config.x_graphql_endpoint) and
            endpointIsLoopback(config.x_syndication_endpoint);
        try validateXEndpoint(config.x_guest_endpoint, "api.x.com", fixture_mode);
        try validateXEndpoint(config.x_graphql_endpoint, "x.com", fixture_mode);
        try validateXEndpoint(config.x_syndication_endpoint, "cdn.syndication.twimg.com", fixture_mode);
        if (config.x_photo_media_hosts.len == 0 or config.x_video_media_hosts.len == 0) return error.InvalidXMediaHost;
        for (config.x_photo_media_hosts) |host| try validateXMediaHost(host, "pbs.twimg.com", fixture_mode);
        for (config.x_video_media_hosts) |host| try validateXMediaHost(host, "video.twimg.com", fixture_mode);
    }
};

fn validatePublicOrigin(origin: []const u8) !void {
    if (origin.len == 0 or origin.len > 2048 or std.mem.endsWith(u8, origin, "/")) return error.InvalidPublicOrigin;
    const uri = std.Uri.parse(origin) catch return error.InvalidPublicOrigin;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or !uri.path.isEmpty()) return error.InvalidPublicOrigin;
}

fn validateXEndpoint(endpoint: []const u8, production_host: []const u8, fixture_mode: bool) !void {
    if (endpoint.len == 0 or endpoint.len > 2048) return error.InvalidXEndpoint;
    const uri = std.Uri.parse(endpoint) catch return error.InvalidXEndpoint;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidXEndpoint;
    var host_buffer: [512]u8 = undefined;
    const host = uri.host.?.toRaw(&host_buffer) catch return error.InvalidXEndpoint;
    if (fixture_mode) {
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or !loopbackHost(host)) return error.InvalidXEndpoint;
    } else {
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or !std.ascii.eqlIgnoreCase(host, production_host)) return error.InvalidXEndpoint;
    }
}

fn endpointIsLoopback(endpoint: []const u8) bool {
    const uri = std.Uri.parse(endpoint) catch return false;
    const host_component = uri.host orelse return false;
    var buffer: [512]u8 = undefined;
    return loopbackHost(host_component.toRaw(&buffer) catch return false);
}

fn validateXMediaHost(host: []const u8, production_host: []const u8, fixture_mode: bool) !void {
    if (host.len == 0 or host.len > 253 or std.mem.indexOfAny(u8, host, "\r\n\x00/:@\\") != null) return error.InvalidXMediaHost;
    if (fixture_mode) {
        if (!loopbackHost(host)) return error.InvalidXMediaHost;
    } else if (!std.ascii.eqlIgnoreCase(host, production_host)) return error.InvalidXMediaHost;
}

fn loopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "::1") or
        std.ascii.eqlIgnoreCase(host, "[::1]");
}

test "configuration defaults are valid and bounds fail closed" {
    try (Config{}).validate();
    var config = Config{};
    config.http_workers = 0;
    try std.testing.expectError(error.InvalidHttpWorkerCount, config.validate());
    config.http_workers = 4;
    config.http_queue = 2;
    try std.testing.expectError(error.InvalidHttpQueueCapacity, config.validate());
}

test "only reviewed X hosts or complete loopback fixtures are accepted" {
    var config = Config{};
    config.x_graphql_endpoint = "https://example.com/graphql";
    try std.testing.expectError(error.InvalidXEndpoint, config.validate());

    config = Config{};
    config.public_origin = "http://127.0.0.1:8090";
    config.x_guest_endpoint = "http://127.0.0.1:9000/guest";
    config.x_graphql_endpoint = "http://127.0.0.1:9000/graphql";
    config.x_syndication_endpoint = "http://127.0.0.1:9000/tweet-result";
    config.x_photo_media_hosts = &.{"127.0.0.1"};
    config.x_video_media_hosts = &.{"127.0.0.1"};
    try config.validate();
}
