//! Public, logged-out Instagram posts. Resolve the complete collection before
//! selecting one child. Never substitute a video's poster for its video.
const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Config;
const job = @import("job.zig");
const plan_mod = @import("instagram_plan.zig");
const ffmpeg = @import("ffmpeg.zig");
const media_url = @import("url.zig");

const maximum_metadata = 4 * 1024 * 1024;
pub const maximum_thumbnail = 256 * 1024;
const agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
// Reviewed with Instaloader's shortcode web_info query. This is an internal
// provider contract, not a stable Meta API. Keep provenance in docs/instagram.
const document_id = "27128499623469141";
const web_app_id = "936619743392459";

pub const Shared = struct {
    busy: std.atomic.Value(bool) = .init(false),
    cooldown_until: std.atomic.Value(i64) = .init(0),
};
pub const Client = struct {
    io: std.Io,
    config: *const Config,
    http: std.http.Client,
    shared: *Shared,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: *const Config, shared: *Shared) Client {
        return .{ .io = io, .config = config, .http = .{ .allocator = allocator, .io = io }, .shared = shared };
    }
    pub fn deinit(client: *Client) void {
        client.http.deinit();
    }
};

pub const ParsedUrl = struct {
    shortcode: []const u8,
    route: []const u8,
    highlighted_ordinal: ?u8 = null,
    shared_link: bool = false,
};

pub fn matches(raw: []const u8) bool {
    _ = parseUrl(raw) catch return false;
    return true;
}

pub fn parseUrl(raw: []const u8) !ParsedUrl {
    var host_buffer: [512]u8 = undefined;
    const parsed = media_url.validate(raw, &host_buffer) catch return error.InvalidInstagramUrl;
    if (!instagramHost(parsed.host)) return error.InvalidInstagramUrl;
    if (parsed.uri.port) |port| if (port != 443 and port != 80) return error.InvalidInstagramUrl;
    const end = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
    const authority = (std.mem.indexOf(u8, raw[0..end], "://") orelse return error.InvalidInstagramUrl) + 3;
    const path_start = std.mem.indexOfScalarPos(u8, raw[0..end], authority, '/') orelse return error.InvalidInstagramUrl;
    const path = std.mem.trim(u8, raw[path_start..end], "/");
    var components = std.mem.splitScalar(u8, path, '/');
    const route = components.next() orelse return error.InvalidInstagramUrl;
    const code = components.next() orelse return error.InvalidInstagramUrl;
    if (components.next() != null or !plan_mod.validId(code)) return error.InvalidInstagramUrl;
    if (!std.mem.eql(u8, route, "p") and !std.mem.eql(u8, route, "reel") and !std.mem.eql(u8, route, "reels") and !std.mem.eql(u8, route, "tv") and !std.mem.eql(u8, route, "share")) return error.InvalidInstagramUrl;
    var highlighted: ?u8 = null;
    if (end < raw.len and raw[end] == '?') {
        const query_end = std.mem.indexOfScalarPos(u8, raw, end + 1, '#') orelse raw.len;
        var query = std.mem.splitScalar(u8, raw[end + 1 .. query_end], '&');
        while (query.next()) |part| if (std.mem.startsWith(u8, part, "img_index=")) {
            const value = std.fmt.parseInt(u8, part[10..], 10) catch continue;
            if (value > 0 and value <= plan_mod.maximum_items) highlighted = value;
        };
    }
    return .{ .shortcode = code, .route = route, .highlighted_ordinal = highlighted, .shared_link = std.mem.eql(u8, route, "share") };
}

fn instagramHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "instagram.com") or std.ascii.eqlIgnoreCase(host, "www.instagram.com") or std.ascii.eqlIgnoreCase(host, "m.instagram.com");
}

pub fn validOrigin(value: []const u8) bool {
    const uri = std.Uri.parse(value) catch return false;
    if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return false;
    var buffer: [512]u8 = undefined;
    const host = uri.host.?.toRaw(&buffer) catch return false;
    var path_buffer: [512]u8 = undefined;
    const path = uri.path.toRaw(&path_buffer) catch return false;
    if (path.len > 0 and !std.mem.eql(u8, path, "/")) return false;
    return (std.ascii.eqlIgnoreCase(uri.scheme, "https") and instagramHost(host)) or
        (std.ascii.eqlIgnoreCase(uri.scheme, "http") and loopbackHost(host));
}

fn loopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]") or std.mem.eql(u8, host, "::1");
}

fn hostSuffix(host: []const u8, suffix: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, suffix) or (host.len > suffix.len and host[host.len - suffix.len - 1] == '.' and std.ascii.endsWithIgnoreCase(host, suffix));
}

pub fn allowedUrl(config: *const Config, raw: []const u8, metadata: bool) bool {
    if (raw.len == 0 or raw.len > plan_mod.maximum_url_bytes or std.mem.indexOfAny(u8, raw, "\r\n\x00") != null) return false;
    const uri = std.Uri.parse(raw) catch return false;
    if (uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) return false;
    var buffer: [512]u8 = undefined;
    const host = uri.host.?.toRaw(&buffer) catch return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https") and (uri.port == null or uri.port.? == 443)) {
        return if (metadata) instagramHost(host) else hostSuffix(host, "cdninstagram.com") or hostSuffix(host, "fbcdn.net");
    }
    // An explicitly configured loopback origin is a deterministic test boundary,
    // never a wildcard arbitrary-URL proxy. Production defaults cannot use it.
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or !loopbackHost(host)) return false;
    const fixture = std.Uri.parse(config.instagram_origin) catch return false;
    if (!std.ascii.eqlIgnoreCase(fixture.scheme, "http") or fixture.host == null) return false;
    var other: [512]u8 = undefined;
    return std.mem.eql(u8, host, fixture.host.?.toRaw(&other) catch return false) and uri.port == fixture.port;
}

pub fn probe(allocator: std.mem.Allocator, client: *Client, raw: []const u8, cancel: ?*const std.atomic.Value(bool)) !job.Probe {
    var parsed = try parseUrl(raw);
    try checkCancelled(cancel);
    if (client.shared.cooldown_until.load(.acquire) > std.Io.Clock.real.now(client.io).toSeconds()) return error.InstagramRateLimited;
    if (client.shared.busy.swap(true, .acq_rel)) return error.InstagramBusy;
    defer client.shared.busy.store(false, .release);

    var page_url: []const u8 = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/", .{ client.config.instagram_origin, parsed.route, parsed.shortcode });
    var page: Response = undefined;
    for (0..4) |_| {
        page = try fetch(client, allocator, page_url, .GET, null, &.{}, maximum_metadata, cancel);
        if (page.status >= 300 and page.status < 400) {
            page_url = try redirectUrl(allocator, client.config, page_url, page.location orelse return error.InstagramUnavailable, true);
            try rejectAccessRedirect(page_url);
            continue;
        }
        try checkStatus(page.status);
        break;
    } else return error.InstagramTooManyRedirects;
    if (parsed.shared_link) {
        // Only an actual Instagram-owned redirect establishes the target post.
        var host_buffer: [512]u8 = undefined;
        const uri = try std.Uri.parse(page_url);
        const path = try uri.path.toRaw(&host_buffer);
        const canonical = try std.fmt.allocPrint(allocator, "https://www.instagram.com{s}", .{path});
        parsed = try parseUrl(canonical);
        if (parsed.shared_link) return error.InstagramUnsupported;
    }
    const now_value = std.Io.Clock.real.now(client.io).toSeconds();
    if (try parsePage(allocator, client.config, parsed.shortcode, page.body, now_value, parsed.highlighted_ordinal)) |result| return result;

    const csrf = page.csrf orelse tokenAfter(page.body, "\"csrf_token\":\"") orelse "";
    const lsd = tokenAfter(page.body, "[\"LSD\",[],{\"token\":\"") orelse "";
    const variables = try std.fmt.allocPrint(allocator, "{{\"shortcode\":\"{s}\",\"__relay_internal__pv__PolarisAIGMMediaWebLabelEnabledrelayprovider\":false}}", .{parsed.shortcode});
    const body = try std.fmt.allocPrint(allocator, "doc_id={s}&server_timestamps=true&variables={s}&lsd={s}", .{ document_id, try percentEncode(allocator, variables), try percentEncode(allocator, lsd) });
    const cookie = try std.fmt.allocPrint(allocator, "csrftoken={s}", .{csrf});
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "x-ig-app-id", .value = web_app_id },
        .{ .name = "x-csrftoken", .value = csrf },
        .{ .name = "x-fb-lsd", .value = lsd },
        .{ .name = "referer", .value = page_url },
        .{ .name = "origin", .value = "https://www.instagram.com" },
        .{ .name = "cookie", .value = cookie },
    };
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/graphql/query", .{client.config.instagram_origin});
    const response = try fetch(client, allocator, endpoint, .POST, body, &headers, maximum_metadata, cancel);
    if (response.location) |location| try rejectAccessRedirect(location);
    try checkStatus(response.status);
    if (try parsePage(allocator, client.config, parsed.shortcode, response.body, now_value, parsed.highlighted_ordinal)) |result| return result;
    if (std.mem.indexOf(u8, response.body, "challenge_required") != null or std.mem.indexOf(u8, page.body, "challenge_required") != null) return error.InstagramChallengeRequired;
    if (std.mem.indexOf(u8, response.body, "login_required") != null) return error.InstagramLoginRequired;
    return error.InstagramMetadataIncomplete;
}

fn tokenAfter(body: []const u8, marker: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, body, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return null;
    const token = body[start..end];
    if (token.len == 0 or token.len > 256) return null;
    for (token) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return null;
    return token;
}

fn rejectAccessRedirect(url: []const u8) !void {
    if (std.mem.indexOf(u8, url, "/accounts/login") != null) return error.InstagramLoginRequired;
    if (std.mem.indexOf(u8, url, "/challenge/") != null or std.mem.indexOf(u8, url, "/checkpoint/") != null) return error.InstagramChallengeRequired;
}

fn checkStatus(status: u16) !void {
    return switch (status) {
        200 => {},
        401, 403 => error.InstagramLoginRequired,
        404, 410 => error.InstagramUnavailable,
        429 => error.InstagramRateLimited,
        else => error.InstagramUpstreamRejected,
    };
}

const Response = struct {
    status: u16,
    body: []const u8,
    location: ?[]const u8 = null,
    csrf: ?[]const u8 = null,
};

fn fetch(client: *Client, allocator: std.mem.Allocator, url: []const u8, method: std.http.Method, body: ?[]const u8, headers: []const std.http.Header, maximum: usize, cancel: ?*const std.atomic.Value(bool)) !Response {
    if (!allowedUrl(client.config, url, true)) return error.InstagramHostRejected;
    try checkCancelled(cancel);
    var request = try client.http.request(method, try std.Uri.parse(url), .{
        .keep_alive = true,
        .redirect_behavior = .not_allowed,
        .headers = .{ .user_agent = .{ .override = agent }, .accept_encoding = .omit },
        .extra_headers = headers,
    });
    defer request.deinit();
    errdefer request.connection.?.closing = true;
    try socketTimeout(request.connection.?, client.config.instagram_timeout_seconds);
    if (body) |bytes| try request.sendBodyComplete(try allocator.dupe(u8, bytes)) else try request.sendBodiless();
    var head_buffer: [16 * 1024]u8 = undefined;
    var response = try request.receiveHead(&head_buffer);
    const status: u16 = @backingInt(response.head.status);
    var result = Response{ .status = status, .body = "" };
    if (response.head.location) |location| result.location = try allocator.dupe(u8, location);
    var iterator = response.head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "set-cookie") and std.mem.startsWith(u8, header.value, "csrftoken=")) {
            const token_end = std.mem.indexOfScalar(u8, header.value, ';') orelse header.value.len;
            const token = header.value[10..token_end];
            if (token.len <= 256 and std.mem.indexOfAny(u8, token, "\r\n\x00") == null) result.csrf = try allocator.dupe(u8, token);
        }
        if (status == 429 and std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            const seconds = std.fmt.parseInt(u32, header.value, 10) catch 60;
            client.shared.cooldown_until.store(std.Io.Clock.real.now(client.io).toSeconds() + @as(i64, @intCast(@min(@max(seconds, 1), 600))), .release);
        }
    }
    if (status == 429 and client.shared.cooldown_until.load(.acquire) <= std.Io.Clock.real.now(client.io).toSeconds()) client.shared.cooldown_until.store(std.Io.Clock.real.now(client.io).toSeconds() + 60, .release);
    if (response.head.content_length) |length| if (length > maximum) return error.InstagramResponseTooLarge;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const body_started = std.Io.Clock.Timestamp.now(client.io, .awake);
    var transfer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        try checkCancelled(cancel);
        if (body_started.untilNow(client.io).raw.toSeconds() >= client.config.instagram_timeout_seconds) return error.InstagramTransportFailed;
        const count = reader.readSliceShort(&buffer) catch return error.InstagramTransportFailed;
        if (count == 0) break;
        if (count > maximum - output.items.len) return error.InstagramResponseTooLarge;
        try output.appendSlice(allocator, buffer[0..count]);
    }
    if (response.head.content_length) |length| if (length != output.items.len) return error.InstagramTransportFailed;
    result.body = try output.toOwnedSlice(allocator);
    return result;
}

const Search = struct {
    best: ?job.Probe = null,
    required_count: usize = 0,
};

fn preferProbe(search: *Search, candidate: job.Probe) void {
    if (search.best == null or candidate.item_count > search.best.?.item_count) search.best = candidate;
}

fn completeSearch(search: Search) ?job.Probe {
    const best = search.best orelse return null;
    return if (best.item_count >= search.required_count) best else null;
}

fn parsePage(allocator: std.mem.Allocator, config: *const Config, shortcode: []const u8, bytes: []const u8, now_value: i64, hint: ?u8) !?job.Probe {
    if (bytes.len > maximum_metadata) return error.InstagramResponseTooLarge;
    var trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "for (;;);")) trimmed = std.mem.trimStart(u8, trimmed[9..], " \t\r\n");
    if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) return completeSearch(try parseJsonPost(allocator, config, shortcode, trimmed, now_value, hint));
    var search = Search{};
    var position: usize = 0;
    var scripts: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, position, "<script")) |start| {
        scripts += 1;
        if (scripts > 512) return error.InstagramResponseTooLarge;
        const content_start = (std.mem.indexOfScalarPos(u8, bytes, start, '>') orelse break) + 1;
        const content_end = std.mem.indexOfPos(u8, bytes, content_start, "</script>") orelse break;
        position = content_end + 9;
        const content = std.mem.trim(u8, bytes[content_start..content_end], " \t\r\n");
        if (content.len == 0 or (content[0] != '{' and content[0] != '[')) continue;
        const candidate = try parseJsonPost(allocator, config, shortcode, content, now_value, hint);
        search.required_count = @max(search.required_count, candidate.required_count);
        if (candidate.best) |post| preferProbe(&search, post);
    }
    return completeSearch(search);
}

fn parseJsonPost(allocator: std.mem.Allocator, config: *const Config, shortcode: []const u8, bytes: []const u8, now_value: i64, hint: ?u8) !Search {
    // Pages can contain a cover, an incomplete hydration stub and the complete
    // carousel in different objects/scripts. A first-match parser is unsafe.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{ .max_value_len = maximum_metadata }) catch return .{};
    var remaining: usize = 100_000;
    var search = Search{};
    try findPost(arena.allocator(), config, parsed, shortcode, now_value, hint, 0, &remaining, &search);
    if (search.best) |best| search.best = try job.cloneProbe(allocator, best);
    return search;
}

fn findPost(allocator: std.mem.Allocator, config: *const Config, value: std.json.Value, shortcode: []const u8, now_value: i64, hint: ?u8, depth: usize, remaining: *usize, search: *Search) anyerror!void {
    if (depth > 64 or remaining.* == 0) return error.InstagramResponseTooLarge;
    remaining.* -= 1;
    switch (value) {
        .object => |object| {
            const code = text(object.get("code")) orelse text(object.get("shortcode"));
            if (code) |candidate| if (std.mem.eql(u8, candidate, shortcode) and (object.contains("media_type") or object.contains("__typename") or object.contains("carousel_media") or object.contains("video_versions") or object.contains("image_versions2"))) {
                const carousel = number(object.get("media_type")) == 8 or equal(text(object.get("__typename")), "GraphSidecar") or equal(text(object.get("product_type")), "carousel_container") or object.contains("carousel_media") or object.contains("edge_sidecar_to_children");
                const count = number(object.get("carousel_media_count")) orelse if (carousel) @as(u64, 2) else 1;
                if (count > plan_mod.maximum_items) return error.InstagramTooManyItems;
                search.required_count = @max(search.required_count, @as(usize, @intCast(count)));
                const normalized: ?job.Probe = normalize(allocator, config, shortcode, object, now_value, hint) catch |err| switch (err) {
                    error.InstagramMetadataIncomplete, error.InstagramNoMedia => null,
                    else => return err,
                };
                if (normalized) |probe_result| preferProbe(search, probe_result);
            };
            var iterator = object.iterator();
            while (iterator.next()) |entry| try findPost(allocator, config, entry.value_ptr.*, shortcode, now_value, hint, depth + 1, remaining, search);
        },
        .array => |entries| for (entries.items) |entry| {
            try findPost(allocator, config, entry, shortcode, now_value, hint, depth + 1, remaining, search);
        },
        else => {},
    }
}

fn normalize(allocator: std.mem.Allocator, config: *const Config, shortcode: []const u8, object: std.json.ObjectMap, now_value: i64, hint: ?u8) !job.Probe {
    const is_carousel = number(object.get("media_type")) == 8 or equal(text(object.get("__typename")), "GraphSidecar") or equal(text(object.get("product_type")), "carousel_container") or object.contains("carousel_media") or object.contains("edge_sidecar_to_children");
    var nodes: []const std.json.Value = &.{};
    var edges = false;
    var single = [_]std.json.Value{.{ .object = object }};
    if (is_carousel) {
        nodes = array(object.get("carousel_media")) orelse blk: {
            const sidecar = obj(object.get("edge_sidecar_to_children")) orelse return error.InstagramMetadataIncomplete;
            edges = true;
            break :blk array(sidecar.get("edges")) orelse return error.InstagramMetadataIncomplete;
        };
        const declared = number(object.get("carousel_media_count"));
        if (declared != null and declared.? != nodes.len) return error.InstagramMetadataIncomplete;
        if (nodes.len < 2) return error.InstagramMetadataIncomplete;
    } else {
        if ((number(object.get("carousel_media_count")) orelse 0) > 1) return error.InstagramMetadataIncomplete;
        nodes = &single;
    }
    if (nodes.len > plan_mod.maximum_items) return error.InstagramTooManyItems;
    const items = try allocator.alloc(plan_mod.Item, nodes.len);
    var image_count: u8 = 0;
    var video_count: u8 = 0;
    var available: usize = 0;
    for (nodes, 0..) |value, index| {
        const wrapper = obj(value) orelse return error.InstagramMetadataIncomplete;
        const node = if (edges) obj(wrapper.get("node")) orelse return error.InstagramMetadataIncomplete else wrapper;
        items[index] = try normalizeItem(allocator, config, node, @intCast(index + 1));
        switch (items[index].kind) {
            .image => image_count += 1,
            .video => video_count += 1,
            .unknown => {},
        }
        if (items[index].available()) available += 1;
    }
    if (available == 0) return error.InstagramNoMedia;
    const user = obj(object.get("user")) orelse obj(object.get("owner"));
    const username = if (user) |value| text(value.get("username")) else null;
    const safe_username = if (username) |value| if (value.len <= 64 and std.unicode.utf8ValidateSlice(value)) value else "Instagram" else "Instagram";
    const title = try std.fmt.allocPrint(allocator, "Post by {s}", .{safe_username});
    const plan = plan_mod.Plan{ .shortcode = try allocator.dupe(u8, shortcode), .resolved_at = now_value, .highlighted_ordinal = if (hint != null and hint.? <= items.len) hint else null, .items = items };
    try plan.validate();
    return .{
        .engine = .instagram_native,
        .source_host = "instagram.com",
        .title = title,
        .media_kind = if (video_count == items.len) .video else if (image_count == items.len) .image else .mixed,
        .item_count = @intCast(items.len),
        .video_count = video_count,
        .image_count = image_count,
        .duration_seconds = if (items.len == 1 and items[0].duration_ms != null) items[0].duration_ms.? / 1000 else null,
        .instagram_plan = plan,
    };
}

const Candidate = struct { url: []const u8, width: ?u32, height: ?u32 };
fn area(candidate: Candidate) u64 {
    return @as(u64, candidate.width orelse 0) * @as(u64, candidate.height orelse 0);
}
fn candidateFrom(value: std.json.Value, config: *const Config) ?Candidate {
    const object = obj(value) orelse return null;
    const url = text(object.get("url")) orelse text(object.get("src")) orelse return null;
    if (!allowedUrl(config, url, false)) return null;
    return .{ .url = url, .width = dimension(object.get("width")) orelse dimension(object.get("config_width")), .height = dimension(object.get("height")) orelse dimension(object.get("config_height")) };
}

fn normalizeItem(allocator: std.mem.Allocator, config: *const Config, object: std.json.ObjectMap, ordinal: u8) !plan_mod.Item {
    const numeric_kind = number(object.get("media_type"));
    const kind: plan_mod.Kind = if (numeric_kind == 2 or equal(text(object.get("__typename")), "GraphVideo") or truth(object.get("is_video"))) .video else if (numeric_kind == 1 or equal(text(object.get("__typename")), "GraphImage") or (object.get("is_video") != null and !truth(object.get("is_video")))) .image else .unknown;
    const raw_id = text(object.get("pk")) orelse text(object.get("id"));
    const id = if (raw_id) |value| if (plan_mod.validId(value)) try allocator.dupe(u8, value) else try std.fmt.allocPrint(allocator, "unavailable-{d}", .{ordinal}) else if (number(object.get("pk")) orelse number(object.get("id"))) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else try std.fmt.allocPrint(allocator, "unavailable-{d}", .{ordinal});
    const identified = !std.mem.startsWith(u8, id, "unavailable-");
    var image: ?Candidate = null;
    var preview_candidate: ?Candidate = null;
    const images = if (obj(object.get("image_versions2"))) |versions| array(versions.get("candidates")) else array(object.get("display_resources"));
    if (images) |values| {
        if (values.len > 64) return error.InstagramResponseTooLarge;
        for (values) |value| if (candidateFrom(value, config)) |candidate| {
            if (image == null or area(candidate) > area(image.?)) image = candidate;
            if (candidate.width != null and candidate.height != null and candidate.width.? <= 640 and candidate.height.? <= 640 and (preview_candidate == null or area(candidate) > area(preview_candidate.?))) preview_candidate = candidate;
        };
    }
    if (image == null) {
        if (text(object.get("display_url"))) |url| if (allowedUrl(config, url, false)) {
            const dimensions = obj(object.get("dimensions"));
            image = .{ .url = url, .width = if (dimensions) |value| dimension(value.get("width")) else null, .height = if (dimensions) |value| dimension(value.get("height")) else null };
        };
    }
    if (preview_candidate == null) {
        if (text(object.get("thumbnail_src"))) |url| {
            if (allowedUrl(config, url, false)) preview_candidate = .{ .url = url, .width = null, .height = null };
        }
    }
    var video: ?Candidate = null;
    if (array(object.get("video_versions"))) |versions| {
        if (versions.len > 64) return error.InstagramResponseTooLarge;
        for (versions) |value| if (candidateFrom(value, config)) |candidate| if (video == null or area(candidate) > area(video.?)) {
            video = candidate;
        };
    }
    if (video == null) {
        if (text(object.get("video_url"))) |url| if (allowedUrl(config, url, false)) {
            const dimensions = obj(object.get("dimensions"));
            video = .{ .url = url, .width = if (dimensions) |value| dimension(value.get("width")) else null, .height = if (dimensions) |value| dimension(value.get("height")) else null };
        };
    }
    const selected = switch (kind) {
        .image => image,
        .video => video,
        .unknown => null,
    };
    // Never request an unselected full-size photo as its own preview_candidate.
    if (kind == .image and preview_candidate != null and selected != null and std.mem.eql(u8, preview_candidate.?.url, selected.?.url)) preview_candidate = null;
    if (kind == .video and preview_candidate == null) preview_candidate = image;
    return .{
        .id = id,
        .ordinal = ordinal,
        .kind = kind,
        .url = if (identified and selected != null) try allocator.dupe(u8, selected.?.url) else null,
        .thumbnail_url = if (preview_candidate) |value| try allocator.dupe(u8, value.url) else null,
        .width = if (selected) |value| value.width else null,
        .height = if (selected) |value| value.height else null,
        .duration_ms = secondsToMs(object.get("video_duration")),
    };
}

pub const ProgressCallback = struct { context: *anyopaque, update: *const fn (*anyopaque, job.Progress) anyerror!void };
const Downloaded = struct { mime: []const u8, extension: []const u8, size: u64 };

pub fn acquire(allocator: std.mem.Allocator, scratch: std.mem.Allocator, client: *Client, environment: *const std.process.Environ.Map, root: []const u8, probe_result: job.Probe, selection: job.Selection, cancel: *const std.atomic.Value(bool), callback: ProgressCallback) !job.Acquisition {
    const original_plan = probe_result.instagram_plan orelse return error.InvalidInstagramPlan;
    const selected_id = selection.item_id orelse return error.InvalidSelection;
    const original = original_plan.find(selected_id) orelse return error.InvalidSelection;
    if (!original.available()) return error.InstagramItemUnavailable;
    const work = try std.fs.path.join(scratch, &.{ root, "work" });
    const sources = try std.fs.path.join(scratch, &.{ root, "source" });
    std.Io.Dir.cwd().deleteTree(client.io, work) catch {};
    try std.Io.Dir.cwd().createDirPath(client.io, work);
    try std.Io.Dir.cwd().createDirPath(client.io, sources);
    const temporary = try std.fs.path.join(scratch, &.{ work, "selected.part" });
    errdefer std.Io.Dir.cwd().deleteFile(client.io, temporary) catch {};
    var chosen = original;
    var downloaded: Downloaded = undefined;
    for (0..2) |attempt| {
        if (attempt == 1) {
            const canonical = try std.fmt.allocPrint(scratch, "https://www.instagram.com/p/{s}/", .{original_plan.shortcode});
            const refreshed = try probe(scratch, client, canonical, cancel);
            chosen = refreshed.instagram_plan.?.find(selected_id) orelse return error.InstagramItemUnavailable;
            if (chosen.kind != original.kind or !chosen.available()) return error.InstagramItemUnavailable;
        }
        downloaded = download(client, scratch, chosen.url.?, temporary, client.config.max_download_bytes, chosen.kind, cancel, callback) catch |err| {
            if (attempt == 0 and err == error.InstagramMediaExpired) continue;
            return err;
        };
        break;
    } else return error.InstagramMediaExpired;
    if (chosen.kind == .video) {
        const info = ffmpeg.inspectVideo(allocator, client.io, client.config, environment, root, temporary, cancel) catch |err| switch (err) {
            error.Cancelled, error.ToolMissing => return err,
            else => return error.InstagramInvalidMedia,
        };
        if (info.video_codec == null or (info.width orelse 0) == 0 or (info.height orelse 0) == 0) return error.InstagramInvalidMedia;
    }
    const stored = try std.fmt.allocPrint(scratch, "item-{d:0>3}.{s}", .{ original.ordinal, downloaded.extension });
    const final = try std.fs.path.join(scratch, &.{ sources, stored });
    try checkCancelled(cancel);
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), final, client.io);
    const artifacts = try allocator.alloc(job.Artifact, 1);
    artifacts[0] = .{
        .id = "file-1",
        .path = try std.fmt.allocPrint(allocator, "source/{s}", .{stored}),
        .filename = try std.fmt.allocPrint(allocator, "instagram-{s}-{d}.{s}", .{ original_plan.shortcode, original.ordinal, downloaded.extension }),
        .media_kind = if (chosen.kind == .video) .video else .image,
        .mime_type = downloaded.mime,
        .size_bytes = downloaded.size,
        .primary = true,
    };
    return .{ .artifacts = artifacts, .total_bytes = downloaded.size };
}

fn download(client: *Client, allocator: std.mem.Allocator, initial: []const u8, destination: []const u8, maximum: u64, kind: plan_mod.Kind, cancel: ?*const std.atomic.Value(bool), callback: ?ProgressCallback) !Downloaded {
    var url = initial;
    for (0..4) |_| {
        try checkCancelled(cancel);
        if (!allowedUrl(client.config, url, false)) return error.InstagramHostRejected;
        var request = try client.http.request(.GET, try std.Uri.parse(url), .{ .keep_alive = true, .redirect_behavior = .not_allowed, .headers = .{ .user_agent = .{ .override = agent }, .accept_encoding = .omit }, .extra_headers = &.{.{ .name = "referer", .value = "https://www.instagram.com/" }} });
        defer request.deinit();
        errdefer request.connection.?.closing = true;
        try socketTimeout(request.connection.?, client.config.instagram_timeout_seconds);
        try request.sendBodiless();
        var header_buffer: [16 * 1024]u8 = undefined;
        var response = try request.receiveHead(&header_buffer);
        const status: u16 = @backingInt(response.head.status);
        if (status >= 300 and status < 400) {
            url = try redirectUrl(allocator, client.config, url, response.head.location orelse return error.InstagramMediaExpired, false);
            request.connection.?.closing = true;
            continue;
        }
        if (status == 403 or status == 404 or status == 410) return error.InstagramMediaExpired;
        if (status != 200) return error.InstagramUpstreamRejected;
        if (response.head.content_length) |length| if (length == 0 or length > maximum) return error.DownloadTooLarge;
        // Response.reader invalidates all borrowed header strings in this Zig
        // revision. Copy the MIME before opening the body stream.
        const declared_mime: ?[]const u8 = if (response.head.content_type) |mime| blk: {
            if (mime.len > 255) return error.InstagramInvalidMedia;
            break :blk try allocator.dupe(u8, mime);
        } else null;
        const transfer_started = std.Io.Clock.Timestamp.now(client.io, .awake);
        const file = try std.Io.Dir.cwd().createFile(client.io, destination, .{ .exclusive = true, .permissions = @fromBackingInt(@intCast(0o600)) });
        defer file.close(client.io);
        errdefer std.Io.Dir.cwd().deleteFile(client.io, destination) catch {};
        var file_buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(client.io, &file_buffer);
        var transfer_buffer: [32 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var buffer: [64 * 1024]u8 = undefined;
        var prefix: [64]u8 = undefined;
        var prefix_length: usize = 0;
        var total: u64 = 0;
        var last_update = std.Io.Clock.Timestamp.now(client.io, .awake);
        while (true) {
            try checkCancelled(cancel);
            if (transfer_started.untilNow(client.io).raw.toSeconds() >= client.config.download_timeout_seconds) return error.DownloadTimedOut;
            const count = reader.readSliceShort(&buffer) catch return error.InstagramTransportFailed;
            if (count == 0) break;
            if (count > maximum - total) return error.DownloadTooLarge;
            if (prefix_length < prefix.len) {
                const take = @min(prefix.len - prefix_length, count);
                @memcpy(prefix[prefix_length .. prefix_length + take], buffer[0..take]);
                prefix_length += take;
            }
            try writer.interface.writeAll(buffer[0..count]);
            total += count;
            if (callback) |progress| if (last_update.untilNow(client.io).raw.toMilliseconds() >= 100) {
                try progress.update(progress.context, .{ .phase = .source_download, .label = "Downloading selected item", .bytes_downloaded = total, .bytes_total = response.head.content_length, .bytes_total_kind = if (response.head.content_length != null) .exact else null, .item_index = 1, .item_count = 1, .updated_at = std.Io.Clock.real.now(client.io).toSeconds() });
                last_update = std.Io.Clock.Timestamp.now(client.io, .awake);
            };
        }
        if (total == 0 or (response.head.content_length != null and response.head.content_length.? != total)) return error.InstagramInvalidMedia;
        var result = sniff(prefix[0..prefix_length], kind) orelse return error.InstagramInvalidMedia;
        if (declared_mime) |content_type| {
            const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
            const mime = content_type[0..end];
            if (!std.ascii.eqlIgnoreCase(mime, result.mime) and !std.ascii.eqlIgnoreCase(mime, "application/octet-stream")) return error.InstagramInvalidMedia;
        }
        try writer.flush();
        try file.sync(client.io);
        result.size = total;
        return result;
    }
    return error.InstagramTooManyRedirects;
}

pub const Thumbnail = struct { bytes: []const u8, mime: []const u8 };
pub fn thumbnail(allocator: std.mem.Allocator, client: *Client, root: []const u8, plan: plan_mod.Plan, id: []const u8) !Thumbnail {
    const item = plan.find(id) orelse return error.InstagramItemUnavailable;
    const url = item.thumbnail_url orelse return error.InstagramItemUnavailable;
    const directory = try std.fs.path.join(allocator, &.{ root, "preview" });
    try std.Io.Dir.cwd().createDirPath(client.io, directory);
    const filename = try std.fmt.allocPrint(allocator, "instagram-{d}.thumb", .{item.ordinal});
    const path = try std.fs.path.join(allocator, &.{ directory, filename });
    if (std.Io.Dir.cwd().readFileAlloc(client.io, path, allocator, .limited(maximum_thumbnail))) |bytes| {
        const info = sniff(bytes, .image) orelse return error.InstagramInvalidMedia;
        return .{ .bytes = bytes, .mime = info.mime };
    } else |err| if (err != error.FileNotFound) return err;
    // Cache at most the first 16 previews; remaining thumbnails are still bounded
    // per response and loaded only when the browser scrolls them into view.
    const temporary = try std.fmt.allocPrint(allocator, "{s}.part", .{path});
    const downloaded = try download(client, allocator, url, temporary, maximum_thumbnail, .image, null, null);
    defer std.Io.Dir.cwd().deleteFile(client.io, temporary) catch {};
    const bytes = try std.Io.Dir.cwd().readFileAlloc(client.io, temporary, allocator, .limited(maximum_thumbnail));
    if (item.ordinal <= 16) try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, client.io);
    return .{ .bytes = bytes, .mime = downloaded.mime };
}

fn sniff(bytes: []const u8, kind: plan_mod.Kind) ?Downloaded {
    if (kind == .video) {
        if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "ftyp")) return .{ .mime = "video/mp4", .extension = "mp4", .size = 0 };
        return null;
    }
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xff\xd8\xff")) return .{ .mime = "image/jpeg", .extension = "jpg", .size = 0 };
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .{ .mime = "image/png", .extension = "png", .size = 0 };
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF89a") or std.mem.eql(u8, bytes[0..6], "GIF87a"))) return .{ .mime = "image/gif", .extension = "gif", .size = 0 };
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .{ .mime = "image/webp", .extension = "webp", .size = 0 };
    return null;
}

fn redirectUrl(allocator: std.mem.Allocator, config: *const Config, previous: []const u8, location: []const u8, metadata: bool) ![]const u8 {
    const next = if (std.mem.startsWith(u8, location, "/") and !std.mem.startsWith(u8, location, "//")) blk: {
        const scheme_end = (std.mem.indexOf(u8, previous, "://") orelse return error.InstagramHostRejected) + 3;
        const authority_end = std.mem.indexOfScalarPos(u8, previous, scheme_end, '/') orelse previous.len;
        break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ previous[0..authority_end], location });
    } else try allocator.dupe(u8, location);
    if (!allowedUrl(config, next, metadata)) return error.InstagramHostRejected;
    return next;
}

fn socketTimeout(connection: *std.http.Client.Connection, seconds: u16) !void {
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        const timeout: std.posix.timeval = .{ .sec = seconds, .usec = 0 };
        const handle = connection.stream_reader.stream.socket.handle;
        try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
    }
}
fn checkCancelled(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel != null and cancel.?.load(.acquire)) return error.Cancelled;
}
fn obj(value: ?std.json.Value) ?std.json.ObjectMap {
    const present = value orelse return null;
    return if (present == .object) present.object else null;
}
fn array(value: ?std.json.Value) ?[]const std.json.Value {
    const present = value orelse return null;
    return if (present == .array) present.array.items else null;
}
fn text(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return if (present == .string) present.string else null;
}
fn number(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |v| if (v >= 0) @intCast(v) else null,
        .string, .number_string => |v| std.fmt.parseInt(u64, v, 10) catch null,
        else => null,
    };
}
fn dimension(value: ?std.json.Value) ?u32 {
    const v = number(value) orelse return null;
    return if (v > 0 and v <= 65535) @intCast(v) else null;
}
fn truth(value: ?std.json.Value) bool {
    const present = value orelse return false;
    return present == .bool and present.bool;
}
fn equal(value: ?[]const u8, other: []const u8) bool {
    return value != null and std.mem.eql(u8, value.?, other);
}
fn secondsToMs(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    const seconds: f64 = switch (present) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => return null,
    };
    return if (std.math.isFinite(seconds) and seconds >= 0 and seconds <= 86400) @intFromFloat(seconds * 1000) else null;
}
fn percentEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (bytes) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try output.append(allocator, byte) else try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 15] });
    }
    return output.toOwnedSlice(allocator);
}

pub fn failure(err: anyerror) ?struct { code: []const u8, message: []const u8 } {
    return switch (err) {
        error.InvalidInstagramUrl, error.InstagramUnsupported => .{ .code = "INSTAGRAM_UNSUPPORTED", .message = "Use a public Instagram post or Reel link. Stories and account-only content are not supported." },
        error.InstagramLoginRequired => .{ .code = "INSTAGRAM_LOGIN_REQUIRED", .message = "Instagram requires a signed-in session for this request. xvid does not borrow a personal account's access." },
        error.InstagramChallengeRequired => .{ .code = "INSTAGRAM_CHALLENGE", .message = "Instagram requested a browser challenge. This server cannot retrieve the post right now." },
        error.InstagramRateLimited, error.InstagramBusy => .{ .code = "INSTAGRAM_BUSY", .message = "Instagram link checks are temporarily busy or rate limited. Try again shortly." },
        error.InstagramUnavailable, error.InstagramItemUnavailable => .{ .code = "INSTAGRAM_UNAVAILABLE", .message = "This post or selected item is no longer available. Reload the post to choose again." },
        error.InstagramNoMedia, error.InstagramMetadataIncomplete => .{ .code = "INSTAGRAM_INCOMPLETE", .message = "Instagram did not expose the complete post. No cover image or different carousel item was substituted." },
        error.InstagramTooManyItems, error.InstagramResponseTooLarge => .{ .code = "INSTAGRAM_LIMIT", .message = "This Instagram response exceeds the bounded post or preview limits." },
        error.InstagramHostRejected => .{ .code = "INSTAGRAM_HOST_REJECTED", .message = "Instagram returned an unapproved media or redirect host." },
        error.InstagramInvalidMedia => .{ .code = "INSTAGRAM_INVALID_MEDIA", .message = "The selected file was not a valid image or playable video." },
        error.InstagramMediaExpired, error.InstagramUpstreamRejected, error.InstagramTransportFailed, error.InstagramTooManyRedirects => .{ .code = "INSTAGRAM_FETCH_FAILED", .message = "Instagram could not deliver this item. Try again; the existing X downloader is unaffected." },
        else => null,
    };
}

test "Instagram URLs preserve case and treat img_index as a hint" {
    const parsed = try parseUrl("https://www.instagram.com/reel/Ab_C-9/?igsh=ignored&img_index=7");
    try std.testing.expectEqualStrings("Ab_C-9", parsed.shortcode);
    try std.testing.expectEqual(@as(?u8, 7), parsed.highlighted_ordinal);
    try std.testing.expect(!matches("https://instagram.com.evil.test/p/ABC/"));
    try std.testing.expect(!matches("https://instagram.com/stories/user/123/"));
    try std.testing.expect(!matches("https://user:pass@instagram.com/p/ABC/"));
}

test "Instagram metadata cannot turn a video or incomplete carousel into a cover photo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = Config{};
    const incomplete = "{\"code\":\"AbC\",\"media_type\":8,\"carousel_media_count\":3,\"image_versions2\":{\"candidates\":[]}}";
    try std.testing.expect((try parsePage(arena.allocator(), &config, "AbC", incomplete, 1, null)) == null);
    const video = "{\"code\":\"AbC\",\"pk\":\"11\",\"media_type\":2,\"image_versions2\":{\"candidates\":[{\"url\":\"https://s.cdninstagram.com/poster.jpg\",\"width\":1080,\"height\":1080}]}}";
    try std.testing.expect((try parsePage(arena.allocator(), &config, "AbC", video, 1, null)) == null);
}

test "Instagram signed URLs are preserved and unrelated recommendations ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = Config{};
    const bytes = "{\"items\":[{\"code\":\"Wrong\",\"pk\":\"9\",\"media_type\":1},{\"code\":\"AbC\",\"pk\":\"11\",\"media_type\":1,\"image_versions2\":{\"candidates\":[{\"url\":\"https://s.cdninstagram.com/photo.jpg?sig=Ab%2F&size=large\",\"width\":1080,\"height\":1350},{\"url\":\"https://s.cdninstagram.com/thumb.jpg\",\"width\":320,\"height\":400}]}}]}";
    const result = (try parsePage(arena.allocator(), &config, "AbC", bytes, 1, null)).?;
    try std.testing.expectEqualStrings("https://s.cdninstagram.com/photo.jpg?sig=Ab%2F&size=large", result.instagram_plan.?.items[0].url.?);
    try std.testing.expectEqual(@as(u8, 1), result.item_count);
    try std.testing.expect(!allowedUrl(&config, "https://s.cdninstagram.com.attacker.test/x", false));
    try std.testing.expect(!allowedUrl(&config, "http://127.0.0.1/x", false));
}
