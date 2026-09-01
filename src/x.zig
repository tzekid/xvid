const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Config;
const ffmpeg = @import("ffmpeg.zig");
const job_mod = @import("job.zig");
const media_url = @import("url.zig");
const zip_bundle = @import("zip.zig");

pub const upstream_revision = "2bbfb9972c8f514740a5fcfdff38374d08e9c15c";

const public_bearer = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";
const user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
const max_graphql_url_bytes: usize = 32 * 1024;
const max_graphql_response_bytes: usize = 2 * 1024 * 1024;
const max_syndication_response_bytes: usize = 512 * 1024;
const max_guest_response_bytes: usize = 64 * 1024;

const graphql_features =
    \\{"creator_subscriptions_tweet_preview_api_enabled":true,"tweetypie_unmention_optimization_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,"longform_notetweets_consumption_enabled":true,"responsive_web_twitter_article_tweet_consumption_enabled":false,"tweet_awards_web_tipping_enabled":false,"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":true,"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,"responsive_web_media_download_video_enabled":false,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_enhance_cards_enabled":false}
;
const graphql_field_toggles =
    \\{"withArticleRichContentState":false}
;

pub const ResolutionPath = enum { graphql, syndication };

pub const MetadataEndpoint = enum { guest, graphql, syndication };

pub const MetadataStage = enum {
    request,
    send,
    response_head,
    response_body,
    body_bound,
    http_status,
    normalize,
};

pub const MetadataFailure = struct {
    endpoint: MetadataEndpoint,
    stage: MetadataStage,
    status: u16 = 0,
    cause: []const u8,
};

pub const MetadataTrace = struct {
    count: u8 = 0,
    first: ?MetadataFailure = null,
    last: ?MetadataFailure = null,

    fn record(trace: *MetadataTrace, failure: MetadataFailure) void {
        if (trace.first == null) trace.first = failure;
        trace.last = failure;
        trace.count +|= 1;
    }
};

pub const RetryEvidence = struct {
    cause: []const u8,
    trace: MetadataTrace,
};

pub const Metrics = struct {
    guest_activation_ms: ?u64 = null,
    graphql_ms: ?u64 = null,
    syndication_ms: ?u64 = null,
    total_ms: u64 = 0,
};

pub const Diagnostic = struct {
    probe: job_mod.Probe,
    resolution_path: ResolutionPath,
    metrics: Metrics,
    metadata_retries: u8 = 0,
};

pub const YtdlpComparisonItem = struct {
    media_kind: job_mod.MediaKind,
    maximum_height: ?u32,
    maximum_direct_height: ?u32,
    maximum_hls_height: ?u32,
    selected_height: ?u32,
    selected_uses_hls: bool,
    hls_only: bool,
    duration_seconds: ?u64,
};

pub const YtdlpComparison = struct {
    items: []const YtdlpComparisonItem,
};

pub const StatusUrl = struct {
    status_id: []const u8,
    requested_media_index: ?u8,
};

const GuestToken = struct {
    length: u8,
    bytes: [128]u8,

    fn slice(token: *const GuestToken) []const u8 {
        return token.bytes[0..token.length];
    }
};

pub const GuestTokenCache = struct {
    mutex: std.atomic.Value(bool) = .init(false),
    length: u8 = 0,
    bytes: [128]u8 = undefined,

    pub fn get(cache: *GuestTokenCache) ?GuestToken {
        cache.lock();
        defer cache.unlock();
        if (cache.length == 0) return null;
        var token = GuestToken{ .length = cache.length, .bytes = undefined };
        @memcpy(token.bytes[0..cache.length], cache.bytes[0..cache.length]);
        return token;
    }

    pub fn storeIfEmpty(cache: *GuestTokenCache, value: []const u8) bool {
        if (value.len == 0 or value.len > cache.bytes.len) return false;
        cache.lock();
        defer cache.unlock();
        if (cache.length != 0) return false;
        @memcpy(cache.bytes[0..value.len], value);
        cache.length = @intCast(value.len);
        return true;
    }

    pub fn invalidateIfEqual(cache: *GuestTokenCache, value: []const u8) bool {
        cache.lock();
        defer cache.unlock();
        if (value.len != cache.length or !std.mem.eql(u8, cache.bytes[0..cache.length], value)) return false;
        @memset(cache.bytes[0..cache.length], 0);
        cache.length = 0;
        return true;
    }

    fn lock(cache: *GuestTokenCache) void {
        while (cache.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(cache: *GuestTokenCache) void {
        cache.mutex.store(false, .release);
    }
};

pub fn matches(raw_url: []const u8) bool {
    return parseStatusUrl(raw_url) catch null != null;
}

pub fn parseStatusUrl(raw_url: []const u8) !StatusUrl {
    var host_buffer: [512]u8 = undefined;
    const parsed = try media_url.validate(raw_url, &host_buffer);
    if (!xHost(parsed.host)) return error.InvalidXUrl;

    const end = std.mem.indexOfAny(u8, raw_url, "?#") orelse raw_url.len;
    const without_query = raw_url[0..end];
    const marker = "/status/";
    const marker_start = std.mem.indexOf(u8, without_query, marker) orelse return error.InvalidXUrl;
    if (std.mem.indexOf(u8, without_query[marker_start + marker.len ..], marker) != null) return error.InvalidXUrl;
    const id_start = marker_start + marker.len;
    var id_end = id_start;
    while (id_end < without_query.len and std.ascii.isDigit(without_query[id_end])) : (id_end += 1) {}
    if (id_end == id_start or id_end - id_start > 24) return error.InvalidXUrl;
    const suffix = without_query[id_end..];
    var requested_media_index: ?u8 = null;
    if (suffix.len > 0 and !std.mem.eql(u8, suffix, "/")) {
        const prefix = if (std.mem.startsWith(u8, suffix, "/video/"))
            "/video/"
        else if (std.mem.startsWith(u8, suffix, "/photo/"))
            "/photo/"
        else
            return error.InvalidXUrl;
        const raw_index = suffix[prefix.len..];
        const index_text = if (std.mem.endsWith(u8, raw_index, "/")) raw_index[0 .. raw_index.len - 1] else raw_index;
        if (index_text.len == 0 or std.mem.indexOfScalar(u8, index_text, '/') != null) return error.InvalidXUrl;
        const index = std.fmt.parseInt(u8, index_text, 10) catch return error.InvalidXUrl;
        if (index == 0 or index > 8) return error.InvalidXUrl;
        requested_media_index = index;
    }
    return .{ .status_id = without_query[id_start..id_end], .requested_media_index = requested_media_index };
}

fn xHost(host: []const u8) bool {
    inline for (.{ "x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com", "m.twitter.com" }) |candidate| {
        if (std.ascii.eqlIgnoreCase(host, candidate)) return true;
    }
    return false;
}

fn percentEncode(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return output.toOwnedSlice(allocator);
}

fn syndicationToken(allocator: std.mem.Allocator, status_id: []const u8) ![]const u8 {
    const integer = std.fmt.parseInt(u64, status_id, 10) catch return error.InvalidXUrl;
    const value = (@as(f64, @floatFromInt(integer)) / 1e15) * std.math.pi;
    const base36 = try jsNumberToStringBase36(allocator, value);
    defer allocator.free(base36);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (base36) |byte| if (byte != '0' and byte != '.') try output.append(allocator, byte);
    return output.toOwnedSlice(allocator);
}

fn jsNumberToStringBase36(allocator: std.mem.Allocator, raw_value: f64) ![]const u8 {
    if (!std.math.isFinite(raw_value) or raw_value <= 0) return error.InvalidNumber;
    const radix: f64 = 36;
    const value = raw_value;
    var integer = @floor(value);
    var fraction = value - integer;
    const next = std.math.nextAfter(f64, value, std.math.inf(f64));
    var delta = @max(std.math.floatTrueMin(f64), (next - value) / 2);
    var digits: std.ArrayList(i8) = .empty;
    defer digits.deinit(allocator);
    if (fraction >= delta) try digits.append(allocator, -2);
    while (fraction >= delta) {
        delta *= radix;
        const scaled = fraction * radix;
        const digit = @floor(scaled);
        fraction = scaled - digit;
        try digits.append(allocator, @intFromFloat(digit));
        const integral_digit: i8 = @intFromFloat(digit);
        const needs_rounding = fraction > 0.5 or (fraction == 0.5 and (integral_digit & 1) == 1);
        if (needs_rounding and fraction + delta > 1) {
            var index = digits.items.len;
            var carried = false;
            while (index > 1) {
                index -= 1;
                if (digits.items[index] + 1 < 36) {
                    digits.items[index] += 1;
                    carried = true;
                    break;
                }
                _ = digits.pop();
            }
            if (!carried) integer += 1;
            break;
        }
    }

    var integer_value: u64 = @intFromFloat(integer);
    try digits.insert(allocator, 0, @intCast(integer_value % 36));
    integer_value /= 36;
    while (integer_value > 0) : (integer_value /= 36) try digits.insert(allocator, 0, @intCast(integer_value % 36));
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz.-";
    const output = try allocator.alloc(u8, digits.items.len);
    for (digits.items, 0..) |digit, index| {
        const alphabet_index: usize = if (digit == -2) 36 else if (digit == -1) 37 else @intCast(digit);
        output[index] = alphabet[alphabet_index];
    }
    return output;
}

pub const Client = struct {
    http: std.http.Client,
    io: std.Io,
    config: *const Config,
    shared: *GuestTokenCache,
    metadata_trace: MetadataTrace = .{},
    retry_evidence: ?RetryEvidence = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: *const Config, shared: *GuestTokenCache) Client {
        return .{
            .http = .{ .allocator = allocator, .io = io },
            .io = io,
            .config = config,
            .shared = shared,
        };
    }

    pub fn deinit(client: *Client) void {
        client.http.deinit();
    }

    pub fn trace(client: *const Client) MetadataTrace {
        return client.metadata_trace;
    }

    pub fn retryEvidence(client: *const Client) ?RetryEvidence {
        return client.retry_evidence;
    }

    fn beginProbe(client: *Client) void {
        client.metadata_trace = .{};
        client.retry_evidence = null;
    }

    fn beginAttempt(client: *Client) void {
        client.metadata_trace = .{};
    }

    fn recordFailure(client: *Client, endpoint: MetadataEndpoint, stage: MetadataStage, status: u16, cause: []const u8) void {
        client.metadata_trace.record(.{ .endpoint = endpoint, .stage = stage, .status = status, .cause = cause });
    }

    fn resetTransport(client: *Client) void {
        const allocator = client.http.allocator;
        client.http.deinit();
        client.http = .{ .allocator = allocator, .io = client.io };
    }

    fn graphql(client: *Client, allocator: std.mem.Allocator, status_id: []const u8, metrics: *Metrics) !job_mod.Probe {
        var token = try client.guestToken(allocator, metrics);
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            const request_url = try graphqlUrl(allocator, client.config.x_graphql_endpoint, status_id);
            const headers = [_]std.http.Header{
                .{ .name = "authorization", .value = "Bearer " ++ public_bearer },
                .{ .name = "x-guest-token", .value = token.slice() },
                .{ .name = "x-twitter-active-user", .value = "yes" },
                .{ .name = "x-twitter-client-language", .value = "en" },
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "accept-language", .value = "en" },
            };
            const started = std.Io.Clock.Timestamp.now(client.io, .awake);
            const response = try client.fetch(allocator, .graphql, .GET, request_url, &headers, max_graphql_response_bytes);
            addDuration(&metrics.graphql_ms, started.untilNow(client.io).raw.toMilliseconds());
            if (response.status == .unauthorized or response.status == .forbidden or response.status == .too_many_requests) {
                client.recordFailure(.graphql, .http_status, @backingInt(response.status), "authorization_rejected");
                if (attempt == 0) {
                    _ = client.shared.invalidateIfEqual(token.slice());
                    token = try client.activateGuestToken(allocator, metrics);
                    continue;
                }
                return if (response.status == .too_many_requests) error.XRateLimited else error.XMetadataRejected;
            }
            if (response.status.class() != .success) {
                client.recordFailure(.graphql, .http_status, @backingInt(response.status), "http_status");
                return metadataStatusError(response.status);
            }
            return normalizeGraphql(allocator, client.config, status_id, response.body, std.Io.Clock.real.now(client.io).toSeconds()) catch |err| {
                client.recordFailure(.graphql, .normalize, 0, @errorName(err));
                return err;
            };
        }
        unreachable;
    }

    fn syndication(client: *Client, allocator: std.mem.Allocator, status_id: []const u8, metrics: *Metrics) !job_mod.Probe {
        const token = try syndicationToken(allocator, status_id);
        const encoded_token = try percentEncode(allocator, token);
        const request_url = try std.fmt.allocPrint(allocator, "{s}?id={s}&token={s}&lang=en", .{ client.config.x_syndication_endpoint, status_id, encoded_token });
        if (request_url.len > max_graphql_url_bytes) return error.XMetadataTooLarge;
        const headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "accept-language", .value = "en" },
        };
        const started = std.Io.Clock.Timestamp.now(client.io, .awake);
        const response = try client.fetch(allocator, .syndication, .GET, request_url, &headers, max_syndication_response_bytes);
        addDuration(&metrics.syndication_ms, started.untilNow(client.io).raw.toMilliseconds());
        if (response.status.class() != .success) {
            client.recordFailure(.syndication, .http_status, @backingInt(response.status), "http_status");
            return metadataStatusError(response.status);
        }
        return normalizeSyndication(allocator, client.config, status_id, response.body, std.Io.Clock.real.now(client.io).toSeconds()) catch |err| {
            client.recordFailure(.syndication, .normalize, 0, @errorName(err));
            return err;
        };
    }

    fn guestToken(client: *Client, allocator: std.mem.Allocator, metrics: *Metrics) !GuestToken {
        return client.shared.get() orelse client.activateGuestToken(allocator, metrics);
    }

    fn activateGuestToken(client: *Client, allocator: std.mem.Allocator, metrics: *Metrics) !GuestToken {
        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = "Bearer " ++ public_bearer },
            .{ .name = "accept", .value = "application/json" },
        };
        const started = std.Io.Clock.Timestamp.now(client.io, .awake);
        const response = try client.fetch(allocator, .guest, .POST, client.config.x_guest_endpoint, &headers, max_guest_response_bytes);
        addDuration(&metrics.guest_activation_ms, started.untilNow(client.io).raw.toMilliseconds());
        if (response.status.class() != .success) {
            client.recordFailure(.guest, .http_status, @backingInt(response.status), "http_status");
            return metadataStatusError(response.status);
        }
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, response.body, .{ .max_value_len = max_guest_response_bytes }) catch {
            client.recordFailure(.guest, .normalize, 0, "malformed_json");
            return error.XMetadataMalformed;
        };
        const root = objectFromValue(parsed) orelse return error.XInvalidMetadata;
        const value = stringValue(root.get("guest_token")) orelse return error.XInvalidMetadata;
        if (value.len == 0 or value.len > 128 or std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.XInvalidMetadata;
        _ = client.shared.storeIfEmpty(value);
        return client.shared.get() orelse error.XMetadataRejected;
    }

    fn fetch(
        client: *Client,
        allocator: std.mem.Allocator,
        endpoint: MetadataEndpoint,
        method: std.http.Method,
        raw_url: []const u8,
        extra_headers: []const std.http.Header,
        maximum_bytes: usize,
    ) !HttpResponse {
        const uri = std.Uri.parse(raw_url) catch return error.InvalidXEndpoint;
        var request = client.http.request(method, uri, .{
            .keep_alive = true,
            .redirect_behavior = .not_allowed,
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = extra_headers,
        }) catch |err| {
            client.recordFailure(endpoint, .request, 0, @errorName(err));
            return metadataTransportError(err);
        };
        defer request.deinit();
        configureSocketTimeout(request.connection.?, client.config.x_metadata_timeout_seconds) catch |err| {
            request.connection.?.closing = true;
            client.recordFailure(endpoint, .request, 0, @errorName(err));
            return metadataTransportError(err);
        };
        if (method.requestHasBody()) {
            request.sendBodyComplete("") catch |err| {
                request.connection.?.closing = true;
                client.recordFailure(endpoint, .send, 0, @errorName(err));
                return metadataTransportError(err);
            };
        } else {
            request.sendBodiless() catch |err| {
                request.connection.?.closing = true;
                client.recordFailure(endpoint, .send, 0, @errorName(err));
                return metadataTransportError(err);
            };
        }
        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch |err| {
            request.connection.?.closing = true;
            client.recordFailure(endpoint, .response_head, 0, @errorName(err));
            return metadataTransportError(err);
        };
        if (response.head.content_length) |declared| if (declared > maximum_bytes) {
            request.connection.?.closing = true;
            client.recordFailure(endpoint, .body_bound, @backingInt(response.head.status), "declared_too_large");
            return error.XMetadataTooLarge;
        };
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        if (response.head.content_length) |declared| try body.ensureTotalCapacity(allocator, @intCast(declared));
        var transfer_buffer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const count = reader.readSliceShort(&buffer) catch |err| switch (err) {
                error.ReadFailed => {
                    const cause = response.bodyErr() orelse err;
                    request.connection.?.closing = true;
                    client.recordFailure(endpoint, .response_body, @backingInt(response.head.status), @errorName(cause));
                    return metadataTransportError(cause);
                },
            };
            if (count == 0) break;
            if (body.items.len > maximum_bytes - count) {
                request.connection.?.closing = true;
                client.recordFailure(endpoint, .body_bound, @backingInt(response.head.status), "actual_too_large");
                return error.XMetadataTooLarge;
            }
            try body.appendSlice(allocator, buffer[0..count]);
        }
        if (response.head.content_length) |declared| if (@as(u64, @intCast(body.items.len)) != declared) {
            request.connection.?.closing = true;
            client.recordFailure(endpoint, .response_body, @backingInt(response.head.status), "content_length_mismatch");
            return error.XMetadataTransportFailed;
        };
        return .{ .status = response.head.status, .body = try body.toOwnedSlice(allocator) };
    }
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []const u8,
};

fn metadataStatusError(status: std.http.Status) anyerror {
    if (status == .too_many_requests) return error.XRateLimited;
    if (status.class() == .server_error) return error.XMetadataServerError;
    return error.XMetadataRejected;
}

fn metadataTransportError(err: anyerror) anyerror {
    const name = @errorName(err);
    if (std.mem.indexOf(u8, name, "TimedOut") != null or std.mem.indexOf(u8, name, "Timeout") != null or std.mem.eql(u8, name, "WouldBlock")) return error.XMetadataTimedOut;
    return error.XMetadataTransportFailed;
}

fn retryableMetadataFailure(err: anyerror) bool {
    return err == error.XMetadataTransportFailed or err == error.XMetadataTimedOut or err == error.XMetadataServerError or err == error.XMetadataMalformed;
}

const Resolution = struct {
    probe: job_mod.Probe,
    path: ResolutionPath,
};

fn resolveOnce(allocator: std.mem.Allocator, client: *Client, status_id: []const u8, metrics: *Metrics) !Resolution {
    const graphql_probe = client.graphql(allocator, status_id, metrics) catch |graphql_error| {
        if (finalWithoutSyndication(graphql_error)) return graphql_error;
        const syndication_probe = client.syndication(allocator, status_id, metrics) catch |syndication_error| {
            return finalResolutionError(graphql_error, syndication_error);
        };
        return .{ .probe = syndication_probe, .path = .syndication };
    };
    return .{ .probe = graphql_probe, .path = .graphql };
}

pub fn probeDiagnostic(allocator: std.mem.Allocator, client: *Client, raw_url: []const u8) !Diagnostic {
    const status = try parseStatusUrl(raw_url);
    const started = std.Io.Clock.Timestamp.now(client.io, .awake);
    var metrics = Metrics{};
    client.beginProbe();
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        client.beginAttempt();
        const resolved = resolveOnce(allocator, client, status.status_id, &metrics) catch |err| {
            if (attempt == 0 and retryableMetadataFailure(err)) {
                client.retry_evidence = .{ .cause = @errorName(err), .trace = client.metadata_trace };
                client.resetTransport();
                continue;
            }
            return err;
        };
        metrics.total_ms = elapsedMilliseconds(started, client.io);
        return .{ .probe = resolved.probe, .resolution_path = resolved.path, .metrics = metrics, .metadata_retries = attempt };
    }
    unreachable;
}

pub fn writeDiagnostic(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    diagnostic: Diagnostic,
    ytdlp_probe: ?YtdlpComparison,
    as_json: bool,
) !void {
    const plan = diagnostic.probe.x_plan orelse return error.MissingXPlan;
    const items = try allocator.alloc(DiagnosticItem, plan.items.len);
    for (plan.items, 0..) |item, index| {
        const best = if (item.video_variants.len > 0) item.video_variants[0] else null;
        items[index] = .{
            .kind = item.kind,
            .width = item.width,
            .height = item.height,
            .best_height = if (best) |variant| variant.height else null,
            .best_bitrate = if (best) |variant| variant.bitrate else null,
            .direct_variants = item.video_variants.len,
        };
    }
    const comparison = if (ytdlp_probe) |probe| compareNormalized(plan.items, probe.items) else null;
    if (as_json) {
        try std.json.Stringify.value(.{
            .status_id = plan.status_id,
            .title = diagnostic.probe.title,
            .media_kind = diagnostic.probe.media_kind,
            .item_count = diagnostic.probe.item_count,
            .video_count = diagnostic.probe.video_count,
            .image_count = diagnostic.probe.image_count,
            .items = items,
            .resolution_path = diagnostic.resolution_path,
            .metrics = diagnostic.metrics,
            .metadata_retries = diagnostic.metadata_retries,
            .ytdlp_comparison = comparison,
        }, .{ .whitespace = .indent_2 }, writer);
        try writer.writeByte('\n');
        return;
    }
    try writer.print("X status {s}: {s}\n", .{ plan.status_id, diagnostic.probe.title });
    try writer.print("source={s} kind={s} items={d} videos={d} photos={d} total_ms={d} metadata_retries={d}\n", .{ @tagName(diagnostic.resolution_path), @tagName(diagnostic.probe.media_kind), diagnostic.probe.item_count, diagnostic.probe.video_count, diagnostic.probe.image_count, diagnostic.metrics.total_ms, diagnostic.metadata_retries });
    for (items, 0..) |item, index| try writer.print("item {d}: kind={s} width={?} height={?} best_height={?} best_bitrate={?} direct_variants={d}\n", .{ index + 1, @tagName(item.kind), item.width, item.height, item.best_height, item.best_bitrate, item.direct_variants });
    if (comparison) |value| try writer.print("yt-dlp: items={d} maximum_height={?} item_count_match={s} media_order_match={s} lower_native_items={d}\n", .{ value.item_count, value.maximum_height, if (value.native_item_count_matches) "yes" else "no", if (value.native_media_order_matches) "yes" else "no", value.lower_native_resolution_items });
}

const DiagnosticItem = struct {
    kind: job_mod.XMediaKind,
    width: ?u32,
    height: ?u32,
    best_height: ?u32,
    best_bitrate: ?u64,
    direct_variants: usize,
};

const Comparison = struct {
    item_count: usize,
    maximum_height: ?u32,
    maximum_direct_height: ?u32,
    maximum_hls_height: ?u32,
    native_item_count_matches: bool,
    native_media_kind_matches: bool,
    native_media_order_matches: bool,
    lower_native_resolution_items: usize,
    items: []const YtdlpComparisonItem,
};

fn compareNormalized(native_items: []const job_mod.XPlanItem, ytdlp_items: []const YtdlpComparisonItem) Comparison {
    var maximum_height: ?u32 = null;
    var maximum_direct_height: ?u32 = null;
    var maximum_hls_height: ?u32 = null;
    var order_matches = native_items.len == ytdlp_items.len;
    var native_videos: usize = 0;
    var native_images: usize = 0;
    var ytdlp_videos: usize = 0;
    var ytdlp_images: usize = 0;
    var lower_native_resolution_items: usize = 0;
    for (ytdlp_items, 0..) |item, index| {
        if (item.maximum_height) |height| maximum_height = @max(maximum_height orelse 0, height);
        if (item.maximum_direct_height) |height| maximum_direct_height = @max(maximum_direct_height orelse 0, height);
        if (item.maximum_hls_height) |height| maximum_hls_height = @max(maximum_hls_height orelse 0, height);
        switch (item.media_kind) {
            .video => ytdlp_videos += 1,
            .image => ytdlp_images += 1,
            else => {},
        }
        if (index >= native_items.len) {
            order_matches = false;
            continue;
        }
        const native_kind: job_mod.MediaKind = switch (native_items[index].kind) {
            .photo => .image,
            .video, .animated_gif => .video,
        };
        if (native_kind != item.media_kind) order_matches = false;
        if (native_kind == .video and native_items[index].video_variants.len > 0 and native_items[index].video_variants[0].height != null and item.maximum_height != null and native_items[index].video_variants[0].height.? < item.maximum_height.?) lower_native_resolution_items += 1;
    }
    for (native_items) |item| switch (item.kind) {
        .photo => native_images += 1,
        .video, .animated_gif => native_videos += 1,
    };
    return .{
        .item_count = ytdlp_items.len,
        .maximum_height = maximum_height,
        .maximum_direct_height = maximum_direct_height,
        .maximum_hls_height = maximum_hls_height,
        .native_item_count_matches = native_items.len == ytdlp_items.len,
        .native_media_kind_matches = native_videos == ytdlp_videos and native_images == ytdlp_images,
        .native_media_order_matches = order_matches,
        .lower_native_resolution_items = lower_native_resolution_items,
        .items = ytdlp_items,
    };
}

pub const ProgressCallback = struct {
    context: *anyopaque,
    update: *const fn (context: *anyopaque, progress: job_mod.Progress) anyerror!void,
};

pub fn acquire(
    result_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    client: *Client,
    environment: *const std.process.Environ.Map,
    job_root: []const u8,
    probe_result: job_mod.Probe,
    selection: job_mod.Selection,
    cancel: *const std.atomic.Value(bool),
    progress_callback: ProgressCallback,
) !job_mod.Acquisition {
    return acquirePlan(result_allocator, scratch_allocator, client, environment, job_root, probe_result, selection, cancel, progress_callback) catch |first_error| {
        if (first_error != error.XMediaRejected) return first_error;
        if (cancel.load(.acquire)) return error.Cancelled;
        const original_plan = probe_result.x_plan orelse return error.InvalidProbe;
        const canonical_url = try std.fmt.allocPrint(scratch_allocator, "https://x.com/i/status/{s}", .{original_plan.status_id});
        const refreshed = probeDiagnostic(scratch_allocator, client, canonical_url) catch return first_error;
        const aligned = alignRefreshedProbe(scratch_allocator, probe_result, refreshed.probe) catch return first_error;
        return acquirePlan(result_allocator, scratch_allocator, client, environment, job_root, aligned, selection, cancel, progress_callback);
    };
}

fn acquirePlan(
    result_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    client: *Client,
    environment: *const std.process.Environ.Map,
    job_root: []const u8,
    probe_result: job_mod.Probe,
    selection: job_mod.Selection,
    cancel: *const std.atomic.Value(bool),
    progress_callback: ProgressCallback,
) !job_mod.Acquisition {
    try job_mod.validateProbe(probe_result);
    try job_mod.validateStart(probe_result, selection, .{ .mode = .original });
    const plan = probe_result.x_plan orelse return error.InvalidProbe;
    if (probe_result.engine != .x_native or plan.items.len == 0) return error.InvalidProbe;

    const work_path = try std.fs.path.join(scratch_allocator, &.{ job_root, "work" });
    const source_path = try std.fs.path.join(scratch_allocator, &.{ job_root, "source" });
    const preview_path = try std.fs.path.join(scratch_allocator, &.{ job_root, "preview" });
    resetAcquisitionDirectories(client.io, work_path, source_path, preview_path) catch return error.XInvalidMediaOutput;
    errdefer resetAcquisitionDirectories(client.io, work_path, source_path, preview_path) catch {};

    const artifacts = try result_allocator.alloc(job_mod.Artifact, plan.items.len);
    const safe_title = try safeFilenameBase(result_allocator, probe_result.title);
    var total: u64 = 0;
    for (plan.items, 0..) |item, index| {
        if (cancel.load(.acquire)) return error.Cancelled;
        const transfer = try transferForSelection(item, selection);
        var temporary_name_buffer: [64]u8 = undefined;
        const temporary_name = try std.fmt.bufPrint(&temporary_name_buffer, "item-{d:0>3}.part", .{index + 1});
        const temporary_path = try std.fs.path.join(scratch_allocator, &.{ work_path, temporary_name });
        const downloaded = try downloadMedia(
            scratch_allocator,
            client,
            transfer.url,
            transfer.kind,
            temporary_path,
            client.config.max_download_bytes - total,
            total,
            @intCast(index + 1),
            @intCast(plan.items.len),
            cancel,
            progress_callback,
        );
        if (transfer.kind == .video) {
            const info = ffmpeg.inspectVideo(scratch_allocator, client.io, client.config, environment, job_root, temporary_path, cancel) catch |err| switch (err) {
                error.Cancelled, error.ToolMissing => return err,
                else => return error.XInvalidMediaOutput,
            };
            try validateVideoInfo(client.config, info, transfer.height_ceiling);
        }

        var stored_name_buffer: [64]u8 = undefined;
        const stored_name = try std.fmt.bufPrint(&stored_name_buffer, "item-{d:0>3}.{s}", .{ index + 1, downloaded.extension });
        const final_path = try std.fs.path.join(scratch_allocator, &.{ source_path, stored_name });
        try std.Io.Dir.cwd().rename(temporary_path, std.Io.Dir.cwd(), final_path, client.io);
        total = std.math.add(u64, total, downloaded.size) catch return error.DownloadTooLarge;
        const poster = if (index == 0 and transfer.kind == .video and total < client.config.max_download_bytes)
            try acquirePoster(result_allocator, scratch_allocator, client, work_path, preview_path, item, index, client.config.max_download_bytes - total, cancel)
        else
            null;
        if (poster) |value| total = std.math.add(u64, total, value.size_bytes) catch return error.DownloadTooLarge;
        artifacts[index] = .{
            .id = try std.fmt.allocPrint(result_allocator, "file-{d}", .{index + 1}),
            .path = try std.fmt.allocPrint(result_allocator, "source/{s}", .{stored_name}),
            .filename = if (plan.items.len == 1)
                try std.fmt.allocPrint(result_allocator, "{s}.{s}", .{ safe_title, downloaded.extension })
            else
                try std.fmt.allocPrint(result_allocator, "{s}-{d}.{s}", .{ safe_title, index + 1, downloaded.extension }),
            .media_kind = if (transfer.kind == .photo) .image else .video,
            .mime_type = downloaded.mime_type,
            .size_bytes = downloaded.size,
            .primary = index == 0,
            .poster = poster,
        };
    }

    var acquisition = job_mod.Acquisition{ .artifacts = artifacts, .total_bytes = total };
    if (artifacts.len > 1) {
        const outputs = try result_allocator.alloc(job_mod.Artifact, 1);
        outputs[0] = try zip_bundle.createBundle(result_allocator, scratch_allocator, client.io, job_root, artifacts, probe_result.title, client.config.max_output_bytes);
        acquisition.output_artifacts = outputs;
    }
    return acquisition;
}

fn acquirePoster(
    result_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    client: *Client,
    work_path: []const u8,
    preview_path: []const u8,
    item: job_mod.XPlanItem,
    index: usize,
    remaining_bytes: u64,
    cancel: *const std.atomic.Value(bool),
) !?job_mod.Poster {
    const thumbnail_url = item.thumbnail_url orelse return null;
    const maximum_bytes = @min(remaining_bytes, job_mod.max_poster_bytes);
    if (maximum_bytes == 0) return null;

    var temporary_name_buffer: [64]u8 = undefined;
    const temporary_name = try std.fmt.bufPrint(&temporary_name_buffer, "poster-{d:0>3}.part", .{index + 1});
    const temporary_path = try std.fs.path.join(scratch_allocator, &.{ work_path, temporary_name });
    var ignored_progress: u8 = 0;
    const downloaded = downloadMedia(
        scratch_allocator,
        client,
        thumbnail_url,
        .photo,
        temporary_path,
        maximum_bytes,
        0,
        1,
        1,
        cancel,
        .{ .context = &ignored_progress, .update = ignorePosterProgress },
    ) catch |err| switch (err) {
        error.Cancelled => return err,
        else => {
            std.log.warn("native_x_poster_unavailable ordinal={d} error={s}", .{ item.ordinal, @errorName(err) });
            return null;
        },
    };

    var stored_name_buffer: [64]u8 = undefined;
    const stored_name = try std.fmt.bufPrint(&stored_name_buffer, "item-{d:0>3}.{s}", .{ index + 1, downloaded.extension });
    const final_path = try std.fs.path.join(scratch_allocator, &.{ preview_path, stored_name });
    std.Io.Dir.cwd().rename(temporary_path, std.Io.Dir.cwd(), final_path, client.io) catch |err| {
        std.Io.Dir.cwd().deleteFile(client.io, temporary_path) catch {};
        std.log.warn("native_x_poster_unavailable ordinal={d} error={s}", .{ item.ordinal, @errorName(err) });
        return null;
    };
    return .{
        .path = try std.fmt.allocPrint(result_allocator, "preview/{s}", .{stored_name}),
        .mime_type = downloaded.mime_type,
        .size_bytes = downloaded.size,
    };
}

fn ignorePosterProgress(_: *anyopaque, _: job_mod.Progress) !void {}

const TransferKind = enum { photo, video };

const SelectedTransfer = struct {
    kind: TransferKind,
    url: []const u8,
    height_ceiling: ?u32 = null,
};

fn transferForSelection(item: job_mod.XPlanItem, selection: job_mod.Selection) !SelectedTransfer {
    return switch (item.kind) {
        .photo => {
            if (selection.kind != .image and selection.kind != .all) return error.InvalidSelection;
            return .{ .kind = .photo, .url = item.photo_url orelse return error.InvalidProbe };
        },
        .video, .animated_gif => {
            if (selection.kind != .video and selection.kind != .all) return error.InvalidSelection;
            const variant_id = selection.variant_id orelse if (selection.kind == .all) "best" else return error.InvalidSelection;
            const variant = try selectVideoVariant(item.video_variants, variant_id);
            const ceiling = if (std.mem.startsWith(u8, variant_id, "video-")) std.fmt.parseInt(u32, variant_id["video-".len..], 10) catch return error.InvalidSelection else null;
            return .{ .kind = .video, .url = variant.url, .height_ceiling = ceiling };
        },
    };
}

fn selectVideoVariant(variants: []const job_mod.XVideoVariant, variant_id: []const u8) !job_mod.XVideoVariant {
    if (variants.len == 0) return error.VariantUnavailable;
    if (std.mem.eql(u8, variant_id, "best")) return variants[0];
    if (!std.mem.startsWith(u8, variant_id, "video-")) return error.VariantUnavailable;
    const ceiling = std.fmt.parseInt(u32, variant_id["video-".len..], 10) catch return error.VariantUnavailable;
    for (variants) |variant| if (variant.height != null and variant.height.? <= ceiling) return variant;
    return error.VariantUnavailable;
}

const DownloadedMedia = struct {
    size: u64,
    mime_type: []const u8,
    extension: []const u8,
};

fn downloadMedia(
    scratch_allocator: std.mem.Allocator,
    client: *Client,
    initial_url: []const u8,
    kind: TransferKind,
    destination: []const u8,
    maximum_bytes: u64,
    previous_bytes: u64,
    item_index: u8,
    item_count: u8,
    cancel: *const std.atomic.Value(bool),
    callback: ProgressCallback,
) !DownloadedMedia {
    if (maximum_bytes == 0) return error.DownloadTooLarge;
    var current_url: []const u8 = try scratch_allocator.dupe(u8, initial_url);
    var redirects: u8 = 0;
    while (true) {
        if (cancel.load(.acquire)) return error.Cancelled;
        if (!validMediaRequestUrl(client.config, current_url, kind)) return error.XMediaHostRejected;
        const uri = std.Uri.parse(current_url) catch return error.XMediaHostRejected;
        const headers = [_]std.http.Header{.{
            .name = "accept",
            .value = if (kind == .photo) "image/jpeg,image/png,image/webp,image/gif" else "video/mp4,application/octet-stream;q=0.5",
        }};
        var request = client.http.request(.GET, uri, .{
            .keep_alive = true,
            .redirect_behavior = .unhandled,
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &headers,
        }) catch return error.XMediaRejected;
        defer request.deinit();
        configureSocketTimeout(request.connection.?, client.config.download_inactivity_seconds) catch return error.XMediaRejected;
        request.sendBodiless() catch return error.XMediaRejected;
        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch return error.XMediaRejected;
        if (response.head.status.class() == .redirect) {
            request.connection.?.closing = true;
            if (redirects == 3) return error.XMediaRedirectRejected;
            const location = response.head.location orelse return error.XMediaRedirectRejected;
            const next_url = resolveRedirect(scratch_allocator, current_url, location) catch return error.XMediaRedirectRejected;
            if (!validMediaRequestUrl(client.config, next_url, kind)) return error.XMediaRedirectRejected;
            current_url = next_url;
            redirects += 1;
            continue;
        }
        if (response.head.status.class() != .success) {
            request.connection.?.closing = true;
            return error.XMediaRejected;
        }
        if (response.head.content_length) |declared| {
            if (declared == 0) {
                request.connection.?.closing = true;
                return error.XInvalidMediaOutput;
            }
            if (declared > maximum_bytes) {
                request.connection.?.closing = true;
                return error.DownloadTooLarge;
            }
        }
        const media_type = responseMediaType(kind, response.head.content_type) catch |err| {
            request.connection.?.closing = true;
            return err;
        };

        const file = std.Io.Dir.cwd().createFile(client.io, destination, .{
            .read = true,
            .exclusive = true,
            .permissions = @fromBackingInt(@intCast(0o600)),
        }) catch return error.XInvalidMediaOutput;
        var complete = false;
        defer {
            file.close(client.io);
            if (!complete) std.Io.Dir.cwd().deleteFile(client.io, destination) catch {};
        }
        var file_buffer: [8 * 1024]u8 = undefined;
        var file_writer = file.writer(client.io, &file_buffer);
        var transfer_buffer: [8 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var buffer: [64 * 1024]u8 = undefined;
        var prefix: [64]u8 = undefined;
        var prefix_length: usize = 0;
        var total: u64 = 0;
        const started = std.Io.Clock.Timestamp.now(client.io, .awake);
        while (true) {
            if (cancel.load(.acquire)) return error.Cancelled;
            const count = reader.readSliceShort(&buffer) catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr() orelse error.XMediaRejected,
            };
            if (count == 0) break;
            if (count > maximum_bytes - total) return error.DownloadTooLarge;
            if (prefix_length < prefix.len) {
                const copied = @min(prefix.len - prefix_length, count);
                @memcpy(prefix[prefix_length .. prefix_length + copied], buffer[0..copied]);
                prefix_length += copied;
            }
            try file_writer.interface.writeAll(buffer[0..count]);
            total += count;
            const elapsed_ms = @max(elapsedMilliseconds(started, client.io), 1);
            try callback.update(callback.context, .{
                .phase = .source_download,
                .label = "Downloading media",
                .bytes_downloaded = previous_bytes + total,
                .bytes_total = if (item_count == 1) response.head.content_length else null,
                .bytes_total_kind = if (item_count == 1 and response.head.content_length != null) .exact else null,
                .fraction = if (item_count == 1 and response.head.content_length != null) @min(1.0, @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(response.head.content_length.?))) else null,
                .speed_bytes_per_second = @as(f64, @floatFromInt(total)) * 1000.0 / @as(f64, @floatFromInt(elapsed_ms)),
                .item_index = item_index,
                .item_count = item_count,
                .updated_at = std.Io.Clock.real.now(client.io).toSeconds(),
            });
        }
        try file_writer.flush();
        try file.sync(client.io);
        if (total == 0 or (response.head.content_length != null and response.head.content_length.? != total)) return error.XInvalidMediaOutput;
        if (!validMediaMagic(kind, media_type, prefix[0..prefix_length])) return error.XInvalidMediaOutput;
        complete = true;
        return .{ .size = total, .mime_type = media_type.mime_type, .extension = media_type.extension };
    }
}

const ResponseMediaType = struct {
    mime_type: []const u8,
    extension: []const u8,
};

fn responseMediaType(kind: TransferKind, content_type: ?[]const u8) !ResponseMediaType {
    const raw = content_type orelse if (kind == .video) return .{ .mime_type = "video/mp4", .extension = "mp4" } else return error.XInvalidMediaOutput;
    const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    const value = std.mem.trim(u8, raw[0..end], " \t");
    if (kind == .video) {
        if (!std.ascii.eqlIgnoreCase(value, "video/mp4") and !std.ascii.eqlIgnoreCase(value, "application/octet-stream")) return error.XInvalidMediaOutput;
        return .{ .mime_type = "video/mp4", .extension = "mp4" };
    }
    if (std.ascii.eqlIgnoreCase(value, "image/jpeg") or std.ascii.eqlIgnoreCase(value, "image/jpg")) return .{ .mime_type = "image/jpeg", .extension = "jpg" };
    if (std.ascii.eqlIgnoreCase(value, "image/png")) return .{ .mime_type = "image/png", .extension = "png" };
    if (std.ascii.eqlIgnoreCase(value, "image/webp")) return .{ .mime_type = "image/webp", .extension = "webp" };
    if (std.ascii.eqlIgnoreCase(value, "image/gif")) return .{ .mime_type = "image/gif", .extension = "gif" };
    return error.XInvalidMediaOutput;
}

fn validMediaMagic(kind: TransferKind, media_type: ResponseMediaType, bytes: []const u8) bool {
    if (kind == .video) return hasFtypBox(bytes);
    if (std.mem.eql(u8, media_type.extension, "jpg")) return bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xff\xd8\xff");
    if (std.mem.eql(u8, media_type.extension, "png")) return bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n");
    if (std.mem.eql(u8, media_type.extension, "gif")) return bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"));
    if (std.mem.eql(u8, media_type.extension, "webp")) return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP");
    return false;
}

fn hasFtypBox(bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset <= 32 and offset + 8 <= bytes.len) {
        const box_size = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (std.mem.eql(u8, bytes[offset + 4 .. offset + 8], "ftyp")) return box_size >= 8 and box_size <= 4096;
        if (box_size < 8 or box_size > bytes.len - offset) return false;
        offset += box_size;
    }
    return false;
}

fn validateVideoInfo(config: *const Config, info: ffmpeg.MediaInfo, height_ceiling: ?u32) !void {
    if (info.video_codec == null) return error.XInvalidMediaOutput;
    if (info.width) |width| if (width == 0 or width > 16_384) return error.XInvalidMediaOutput;
    if (info.height) |height| {
        if (height == 0 or height > 16_384) return error.XInvalidMediaOutput;
        if (height_ceiling) |ceiling| if (height > ceiling) return error.XInvalidMediaOutput;
    } else if (height_ceiling != null) return error.XInvalidMediaOutput;
    if (info.duration_seconds) |duration| {
        if (!std.math.isFinite(duration) or duration < 0) return error.XInvalidMediaOutput;
        if (config.max_media_duration_seconds > 0 and duration > @as(f64, @floatFromInt(config.max_media_duration_seconds))) return error.MediaTooLong;
    }
}

fn resetAcquisitionDirectories(io: std.Io, work_path: []const u8, source_path: []const u8, preview_path: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io, work_path) catch {};
    std.Io.Dir.cwd().deleteTree(io, source_path) catch {};
    std.Io.Dir.cwd().deleteTree(io, preview_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, work_path);
    try std.Io.Dir.cwd().createDirPath(io, source_path);
    try std.Io.Dir.cwd().createDirPath(io, preview_path);
}

fn resolveRedirect(allocator: std.mem.Allocator, current_url: []const u8, location: []const u8) ![]const u8 {
    if (location.len == 0 or location.len > 2048 or std.mem.indexOfAny(u8, location, "\r\n\x00") != null) return error.InvalidRedirect;
    const base = std.Uri.parse(current_url) catch return error.InvalidRedirect;
    const storage = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(storage);
    if (location.len > storage.len) return error.InvalidRedirect;
    @memcpy(storage[0..location.len], location);
    var available = storage;
    const resolved = std.Uri.resolveInPlace(base, location.len, &available) catch return error.InvalidRedirect;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try resolved.format(&output.writer);
    const result = try output.toOwnedSlice();
    if (result.len > 2048) return error.InvalidRedirect;
    return result;
}

fn validMediaRequestUrl(config: *const Config, raw_url: []const u8, kind: TransferKind) bool {
    if (!validMediaUrl(config, raw_url, if (kind == .photo) .photo else .video)) return false;
    var host_buffer: [512]u8 = undefined;
    _ = media_url.validate(raw_url, &host_buffer) catch |err| {
        if (err != error.PrivateAddress or !fixtureHttpAllowed(config)) return false;
        const uri = std.Uri.parse(raw_url) catch return false;
        const host_component = uri.host orelse return false;
        var fixture_host_buffer: [512]u8 = undefined;
        if (!loopbackHost(host_component.toRaw(&fixture_host_buffer) catch return false)) return false;
    };
    return true;
}

fn alignRefreshedProbe(allocator: std.mem.Allocator, original: job_mod.Probe, refreshed: job_mod.Probe) !job_mod.Probe {
    const original_plan = original.x_plan orelse return error.InvalidProbe;
    const refreshed_plan = refreshed.x_plan orelse return error.XProviderChanged;
    if (!std.mem.eql(u8, original_plan.status_id, refreshed_plan.status_id) or original_plan.items.len != refreshed_plan.items.len) return error.XProviderChanged;
    const items = try allocator.alloc(job_mod.XPlanItem, original_plan.items.len);
    var used: [job_mod.max_media_items]bool = @splat(false);
    for (original_plan.items, 0..) |wanted, index| {
        var match: ?usize = null;
        for (refreshed_plan.items, 0..) |candidate, candidate_index| {
            if (!used[candidate_index] and std.mem.eql(u8, candidate.id, wanted.id)) {
                match = candidate_index;
                break;
            }
        }
        if (match == null and wanted.ordinal > 0 and wanted.ordinal <= refreshed_plan.items.len and !used[wanted.ordinal - 1]) match = wanted.ordinal - 1;
        const matched_index = match orelse return error.XProviderChanged;
        const matched = refreshed_plan.items[matched_index];
        if (matched.kind != wanted.kind) return error.XProviderChanged;
        used[matched_index] = true;
        items[index] = matched;
        items[index].ordinal = wanted.ordinal;
    }
    var aligned = refreshed;
    aligned.title = original.title;
    aligned.x_plan = .{
        .status_id = refreshed_plan.status_id,
        .resolved_at = refreshed_plan.resolved_at,
        .items = items,
    };
    try job_mod.validateProbe(aligned);
    return aligned;
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

fn finalWithoutSyndication(err: anyerror) bool {
    return switch (err) {
        error.InvalidUrl,
        error.InvalidXUrl,
        error.PrivateAddress,
        error.XPostUnavailable,
        error.XPostPrivate,
        error.XLoginRequired,
        error.XNoMedia,
        error.UnsupportedXShape,
        error.TooManyMediaItems,
        error.MediaTooLong,
        => true,
        else => false,
    };
}

fn finalResolutionError(graphql_error: anyerror, syndication_error: anyerror) anyerror {
    if (finalWithoutSyndication(syndication_error)) return syndication_error;
    if (graphql_error == error.XRateLimited or syndication_error == error.XRateLimited) return error.XRateLimited;
    if (graphql_error == error.XNoDirectVideo or syndication_error == error.XNoDirectVideo) return error.XNoDirectVideo;
    if (graphql_error == error.XProviderChanged or syndication_error == error.XProviderChanged) return error.XProviderChanged;
    if (retryableMetadataFailure(syndication_error)) return syndication_error;
    return graphql_error;
}

fn graphqlUrl(allocator: std.mem.Allocator, endpoint: []const u8, status_id: []const u8) ![]const u8 {
    const variables = try std.fmt.allocPrint(allocator, "{{\"tweetId\":\"{s}\",\"withCommunity\":false,\"includePromotedContent\":false,\"withVoice\":false}}", .{status_id});
    const encoded_variables = try percentEncode(allocator, variables);
    const encoded_features = try percentEncode(allocator, graphql_features);
    const encoded_toggles = try percentEncode(allocator, graphql_field_toggles);
    const result = try std.fmt.allocPrint(allocator, "{s}?variables={s}&features={s}&fieldToggles={s}", .{ endpoint, encoded_variables, encoded_features, encoded_toggles });
    if (result.len > max_graphql_url_bytes) return error.XMetadataTooLarge;
    return result;
}

fn addDuration(target: *?u64, value: i64) void {
    const bounded: u64 = @intCast(@max(value, 0));
    target.* = if (target.*) |current| current +| bounded else bounded;
}

fn elapsedMilliseconds(started: std.Io.Clock.Timestamp, io: std.Io) u64 {
    return @intCast(@max(started.untilNow(io).raw.toMilliseconds(), 0));
}

fn configureSocketTimeout(connection: *std.http.Client.Connection, seconds: u16) !void {
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        const timeout: std.posix.timeval = .{ .sec = seconds, .usec = 0 };
        const handle = connection.stream_reader.stream.socket.handle;
        try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
    }
}

const ResolvedPost = struct {
    status_id: []const u8,
    title: []const u8,
    items: []const ResolvedItem,
};

const ResolvedItem = struct {
    id: []const u8,
    ordinal: u8,
    kind: job_mod.XMediaKind,
    width: ?u32,
    height: ?u32,
    duration_ms: ?u64,
    thumbnail_url: ?[]const u8,
    photo_url: ?[]const u8,
    direct_variants: []const DirectVariant,
};

const DirectVariant = struct {
    url: []const u8,
    width: ?u32,
    height: ?u32,
    bitrate: ?u64,
};

fn normalizeGraphql(
    allocator: std.mem.Allocator,
    config: *const Config,
    status_id: []const u8,
    bytes: []const u8,
    resolved_at: i64,
) !job_mod.Probe {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{ .max_value_len = max_graphql_response_bytes }) catch return error.XMetadataMalformed;
    const root = objectFromValue(parsed) orelse return error.XProviderChanged;
    const data = objectField(root, "data") orelse return error.XProviderChanged;
    const tweet_result = objectField(data, "tweetResult") orelse return error.XProviderChanged;
    const result_value = tweet_result.get("result") orelse return error.XProviderChanged;
    var tweet = try unwrapTweetResult(result_value);

    if (objectField(tweet, "legacy")) |legacy| if (objectField(legacy, "retweeted_status_result")) |repost| {
        if (repost.get("result")) |original| tweet = try unwrapTweetResult(original);
    };

    const legacy = objectField(tweet, "legacy") orelse return error.XProviderChanged;
    var media = attachedMedia(legacy);
    if (media == null or media.?.len == 0) {
        if (objectField(tweet, "quoted_status_result")) |quoted| if (quoted.get("result")) |quoted_result| {
            const quoted_tweet = try unwrapTweetResult(quoted_result);
            if (objectField(quoted_tweet, "legacy")) |quoted_legacy| media = attachedMedia(quoted_legacy);
        };
    }
    const media_values = media orelse {
        if (tweet.get("card") != null or legacy.get("card") != null) return error.UnsupportedXShape;
        return error.XNoMedia;
    };
    if (media_values.len == 0) {
        if (tweet.get("card") != null or legacy.get("card") != null) return error.UnsupportedXShape;
        return error.XNoMedia;
    }
    const user_name = graphqlUserName(tweet);
    const text = stringValue(legacy.get("full_text")) orelse stringValue(legacy.get("text"));
    const title = try cleanTitle(allocator, user_name, text, "X media");
    const items = try normalizeItems(allocator, config, status_id, media_values);
    return probeFromResolved(allocator, config, .{ .status_id = status_id, .title = title, .items = items }, resolved_at);
}

fn normalizeSyndication(
    allocator: std.mem.Allocator,
    config: *const Config,
    status_id: []const u8,
    bytes: []const u8,
    resolved_at: i64,
) !job_mod.Probe {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{ .max_value_len = max_syndication_response_bytes }) catch return error.XMetadataMalformed;
    const root = objectFromValue(parsed) orelse return error.XInvalidMetadata;
    if (stringValue(root.get("__typename"))) |typename| {
        if (std.mem.eql(u8, typename, "TweetUnavailable")) return unavailableReason(stringValue(root.get("reason")));
        if (!std.mem.eql(u8, typename, "Tweet")) return error.XProviderChanged;
    }
    var media = arrayField(root, "mediaDetails");
    if (media == null or media.?.len == 0) {
        if (objectField(root, "quoted_tweet")) |quoted| media = arrayField(quoted, "mediaDetails");
    }
    const media_values = media orelse {
        if (root.get("card") != null) return error.UnsupportedXShape;
        if (root.get("text") != null or root.get("user") != null) return error.XNoMedia;
        return error.XProviderChanged;
    };
    if (media_values.len == 0) {
        if (root.get("card") != null) return error.UnsupportedXShape;
        return error.XNoMedia;
    }
    const user_name = if (objectField(root, "user")) |user| stringValue(user.get("name")) else null;
    const title = try cleanTitle(allocator, user_name, stringValue(root.get("text")), "X media");
    const items = try normalizeItems(allocator, config, status_id, media_values);
    return probeFromResolved(allocator, config, .{ .status_id = status_id, .title = title, .items = items }, resolved_at);
}

fn unwrapTweetResult(value: std.json.Value) !std.json.ObjectMap {
    var result = objectFromValue(value) orelse return error.XProviderChanged;
    const typename = stringValue(result.get("__typename")) orelse return error.XProviderChanged;
    if (std.mem.eql(u8, typename, "TweetWithVisibilityResults")) {
        result = objectField(result, "tweet") orelse return error.XProviderChanged;
        const inner_type = stringValue(result.get("__typename")) orelse return error.XProviderChanged;
        if (!std.mem.eql(u8, inner_type, "Tweet")) return error.XProviderChanged;
        return result;
    }
    if (std.mem.eql(u8, typename, "TweetUnavailable")) return unavailableReason(stringValue(result.get("reason")));
    if (std.mem.eql(u8, typename, "TweetTombstone") or result.get("tombstone") != null) return error.XPostUnavailable;
    if (!std.mem.eql(u8, typename, "Tweet")) return error.XProviderChanged;
    return result;
}

fn unavailableReason(reason: ?[]const u8) anyerror {
    const value = reason orelse return error.XProviderChanged;
    if (std.mem.eql(u8, value, "Protected")) return error.XPostPrivate;
    if (std.mem.eql(u8, value, "NsfwLoggedOut") or std.mem.eql(u8, value, "NsfwViewerHasNoStatedAge")) return error.XLoginRequired;
    inline for (.{ "Deleted", "TweetDeleted", "Suspended", "UserUnavailable", "AuthorUnavailable", "StatusUnavailable" }) |known| {
        if (std.mem.eql(u8, value, known)) return error.XPostUnavailable;
    }
    return error.XProviderChanged;
}

fn attachedMedia(legacy: std.json.ObjectMap) ?[]const std.json.Value {
    const entities = objectField(legacy, "extended_entities") orelse return null;
    return arrayField(entities, "media");
}

fn graphqlUserName(tweet: std.json.ObjectMap) ?[]const u8 {
    const core = objectField(tweet, "core") orelse return null;
    const user_results = objectField(core, "user_results") orelse return null;
    const result = objectField(user_results, "result") orelse return null;
    if (objectField(result, "legacy")) |legacy| if (stringValue(legacy.get("name"))) |name| return name;
    if (objectField(result, "core")) |user_core| return stringValue(user_core.get("name"));
    return null;
}

fn normalizeItems(
    allocator: std.mem.Allocator,
    config: *const Config,
    status_id: []const u8,
    values: []const std.json.Value,
) ![]const ResolvedItem {
    if (values.len == 0) return error.XNoMedia;
    if (values.len > job_mod.max_media_items) return error.TooManyMediaItems;
    var items: std.ArrayList(ResolvedItem) = .empty;
    defer items.deinit(allocator);
    for (values) |value| {
        const media = objectFromValue(value) orelse return error.XInvalidMetadata;
        const type_name = stringValue(media.get("type")) orelse return error.UnsupportedXShape;
        const ordinal: u8 = @intCast(items.items.len + 1);
        const id = try mediaId(allocator, media, status_id, ordinal);
        if (std.mem.eql(u8, type_name, "photo")) {
            const raw_url = stringValue(media.get("media_url_https")) orelse stringValue(media.get("media_url")) orelse return error.XInvalidMetadata;
            const secure_url = try normalizedMediaScheme(allocator, config, raw_url);
            if (!validMediaUrl(config, secure_url, .photo)) return error.XMediaHostRejected;
            const photo_url = try photoOriginalUrl(allocator, secure_url);
            const dimensions = mediaDimensions(media);
            try items.append(allocator, .{
                .id = id,
                .ordinal = ordinal,
                .kind = .photo,
                .width = dimensions.width,
                .height = dimensions.height,
                .duration_ms = null,
                .thumbnail_url = photo_url,
                .photo_url = photo_url,
                .direct_variants = &.{},
            });
            continue;
        }
        const kind: job_mod.XMediaKind = if (std.mem.eql(u8, type_name, "video"))
            .video
        else if (std.mem.eql(u8, type_name, "animated_gif"))
            .animated_gif
        else
            return error.UnsupportedXShape;
        const video_info = objectField(media, "video_info") orelse return error.XInvalidMetadata;
        const variant_values = arrayField(video_info, "variants") orelse return error.XNoDirectVideo;
        var variants: std.ArrayList(DirectVariant) = .empty;
        defer variants.deinit(allocator);
        for (variant_values) |variant_value| {
            const variant = objectFromValue(variant_value) orelse continue;
            const content_type = stringValue(variant.get("content_type")) orelse "";
            if (!std.ascii.eqlIgnoreCase(content_type, "video/mp4")) continue;
            const raw_url = stringValue(variant.get("url")) orelse continue;
            const secure_url = try normalizedMediaScheme(allocator, config, raw_url);
            if (!validMediaUrl(config, secure_url, .video)) continue;
            var duplicate = false;
            for (variants.items) |existing| if (std.mem.eql(u8, existing.url, secure_url)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            const path_dimensions = dimensionsFromVideoUrl(secure_url);
            const normalized = DirectVariant{
                .url = secure_url,
                .width = numberU32(variant.get("width")) orelse path_dimensions.width,
                .height = numberU32(variant.get("height")) orelse path_dimensions.height,
                .bitrate = numberU64(variant.get("bitrate")) orelse numberU64(variant.get("bit_rate")),
            };
            var insert_at: usize = 0;
            while (insert_at < variants.items.len and !variantBetter(normalized, variants.items[insert_at])) : (insert_at += 1) {}
            try variants.insert(allocator, insert_at, normalized);
            if (variants.items.len > 8) return error.XInvalidMetadata;
        }
        if (variants.items.len == 0) return error.XNoDirectVideo;
        const direct_variants = try variants.toOwnedSlice(allocator);
        const item_dimensions = mediaDimensions(media);
        const raw_thumbnail = stringValue(media.get("media_url_https")) orelse stringValue(media.get("media_url"));
        const thumbnail = if (raw_thumbnail) |raw| blk: {
            const secure = try normalizedMediaScheme(allocator, config, raw);
            if (!validMediaUrl(config, secure, .photo)) break :blk null;
            break :blk try photoOriginalUrl(allocator, secure);
        } else null;
        try items.append(allocator, .{
            .id = id,
            .ordinal = ordinal,
            .kind = kind,
            .width = item_dimensions.width orelse direct_variants[0].width,
            .height = item_dimensions.height orelse direct_variants[0].height,
            .duration_ms = numberU64(video_info.get("duration_millis")),
            .thumbnail_url = thumbnail,
            .photo_url = null,
            .direct_variants = direct_variants,
        });
    }
    if (items.items.len == 0) return error.XNoMedia;
    return items.toOwnedSlice(allocator);
}

fn probeFromResolved(allocator: std.mem.Allocator, config: *const Config, resolved: ResolvedPost, resolved_at: i64) !job_mod.Probe {
    const plan_items = try allocator.alloc(job_mod.XPlanItem, resolved.items.len);
    var video_count: u8 = 0;
    var image_count: u8 = 0;
    var duration_ms: ?u64 = null;
    var thumbnail_url: ?[]const u8 = null;
    for (resolved.items, 0..) |item, index| {
        if (thumbnail_url == null) thumbnail_url = item.thumbnail_url;
        switch (item.kind) {
            .photo => image_count += 1,
            .video, .animated_gif => {
                video_count += 1;
                if (item.duration_ms) |duration| duration_ms = @max(duration_ms orelse 0, duration);
            },
        }
        const variants = try allocator.alloc(job_mod.XVideoVariant, item.direct_variants.len);
        for (item.direct_variants, 0..) |variant, variant_index| variants[variant_index] = .{
            .url = variant.url,
            .width = variant.width,
            .height = variant.height,
            .bitrate = variant.bitrate,
        };
        plan_items[index] = .{
            .id = item.id,
            .ordinal = item.ordinal,
            .kind = item.kind,
            .photo_url = item.photo_url,
            .thumbnail_url = item.thumbnail_url,
            .duration_ms = item.duration_ms,
            .width = item.width,
            .height = item.height,
            .video_variants = variants,
        };
    }
    const media_kind: job_mod.MediaKind = if (video_count > 0 and image_count > 0)
        .mixed
    else if (video_count > 0)
        .video
    else
        .image;
    const variants = try probeVariants(allocator, resolved.items, video_count, image_count);
    const single_video = if (video_count == 1 and image_count == 0) for (resolved.items) |item| {
        if (item.kind == .video or item.kind == .animated_gif) break item;
    } else null else null;
    const probe = job_mod.Probe{
        .engine = .x_native,
        .title = resolved.title,
        .source_host = "x.com",
        .media_kind = media_kind,
        .duration_seconds = if (duration_ms) |duration| (duration + 999) / 1000 else null,
        .thumbnail_url = thumbnail_url,
        .source_height = if (single_video) |item| item.height else null,
        .variants = variants,
        .audio_available = if (single_video) |item| item.kind == .video else false,
        .item_count = @intCast(resolved.items.len),
        .video_count = video_count,
        .image_count = image_count,
        .x_plan = .{
            .status_id = try allocator.dupe(u8, resolved.status_id),
            .resolved_at = resolved_at,
            .items = plan_items,
        },
    };
    if (config.max_media_duration_seconds > 0 and probe.duration_seconds != null and probe.duration_seconds.? > config.max_media_duration_seconds) return error.MediaTooLong;
    try job_mod.validateProbe(probe);
    return probe;
}

fn probeVariants(allocator: std.mem.Allocator, items: []const ResolvedItem, video_count: u8, image_count: u8) ![]const job_mod.Variant {
    if (video_count == 0 or image_count > 0) return &.{};
    var variants: std.ArrayList(job_mod.Variant) = .empty;
    defer variants.deinit(allocator);
    const single = if (video_count == 1) for (items) |item| {
        if (item.kind == .video or item.kind == .animated_gif) break item;
    } else null else null;
    if (single) |item| {
        const best_height = item.direct_variants[0].height;
        try variants.append(allocator, .{
            .id = "best",
            .label = if (best_height) |height| try std.fmt.allocPrint(allocator, "Best · {d}p", .{height}) else "Best",
            .height = best_height,
        });
        for ([_]u32{ 1080, 720, 480 }) |ceiling| {
            const selected = for (item.direct_variants) |candidate| {
                if (candidate.height != null and candidate.height.? <= ceiling) break candidate.height.?;
            } else continue;
            var duplicate = false;
            for (variants.items) |variant| if (variant.height == selected) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            try variants.append(allocator, .{
                .id = try std.fmt.allocPrint(allocator, "video-{d}", .{selected}),
                .label = try std.fmt.allocPrint(allocator, "{d}p", .{selected}),
                .height = selected,
            });
        }
    } else {
        try variants.append(allocator, .{ .id = "best", .label = "Best available for each video" });
    }
    return variants.toOwnedSlice(allocator);
}

const Dimensions = struct { width: ?u32 = null, height: ?u32 = null };

fn mediaDimensions(media: std.json.ObjectMap) Dimensions {
    if (objectField(media, "original_info")) |original| return .{ .width = numberU32(original.get("width")), .height = numberU32(original.get("height")) };
    if (objectField(media, "sizes")) |sizes| {
        if (objectField(sizes, "orig") orelse objectField(sizes, "large")) |size| return .{
            .width = numberU32(size.get("w")) orelse numberU32(size.get("width")),
            .height = numberU32(size.get("h")) orelse numberU32(size.get("height")),
        };
    }
    return .{};
}

fn dimensionsFromVideoUrl(raw_url: []const u8) Dimensions {
    const end = std.mem.indexOfAny(u8, raw_url, "?#") orelse raw_url.len;
    var parts = std.mem.splitScalar(u8, raw_url[0..end], '/');
    while (parts.next()) |part| {
        const separator = std.mem.indexOfScalar(u8, part, 'x') orelse continue;
        const width = std.fmt.parseInt(u32, part[0..separator], 10) catch continue;
        const height = std.fmt.parseInt(u32, part[separator + 1 ..], 10) catch continue;
        if (width > 0 and height > 0) return .{ .width = width, .height = height };
    }
    return .{};
}

fn variantBetter(left: DirectVariant, right: DirectVariant) bool {
    if ((left.height != null) != (right.height != null)) return left.height != null;
    if (left.height != right.height) return (left.height orelse 0) > (right.height orelse 0);
    if ((left.width != null) != (right.width != null)) return left.width != null;
    if (left.width != right.width) return (left.width orelse 0) > (right.width orelse 0);
    if ((left.bitrate != null) != (right.bitrate != null)) return left.bitrate != null;
    if (left.bitrate != right.bitrate) return (left.bitrate orelse 0) > (right.bitrate orelse 0);
    return false;
}

fn mediaId(allocator: std.mem.Allocator, media: std.json.ObjectMap, status_id: []const u8, ordinal: u8) ![]const u8 {
    if (stringValue(media.get("id_str")) orelse stringValue(media.get("id"))) |value| {
        if (validMediaId(value)) return allocator.dupe(u8, value);
    }
    if (media.get("id")) |value| switch (value) {
        .integer => |number| if (number >= 0) return std.fmt.allocPrint(allocator, "{d}", .{number}),
        else => {},
    };
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ status_id, ordinal });
}

fn validMediaId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

const MediaUrlKind = enum { photo, video };

fn normalizedMediaScheme(allocator: std.mem.Allocator, config: *const Config, raw_url: []const u8) ![]const u8 {
    if (std.ascii.startsWithIgnoreCase(raw_url, "https://")) return allocator.dupe(u8, raw_url);
    if (!std.ascii.startsWithIgnoreCase(raw_url, "http://")) return error.XMediaHostRejected;
    if (fixtureHttpAllowed(config)) return allocator.dupe(u8, raw_url);
    return std.fmt.allocPrint(allocator, "https://{s}", .{raw_url["http://".len..]});
}

fn validMediaUrl(config: *const Config, raw_url: []const u8, kind: MediaUrlKind) bool {
    if (raw_url.len == 0 or raw_url.len > 2048) return false;
    const uri = std.Uri.parse(raw_url) catch return false;
    const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if ((!secure and (!fixtureHttpAllowed(config) or !std.ascii.eqlIgnoreCase(uri.scheme, "http"))) or uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) return false;
    var host_buffer: [512]u8 = undefined;
    const host = uri.host.?.toRaw(&host_buffer) catch return false;
    if (!secure and !loopbackHost(host)) return false;
    return hostAllowed(host, if (kind == .photo) config.x_photo_media_hosts else config.x_video_media_hosts);
}

fn fixtureHttpAllowed(config: *const Config) bool {
    return loopbackHttpEndpoint(config.x_guest_endpoint) and loopbackHttpEndpoint(config.x_graphql_endpoint) and loopbackHttpEndpoint(config.x_syndication_endpoint);
}

fn loopbackHttpEndpoint(endpoint: []const u8) bool {
    const uri = std.Uri.parse(endpoint) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.host == null) return false;
    var host_buffer: [512]u8 = undefined;
    return loopbackHost(uri.host.?.toRaw(&host_buffer) catch return false);
}

fn loopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]");
}

fn hostAllowed(host: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| {
        if (std.ascii.eqlIgnoreCase(host, candidate)) return true;
        if (host.len > candidate.len and host[host.len - candidate.len - 1] == '.' and std.ascii.eqlIgnoreCase(host[host.len - candidate.len ..], candidate)) return true;
    }
    return false;
}

fn photoOriginalUrl(allocator: std.mem.Allocator, raw_url: []const u8) ![]const u8 {
    const query_start = std.mem.indexOfScalar(u8, raw_url, '?');
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, if (query_start) |start| raw_url[0..start] else raw_url);
    var wrote_query = false;
    if (query_start) |start| {
        var parameters = std.mem.splitScalar(u8, raw_url[start + 1 ..], '&');
        while (parameters.next()) |parameter| {
            if (parameter.len == 0) continue;
            const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse parameter.len;
            if (std.ascii.eqlIgnoreCase(parameter[0..equals], "name")) continue;
            try output.append(allocator, if (wrote_query) '&' else '?');
            try output.appendSlice(allocator, parameter);
            wrote_query = true;
        }
    }
    try output.append(allocator, if (wrote_query) '&' else '?');
    try output.appendSlice(allocator, "name=orig");
    if (output.items.len > 2048) return error.XInvalidMetadata;
    return output.toOwnedSlice(allocator);
}

fn cleanTitle(allocator: std.mem.Allocator, user_name: ?[]const u8, text: ?[]const u8, fallback: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    if (user_name) |value| try appendTitleWords(allocator, &output, value, false);
    if (text) |value| try appendTitleWords(allocator, &output, value, output.items.len > 0);
    if (output.items.len == 0) return allocator.dupe(u8, fallback);
    return output.toOwnedSlice(allocator);
}

fn appendTitleWords(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8, separated: bool) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.XInvalidMetadata;
    var wrote = false;
    var words = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (words.next()) |word| {
        if (std.ascii.startsWithIgnoreCase(word, "https://t.co/") or std.ascii.startsWithIgnoreCase(word, "http://t.co/")) continue;
        const joiner = if (!wrote and separated) " - " else if (wrote) " " else "";
        if (output.items.len + joiner.len >= 1024) break;
        const prefix = utf8Prefix(word, 1024 - output.items.len - joiner.len);
        if (prefix.len == 0) break;
        try output.appendSlice(allocator, joiner);
        try output.appendSlice(allocator, prefix);
        wrote = true;
    }
}

fn utf8Prefix(value: []const u8, maximum: usize) []const u8 {
    var end = @min(value.len, maximum);
    while (end > 0 and !std.unicode.utf8ValidateSlice(value[0..end])) end -= 1;
    return value[0..end];
}

fn objectFromValue(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return objectFromValue(value);
}

fn arrayField(object: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .array => |array| array.items,
        else => null,
    };
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn numberU64(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .float => |number| if (std.math.isFinite(number) and number >= 0 and number <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) @intFromFloat(@round(number)) else null,
        .number_string, .string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn numberU32(value: ?std.json.Value) ?u32 {
    const number = numberU64(value) orelse return null;
    if (number > std.math.maxInt(u32)) return null;
    return @intCast(number);
}

test "recognizes bounded X status URLs and ignores selectors" {
    try std.testing.expectEqualStrings("123", (try parseStatusUrl("https://x.com/user/status/123")).status_id);
    try std.testing.expectEqualStrings("123", (try parseStatusUrl("https://twitter.com/user/status/123?x=1#fragment")).status_id);
    try std.testing.expectEqual(@as(?u8, 2), (try parseStatusUrl("https://mobile.twitter.com/user/status/123/video/2")).requested_media_index);
    try std.testing.expectEqualStrings("123", (try parseStatusUrl("https://x.com/i/status/123/photo/1")).status_id);
    try std.testing.expectEqualStrings("123", (try parseStatusUrl("https://www.x.com/i/status/123")).status_id);
    try std.testing.expectEqualStrings("123", (try parseStatusUrl("https://m.twitter.com/i/status/123")).status_id);
    try std.testing.expectError(error.InvalidXUrl, parseStatusUrl("https://x.com/user/status/text"));
    try std.testing.expectError(error.InvalidXUrl, parseStatusUrl("https://x.com/user/status/"));
    try std.testing.expectError(error.InvalidXUrl, parseStatusUrl("https://example.com/user/status/123"));
    try std.testing.expectError(error.InvalidUrl, parseStatusUrl("https://user:secret@x.com/user/status/123"));
    try std.testing.expectError(error.PrivateAddress, parseStatusUrl("http://127.0.0.1/user/status/123"));
    try std.testing.expectError(error.InvalidXUrl, parseStatusUrl("https://x.com/user/status/1234567890123456789012345"));
    try std.testing.expectError(error.InvalidXUrl, parseStatusUrl("https://x.com/user/status/123/video/0"));
    try std.testing.expectError(error.InvalidXUrl, parseStatusUrl("https://x.com/user/status/123/video/2//"));
    try std.testing.expectError(error.InvalidXUrl, parseStatusUrl("https://x.com/user/status/123/status/456"));
}

test "query encoding uses RFC 3986 bytes" {
    const allocator = std.testing.allocator;
    const encoded = try percentEncode(allocator, "a b+/{🙂}");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("a%20b%2B%2F%7B%F0%9F%99%82%7D", encoded);
}

test "syndication tokens reproduce JavaScript base 36" {
    const vectors = [_]struct { id: []const u8, token: []const u8 }{
        .{ .id = "2041707173428748594", .token = "4y67n31yk3a" },
        .{ .id = "1790637656616943991", .token = "4c9gcitu1vq" },
        .{ .id = "2001950365332455490", .token = "4upb92tr14x" },
        .{ .id = "1600649710662213632", .token = "3vol7tqmapv" },
        .{ .id = "1234567890123456789", .token = "2zqic77uqyk" },
    };
    for (vectors) |vector| {
        const actual = try syndicationToken(std.testing.allocator, vector.id);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(vector.token, actual);
    }
}

test "guest token cache copies values and invalidates exactly" {
    var cache = GuestTokenCache{};
    try std.testing.expect(cache.storeIfEmpty("guest-1"));
    try std.testing.expect(!cache.storeIfEmpty("guest-2"));
    const token = cache.get().?;
    try std.testing.expectEqualStrings("guest-1", token.slice());
    try std.testing.expect(!cache.invalidateIfEqual("guest-2"));
    try std.testing.expect(cache.invalidateIfEqual("guest-1"));
    try std.testing.expect(cache.get() == null);
}

test "unavailable reasons fail closed when provider semantics are unknown" {
    try std.testing.expect(unavailableReason("Protected") == error.XPostPrivate);
    try std.testing.expect(unavailableReason("NsfwLoggedOut") == error.XLoginRequired);
    try std.testing.expect(unavailableReason("Deleted") == error.XPostUnavailable);
    try std.testing.expect(unavailableReason("NewReason") == error.XProviderChanged);
    try std.testing.expect(unavailableReason(null) == error.XProviderChanged);
}

test "plain HTTP media is restricted to loopback fixture configuration" {
    var fixture = Config{};
    fixture.x_guest_endpoint = "http://127.0.0.1:9000/guest";
    fixture.x_graphql_endpoint = "http://127.0.0.1:9000/graphql";
    fixture.x_syndication_endpoint = "http://127.0.0.1:9000/tweet-result";
    fixture.x_photo_media_hosts = &.{"127.0.0.1"};
    try std.testing.expect(validMediaUrl(&fixture, "http://127.0.0.1:9000/photo.jpg", .photo));
    try std.testing.expect(!validMediaUrl(&fixture, "http://example.com/photo.jpg", .photo));

    var remote = fixture;
    remote.x_graphql_endpoint = "http://example.com/graphql";
    try std.testing.expect(!validMediaUrl(&remote, "http://127.0.0.1:9000/photo.jpg", .photo));
}

test "GraphQL normalization preserves mixed media order and direct quality" {
    const payload =
        \\{"data":{"tweetResult":{"result":{"__typename":"Tweet","core":{"user_results":{"result":{"legacy":{"name":"Fixture User"}}}},"legacy":{"full_text":"Mixed post\nhttps://t.co/hidden","extended_entities":{"media":[{"id_str":"photo-1","type":"photo","media_url_https":"https://pbs.twimg.com/media/photo.jpg?format=jpg&name=small","original_info":{"width":2048,"height":1365}},{"id_str":"video-2","type":"video","media_url_https":"https://pbs.twimg.com/ext_tw_video_thumb/thumb.jpg?name=small","video_info":{"duration_millis":4200,"variants":[{"content_type":"application/x-mpegURL","url":"https://video.twimg.com/ext_tw_video/master.m3u8"},{"content_type":"video/mp4","bitrate":256000,"url":"https://video.twimg.com/ext_tw_video/640x360/low.mp4"},{"content_type":"video/mp4","bitrate":8320000,"url":"https://video.twimg.com/ext_tw_video/1920x1080/high.mp4"}]}}]}}}}}}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const probe = try normalizeGraphql(arena_state.allocator(), &Config{}, "2041707173428748594", payload, 1_800_000_000);
    try std.testing.expectEqual(job_mod.MediaKind.mixed, probe.media_kind);
    try std.testing.expectEqual(@as(u8, 2), probe.item_count);
    try std.testing.expectEqual(job_mod.XMediaKind.photo, probe.x_plan.?.items[0].kind);
    try std.testing.expectEqual(job_mod.XMediaKind.video, probe.x_plan.?.items[1].kind);
    try std.testing.expectEqualStrings("https://pbs.twimg.com/media/photo.jpg?format=jpg&name=orig", probe.x_plan.?.items[0].photo_url.?);
    try std.testing.expectEqual(@as(?u32, 1080), probe.x_plan.?.items[1].video_variants[0].height);
    try std.testing.expectEqual(@as(?u64, 8_320_000), probe.x_plan.?.items[1].video_variants[0].bitrate);
    try std.testing.expectEqualStrings("Fixture User - Mixed post", probe.title);
}

test "GraphQL visibility, repost, and one-level quote rules are explicit" {
    const visibility =
        \\{"data":{"tweetResult":{"result":{"__typename":"TweetWithVisibilityResults","tweet":{"__typename":"Tweet","legacy":{"full_text":"Visible","extended_entities":{"media":[{"type":"video","video_info":{"variants":[{"content_type":"video/mp4","url":"https://video.twimg.com/a/1280x720/a.mp4","bitrate":1000}]}}]}}}}}}}
    ;
    const repost =
        \\{"data":{"tweetResult":{"result":{"__typename":"Tweet","legacy":{"full_text":"wrapper","retweeted_status_result":{"result":{"__typename":"Tweet","legacy":{"full_text":"original","extended_entities":{"media":[{"type":"photo","media_url_https":"https://pbs.twimg.com/media/original.jpg"}]}}}}}}}}}
    ;
    const quote =
        \\{"data":{"tweetResult":{"result":{"__typename":"Tweet","legacy":{"full_text":"target"},"quoted_status_result":{"result":{"__typename":"Tweet","legacy":{"full_text":"quoted","extended_entities":{"media":[{"type":"photo","media_url_https":"https://pbs.twimg.com/media/quoted.jpg"}]}}}}}}}}
    ;
    inline for (.{ visibility, repost, quote }) |payload| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const probe = try normalizeGraphql(arena_state.allocator(), &Config{}, "2041707173428748594", payload, 1_800_000_000);
        try std.testing.expectEqual(@as(u8, 1), probe.item_count);
    }
}

test "GraphQL unavailable and unknown shapes have stable classes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    try std.testing.expectError(error.XPostPrivate, normalizeGraphql(allocator, &Config{}, "1", "{\"data\":{\"tweetResult\":{\"result\":{\"__typename\":\"TweetUnavailable\",\"reason\":\"Protected\"}}}}", 1_800_000_000));
    try std.testing.expectError(error.XLoginRequired, normalizeGraphql(allocator, &Config{}, "1", "{\"data\":{\"tweetResult\":{\"result\":{\"__typename\":\"TweetUnavailable\",\"reason\":\"NsfwLoggedOut\"}}}}", 1_800_000_000));
    try std.testing.expectError(error.XProviderChanged, normalizeGraphql(allocator, &Config{}, "1", "{\"data\":{\"tweetResult\":{\"result\":{\"__typename\":\"FutureTweet\"}}}}", 1_800_000_000));
}

test "photo queries, dimensions, and stable video scoring are bounded" {
    const allocator = std.testing.allocator;
    const photo = try photoOriginalUrl(allocator, "https://pbs.twimg.com/media/a.jpg?name=small&format=jpg&name=large");
    defer allocator.free(photo);
    try std.testing.expectEqualStrings("https://pbs.twimg.com/media/a.jpg?format=jpg&name=orig", photo);
    const dimensions = dimensionsFromVideoUrl("https://video.twimg.com/ext/1920x1080/file.mp4?tag=1");
    try std.testing.expectEqual(@as(?u32, 1920), dimensions.width);
    try std.testing.expectEqual(@as(?u32, 1080), dimensions.height);
    try std.testing.expect(variantBetter(.{ .url = "a", .height = 1080, .width = 1920, .bitrate = 1 }, .{ .url = "b", .height = 720, .width = 1280, .bitrate = 9_000_000 }));
    try std.testing.expect(!variantBetter(.{ .url = "a", .height = 720, .width = 1280, .bitrate = 1 }, .{ .url = "b", .height = 720, .width = 1280, .bitrate = 1 }));
}

test "source height ceilings never select a larger direct variant" {
    const variants = [_]job_mod.XVideoVariant{
        .{ .url = "high", .height = 1080 },
        .{ .url = "medium", .height = 720 },
        .{ .url = "low", .height = 360 },
    };
    try std.testing.expectEqualStrings("high", (try selectVideoVariant(&variants, "best")).url);
    try std.testing.expectEqualStrings("medium", (try selectVideoVariant(&variants, "video-720")).url);
    try std.testing.expectEqualStrings("low", (try selectVideoVariant(&variants, "video-719")).url);
    try std.testing.expectError(error.VariantUnavailable, selectVideoVariant(&variants, "video-240"));
}

test "media type and magic validation fail closed" {
    const mp4 = "\x00\x00\x00\x18ftypisomfixture";
    try std.testing.expect(hasFtypBox(mp4));
    try std.testing.expect(!hasFtypBox("junkftypisom"));
    try std.testing.expect(validMediaMagic(.photo, .{ .mime_type = "image/png", .extension = "png" }, "\x89PNG\r\n\x1a\nfixture"));
    try std.testing.expect(!validMediaMagic(.photo, .{ .mime_type = "image/jpeg", .extension = "jpg" }, "not-jpeg"));
    try std.testing.expectError(error.XInvalidMediaOutput, responseMediaType(.video, "text/html"));
    try std.testing.expectError(error.XInvalidMediaOutput, responseMediaType(.photo, null));
}

test "media redirects resolve without retaining credentials or fragments" {
    const allocator = std.testing.allocator;
    const resolved = try resolveRedirect(allocator, "https://video.twimg.com/a/b/file.mp4", "../next.mp4?tag=1");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("https://video.twimg.com/a/next.mp4?tag=1", resolved);
    try std.testing.expectError(error.InvalidRedirect, resolveRedirect(allocator, "https://video.twimg.com/file.mp4", "https://user:secret@video.twimg.com/file.mp4\n"));
}
