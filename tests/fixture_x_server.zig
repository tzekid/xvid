const std = @import("std");
const fixture_poster = @embedFile("fixture_poster");

const State = struct {
    real_video: ?[]const u8 = null,
    guest_activations: u32 = 0,
    refresh_requests: u8 = 0,
    refresh_plan_requests: u8 = 0,
    transient_drop_graphql: u8 = 0,
    transient_drop_syndication: u8 = 0,
    transient_server_graphql: u8 = 0,
    transient_server_syndication: u8 = 0,
    transient_malformed_graphql: u8 = 0,
    transient_malformed_syndication: u8 = 0,
    rejected_graphql_drop_syndication: u8 = 0,
    slow_probe_requests: u8 = 0,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2 and args.len != 4) return error.ExpectedListenAddress;
    if (args.len == 4 and !std.mem.eql(u8, args[2], "--video-file")) return error.ExpectedVideoFileOption;
    const address = try std.Io.net.IpAddress.parseLiteral(args[1]);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    var state = State{};
    if (args.len == 4) state.real_video = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], init.arena.allocator(), .limited(8 * 1024 * 1024));
    while (true) {
        const stream = try listener.accept(init.io);
        serve(init.io, init.arena.allocator(), stream, args[1], &state) catch {};
        stream.close(init.io);
    }
}

fn serve(io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, origin: []const u8, state: *State) !void {
    var request_buffer: [64 * 1024]u8 = undefined;
    var response_buffer: [16 * 1024]u8 = undefined;
    var connection_reader = stream.reader(io, &request_buffer);
    var connection_writer = stream.writer(io, &response_buffer);
    var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);
    var request = try server.receiveHead();
    request.head.keep_alive = false;

    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/ready")) {
        return textResponse(&request, .ok, "ready\n");
    }
    if (request.head.method == .POST and std.mem.eql(u8, request.head.target, "/guest")) {
        state.guest_activations += 1;
        const body = try std.fmt.allocPrint(allocator, "{{\"guest_token\":\"fixture-token-{d}\"}}\n", .{state.guest_activations});
        return jsonResponse(&request, .ok, body);
    }
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/graphql?")) {
        const status_id = graphqlStatusId(request.head.target) orelse return jsonResponse(&request, .bad_request, "{}\n");
        return graphqlResponse(io, allocator, &request, origin, state, status_id);
    }
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/tweet-result?")) {
        const status_id = queryValue(request.head.target, "id") orelse "123";
        return syndicationResponse(allocator, &request, origin, state, status_id);
    }
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/redirect/allowed")) {
        const location = try std.fmt.allocPrint(allocator, "http://{s}/media/photo-a.jpg", .{origin});
        return request.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = location }} });
    }
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/redirect/disallowed")) {
        return request.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = "http://127.0.0.2/rejected.jpg" }} });
    }
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/media/poster.png")) return imageResponse(&request, "image/png", fixture_poster);
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/media/photo-a.jpg")) return imageResponse(&request, "image/jpeg", "\xff\xd8\xff\xe0fixture-jpeg-image-a");
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/media/photo-b.png")) return imageResponse(&request, "image/png", "\x89PNG\r\n\x1a\nfixture-png-image-b");
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/media/photo-c.webp")) return imageResponse(&request, "image/webp", "RIFF\x18\x00\x00\x00WEBPfixture-webp-c");
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/media/photo-d.jpg")) return imageResponse(&request, "image/jpeg", "\xff\xd8\xff\xe1fixture-jpeg-image-d");
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/media/invalid.jpg")) return imageResponse(&request, "image/jpeg", "not-an-image");
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/media/rejected")) return textResponse(&request, .forbidden, "rejected\n");
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/media/declared-large.jpg")) {
        const body = try allocator.alloc(u8, 8 * 1024 * 1024 + 1);
        @memset(body, 0x61);
        @memcpy(body[0..3], "\xff\xd8\xff");
        return imageResponse(&request, "image/jpeg", body);
    }
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/media/actual-large.jpg")) return streamActualLarge(io, &request);
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/media/slow.jpg")) return streamSlow(io, &request);
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/video/invalid.mp4")) return imageResponse(&request, "video/mp4", "not-an-mp4");
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/video/ffprobe-reject.mp4")) return imageResponse(&request, "video/mp4", "\x00\x00\x00\x18ftypisomffprobe-reject");
    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/video/320x240/real.mp4")) {
        const body = state.real_video orelse return textResponse(&request, .not_found, "missing video fixture\n");
        return imageResponse(&request, "video/mp4", body);
    }
    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/video/encode-fail.mp4"))
        return imageResponse(&request, "video/mp4", "\x00\x00\x00\x18ftypisomfixture-mp4 encode-fail height=1080");
    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/video/encode-stall.mp4"))
        return imageResponse(&request, "video/mp4", "\x00\x00\x00\x18ftypisomfixture-mp4 encode-stall height=1080");
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, "/video/")) {
        const height: u32 = if (std.mem.indexOf(u8, request.head.target, "1920x1080") != null)
            1080
        else if (std.mem.indexOf(u8, request.head.target, "1280x720") != null)
            720
        else
            360;
        const body = try std.fmt.allocPrint(allocator, "\x00\x00\x00\x18ftypisomfixture-mp4 height={d}", .{height});
        return imageResponse(&request, "video/mp4", body);
    }
    return textResponse(&request, .not_found, "not found\n");
}

fn graphqlResponse(io: std.Io, allocator: std.mem.Allocator, request: *std.http.Server.Request, origin: []const u8, state: *State, status_id: []const u8) !void {
    if (std.mem.eql(u8, status_id, "2117")) {
        state.refresh_requests += 1;
        if (state.refresh_requests == 1) return jsonResponse(request, .forbidden, "{}\n");
    }
    if (std.mem.eql(u8, status_id, "2118")) return jsonResponse(request, .too_many_requests, "{}\n");
    if (std.mem.eql(u8, status_id, "2119")) return jsonResponse(request, .ok, "{malformed\n");
    if (std.mem.eql(u8, status_id, "2120")) return jsonResponse(request, .ok, "{\"data\":{}}\n");
    if (std.mem.eql(u8, status_id, "2121")) {
        const body = try allocator.alloc(u8, 2 * 1024 * 1024 + 1);
        @memset(body, 'x');
        return jsonResponse(request, .ok, body);
    }
    if (std.mem.eql(u8, status_id, "2132")) {
        state.transient_drop_graphql += 1;
        if (state.transient_drop_graphql == 1) return error.FixtureDropConnection;
    }
    if (std.mem.eql(u8, status_id, "2133")) {
        state.transient_server_graphql += 1;
        if (state.transient_server_graphql == 1) return jsonResponse(request, .service_unavailable, "{}\n");
    }
    if (std.mem.eql(u8, status_id, "2134")) {
        state.transient_malformed_graphql += 1;
        if (state.transient_malformed_graphql == 1) return jsonResponse(request, .ok, "{truncated\n");
    }
    if (std.mem.eql(u8, status_id, "2135")) {
        state.slow_probe_requests += 1;
        if (state.slow_probe_requests == 1) try io.sleep(.fromSeconds(2), .awake);
    }
    if (std.mem.eql(u8, status_id, "2137")) return error.FixtureDropConnection;
    if (std.mem.eql(u8, status_id, "2138")) return jsonResponse(request, .forbidden, "{}\n");

    const result = try graphqlResult(allocator, origin, state, status_id);
    const body = try std.fmt.allocPrint(allocator, "{{\"data\":{{\"tweetResult\":{{\"result\":{s}}}}}}}\n", .{result});
    return jsonResponse(request, .ok, body);
}

fn graphqlResult(allocator: std.mem.Allocator, origin: []const u8, state: *State, status_id: []const u8) ![]const u8 {
    if (std.mem.eql(u8, status_id, "2111")) return "{\"__typename\":\"TweetTombstone\",\"tombstone\":{}}";
    if (std.mem.eql(u8, status_id, "2112")) return "{\"__typename\":\"TweetUnavailable\",\"reason\":\"Protected\"}";
    if (std.mem.eql(u8, status_id, "2113")) return "{\"__typename\":\"TweetUnavailable\",\"reason\":\"NsfwLoggedOut\"}";
    if (std.mem.eql(u8, status_id, "2116")) return "{\"__typename\":\"NewProviderShape\"}";

    if (std.mem.eql(u8, status_id, "2107")) {
        const original = try tweet(allocator, origin, "Retweeted author", "Original media", try onePhoto(allocator, origin));
        return std.fmt.allocPrint(allocator, "{{\"__typename\":\"Tweet\",\"legacy\":{{\"full_text\":\"wrapper\",\"retweeted_status_result\":{{\"result\":{s}}}}}}}", .{original});
    }
    if (std.mem.eql(u8, status_id, "2108")) {
        const quoted = try tweet(allocator, origin, "Quoted author", "Quoted media", try oneVideo(allocator, origin));
        return std.fmt.allocPrint(allocator, "{{\"__typename\":\"Tweet\",\"legacy\":{{\"full_text\":\"Target wins\",\"extended_entities\":{{\"media\":[{s}]}}}},\"quoted_status_result\":{{\"result\":{s}}}}}", .{ try photo(allocator, origin, "target", "photo-a.jpg", 2048, 1365), quoted });
    }
    if (std.mem.eql(u8, status_id, "2109")) {
        const quoted = try tweet(allocator, origin, "Quoted author", "Quoted media", try oneVideo(allocator, origin));
        return std.fmt.allocPrint(allocator, "{{\"__typename\":\"Tweet\",\"legacy\":{{\"full_text\":\"No target media\"}},\"quoted_status_result\":{{\"result\":{s}}}}}", .{quoted});
    }

    if (std.mem.eql(u8, status_id, "2123")) return tweet(allocator, origin, "Fixture User", "Allowed redirect", try customPhoto(allocator, origin, "redirect-ok", "redirect/allowed"));
    if (std.mem.eql(u8, status_id, "2124")) return tweet(allocator, origin, "Fixture User", "Rejected redirect", try customPhoto(allocator, origin, "redirect-bad", "redirect/disallowed"));
    if (std.mem.eql(u8, status_id, "2125")) return tweet(allocator, origin, "Fixture User", "Declared too large", try customPhoto(allocator, origin, "declared-large", "media/declared-large.jpg"));
    if (std.mem.eql(u8, status_id, "2126")) return tweet(allocator, origin, "Fixture User", "Invalid image", try customPhoto(allocator, origin, "invalid-image", "media/invalid.jpg"));
    if (std.mem.eql(u8, status_id, "2127")) return tweet(allocator, origin, "Fixture User", "Invalid MP4", try customVideo(allocator, origin, "invalid-video", "video/invalid.mp4"));
    if (std.mem.eql(u8, status_id, "2128")) return tweet(allocator, origin, "Fixture User", "FFprobe rejects", try customVideo(allocator, origin, "ffprobe-reject", "video/ffprobe-reject.mp4"));
    if (std.mem.eql(u8, status_id, "2129")) {
        state.refresh_plan_requests += 1;
        const path = if (state.refresh_plan_requests == 1) "media/rejected.mp4" else "video/1920x1080/refreshed.mp4";
        return tweet(allocator, origin, "Fixture User", "Expired plan refresh", try customVideo(allocator, origin, "refresh-video", path));
    }
    if (std.mem.eql(u8, status_id, "2130")) return tweet(allocator, origin, "Fixture User", "Slow media", try customPhoto(allocator, origin, "slow-photo", "media/slow.jpg"));
    if (std.mem.eql(u8, status_id, "2131")) return tweet(allocator, origin, "Fixture User", "Actual too large", try customPhoto(allocator, origin, "actual-large", "media/actual-large.jpg"));
    if (std.mem.eql(u8, status_id, "2140")) return tweet(allocator, origin, "Fixture User", "Invalid optional poster", try videoWithThumbnail(allocator, origin, "posterless-video", "posterless", "media/invalid.jpg"));
    if (std.mem.eql(u8, status_id, "2141")) {
        if (state.real_video == null) return error.MissingVideoFixture;
        // Matches the one-second 320x240 clip generated by e2e.sh.
        const media = try std.fmt.allocPrint(allocator, "{{\"id_str\":\"real-video\",\"type\":\"video\",\"original_info\":{{\"width\":320,\"height\":240}},\"video_info\":{{\"duration_millis\":1000,\"variants\":[{{\"content_type\":\"video/mp4\",\"url\":\"http://{s}/video/320x240/real.mp4\",\"width\":320,\"height\":240}}]}}}}", .{origin});
        return tweet(allocator, origin, "Fixture User", "Generated local video", media);
    }
    if (std.mem.eql(u8, status_id, "2142")) return tweet(allocator, origin, "Fixture User", "Encoder failure", try customVideo(allocator, origin, "encode-fail", "video/encode-fail.mp4"));
    if (std.mem.eql(u8, status_id, "2143")) return tweet(allocator, origin, "Fixture User", "Encoder cancellation", try customVideo(allocator, origin, "encode-stall", "video/encode-stall.mp4"));

    const media = if (std.mem.eql(u8, status_id, "2102"))
        try fourPhotos(allocator, origin)
    else if (std.mem.eql(u8, status_id, "2103") or std.mem.eql(u8, status_id, "2117"))
        try oneVideo(allocator, origin)
    else if (std.mem.eql(u8, status_id, "2104"))
        try twoVideos(allocator, origin)
    else if (std.mem.eql(u8, status_id, "2105"))
        try mixedMedia(allocator, origin)
    else if (std.mem.eql(u8, status_id, "2106"))
        try oneAnimatedGif(allocator, origin)
    else if (std.mem.eql(u8, status_id, "2114") or std.mem.eql(u8, status_id, "2115"))
        null
    else
        try onePhoto(allocator, origin);

    if (std.mem.eql(u8, status_id, "2114")) return tweetWithoutMedia(allocator, false);
    if (std.mem.eql(u8, status_id, "2115")) return tweetWithoutMedia(allocator, true);
    const normal = try tweet(allocator, origin, "Fixture User", "Fixture post https://t.co/removed\\nwith media", media.?);
    if (std.mem.eql(u8, status_id, "2110")) return std.fmt.allocPrint(allocator, "{{\"__typename\":\"TweetWithVisibilityResults\",\"tweet\":{s}}}", .{normal});
    return normal;
}

fn syndicationResponse(allocator: std.mem.Allocator, request: *std.http.Server.Request, origin: []const u8, state: *State, status_id: []const u8) !void {
    if (std.mem.eql(u8, status_id, "2118")) {
        const body = try std.fmt.allocPrint(allocator, "{{\"__typename\":\"Tweet\",\"text\":\"Syndication fallback\",\"user\":{{\"name\":\"Fixture User\"}},\"mediaDetails\":[{s}]}}\n", .{try video(allocator, origin, "syndicated-video", "a")});
        return jsonResponse(request, .ok, body);
    }
    if (std.mem.eql(u8, status_id, "2119")) return jsonResponse(request, .ok, "{also-malformed\n");
    if (std.mem.eql(u8, status_id, "2120")) return jsonResponse(request, .ok, "{\"unexpected\":true}\n");
    if (std.mem.eql(u8, status_id, "2116")) return jsonResponse(request, .ok, "{\"__typename\":\"NewProviderShape\"}\n");
    if (std.mem.eql(u8, status_id, "2121")) {
        const body = try allocator.alloc(u8, 512 * 1024 + 1);
        @memset(body, 'x');
        return jsonResponse(request, .ok, body);
    }
    if (std.mem.eql(u8, status_id, "2132")) {
        state.transient_drop_syndication += 1;
        if (state.transient_drop_syndication == 1) return error.FixtureDropConnection;
    }
    if (std.mem.eql(u8, status_id, "2133")) {
        state.transient_server_syndication += 1;
        if (state.transient_server_syndication == 1) return jsonResponse(request, .bad_gateway, "{}\n");
    }
    if (std.mem.eql(u8, status_id, "2134")) {
        state.transient_malformed_syndication += 1;
        if (state.transient_malformed_syndication == 1) return jsonResponse(request, .ok, "{also-truncated\n");
    }
    if (std.mem.eql(u8, status_id, "2137")) return error.FixtureDropConnection;
    if (std.mem.eql(u8, status_id, "2138")) {
        state.rejected_graphql_drop_syndication += 1;
        if (state.rejected_graphql_drop_syndication == 1) return error.FixtureDropConnection;
    }
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"__typename\":\"Tweet\",\"text\":\"Earthset.\\nTwo fixture photos. https://t.co/example\",\"user\":{{\"name\":\"Fixture NASA\"}},\"mediaDetails\":[{s},{s}]}}\n",
        .{ try photo(allocator, origin, "photo-a", "photo-a.jpg", 2048, 1365), try photo(allocator, origin, "photo-b", "photo-b.png", 1024, 1024) },
    );
    return jsonResponse(request, .ok, body);
}

fn tweet(allocator: std.mem.Allocator, origin: []const u8, author: []const u8, text: []const u8, media: []const u8) ![]const u8 {
    _ = origin;
    return std.fmt.allocPrint(allocator, "{{\"__typename\":\"Tweet\",\"legacy\":{{\"full_text\":\"{s}\",\"extended_entities\":{{\"media\":[{s}]}}}},\"core\":{{\"user_results\":{{\"result\":{{\"legacy\":{{\"name\":\"{s}\"}}}}}}}}}}", .{ text, media, author });
}

fn tweetWithoutMedia(allocator: std.mem.Allocator, card: bool) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"__typename\":\"Tweet\",\"legacy\":{{\"full_text\":\"No attached media\"}}{s}}}", .{if (card) ",\"card\":{\"legacy\":{}}" else ""});
}

fn onePhoto(allocator: std.mem.Allocator, origin: []const u8) ![]const u8 {
    return photo(allocator, origin, "photo-a", "photo-a.jpg", 2048, 1365);
}

fn fourPhotos(allocator: std.mem.Allocator, origin: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s},{s},{s},{s}", .{
        try photo(allocator, origin, "photo-a", "photo-a.jpg", 2048, 1365),
        try photo(allocator, origin, "photo-b", "photo-b.png", 1024, 1024),
        try photo(allocator, origin, "photo-c", "photo-c.webp", 1600, 900),
        try photo(allocator, origin, "photo-d", "photo-d.jpg", 1200, 1800),
    });
}

fn oneVideo(allocator: std.mem.Allocator, origin: []const u8) ![]const u8 {
    return video(allocator, origin, "video-a", "a");
}

fn twoVideos(allocator: std.mem.Allocator, origin: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s},{s}", .{ try video(allocator, origin, "video-a", "a"), try video(allocator, origin, "video-b", "b") });
}

fn mixedMedia(allocator: std.mem.Allocator, origin: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s},{s},{s}", .{
        try photo(allocator, origin, "photo-a", "photo-a.jpg", 2048, 1365),
        try video(allocator, origin, "video-a", "a"),
        try photo(allocator, origin, "photo-b", "photo-b.png", 1024, 1024),
    });
}

fn oneAnimatedGif(allocator: std.mem.Allocator, origin: []const u8) ![]const u8 {
    const value = try video(allocator, origin, "gif-a", "gif");
    const marker = "\"type\":\"video\"";
    const index = std.mem.indexOf(u8, value, marker) orelse return error.InvalidFixture;
    const output = try allocator.alloc(u8, value.len + "animated_gif".len - "video".len);
    @memcpy(output[0..index], value[0..index]);
    const replacement = "\"type\":\"animated_gif\"";
    @memcpy(output[index .. index + replacement.len], replacement);
    @memcpy(output[index + replacement.len ..], value[index + marker.len ..]);
    return output;
}

fn photo(allocator: std.mem.Allocator, origin: []const u8, id: []const u8, filename: []const u8, width: u32, height: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"id_str\":\"{s}\",\"type\":\"photo\",\"media_url_https\":\"http://{s}/media/{s}?format=jpg&name=small\",\"original_info\":{{\"width\":{d},\"height\":{d}}}}}", .{ id, origin, filename, width, height });
}

fn customPhoto(allocator: std.mem.Allocator, origin: []const u8, id: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"id_str\":\"{s}\",\"type\":\"photo\",\"media_url_https\":\"http://{s}/{s}\",\"original_info\":{{\"width\":2048,\"height\":1365}}}}", .{ id, origin, path });
}

fn customVideo(allocator: std.mem.Allocator, origin: []const u8, id: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"id_str\":\"{s}\",\"type\":\"video\",\"media_url_https\":\"http://{s}/media/poster.png\",\"video_info\":{{\"duration_millis\":42400,\"variants\":[{{\"content_type\":\"video/mp4\",\"url\":\"http://{s}/{s}\",\"width\":1920,\"height\":1080,\"bitrate\":8320000}}]}}}}", .{ id, origin, origin, path });
}

fn video(allocator: std.mem.Allocator, origin: []const u8, id: []const u8, stem: []const u8) ![]const u8 {
    return videoWithThumbnail(allocator, origin, id, stem, "media/poster.png");
}

fn videoWithThumbnail(allocator: std.mem.Allocator, origin: []const u8, id: []const u8, stem: []const u8, thumbnail_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"id_str\":\"{s}\",\"type\":\"video\",\"media_url_https\":\"http://{s}/{s}\",\"video_info\":{{\"duration_millis\":42400,\"variants\":[{{\"content_type\":\"application/x-mpegURL\",\"url\":\"http://{s}/video/{s}.m3u8\"}},{{\"content_type\":\"video/mp4\",\"url\":\"http://{s}/video/640x360/{s}.mp4\",\"bitrate\":832000}},{{\"content_type\":\"video/mp4\",\"url\":\"http://{s}/video/1920x1080/{s}.mp4\",\"bit_rate\":8320000}},{{\"content_type\":\"video/mp4\",\"url\":\"http://{s}/video/1280x720/{s}.mp4\",\"bitrate\":2176000}}]}}}}",
        .{ id, origin, thumbnail_path, origin, stem, origin, stem, origin, stem, origin, stem },
    );
}

fn graphqlStatusId(target: []const u8) ?[]const u8 {
    const marker = "%22tweetId%22%3A%22";
    const start = (std.mem.indexOf(u8, target, marker) orelse return null) + marker.len;
    var end = start;
    while (end < target.len and std.ascii.isDigit(target[end])) : (end += 1) {}
    if (end == start) return null;
    return target[start..end];
}

fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var parameters = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (parameters.next()) |parameter| {
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
        if (std.mem.eql(u8, parameter[0..equals], name)) return parameter[equals + 1 ..];
    }
    return null;
}

fn jsonResponse(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    return request.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

fn textResponse(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    return request.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
}

fn imageResponse(request: *std.http.Server.Request, content_type: []const u8, body: []const u8) !void {
    return request.respond(body, .{ .extra_headers = &.{.{ .name = "content-type", .value = content_type }} });
}

fn streamSlow(io: std.Io, request: *std.http.Server.Request) !void {
    const total: usize = 2 * 1024 * 1024;
    var response_buffer: [16 * 1024]u8 = undefined;
    var response = try request.respondStreaming(&response_buffer, .{
        .content_length = total,
        .respond_options = .{ .extra_headers = &.{.{ .name = "content-type", .value = "image/jpeg" }} },
    });
    var chunk: [64 * 1024]u8 = @splat(0x62);
    @memcpy(chunk[0..3], "\xff\xd8\xff");
    var written: usize = 0;
    while (written < total) {
        const count = @min(chunk.len, total - written);
        try response.writer.writeAll(chunk[0..count]);
        try response.writer.flush();
        written += count;
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    try response.end();
}

fn streamActualLarge(io: std.Io, request: *std.http.Server.Request) !void {
    _ = io;
    const total: usize = 8 * 1024 * 1024 + 1;
    var response_buffer: [16 * 1024]u8 = undefined;
    var response = try request.respondStreaming(&response_buffer, .{
        .respond_options = .{ .extra_headers = &.{.{ .name = "content-type", .value = "image/jpeg" }} },
    });
    var chunk: [64 * 1024]u8 = @splat(0x63);
    @memcpy(chunk[0..3], "\xff\xd8\xff");
    var written: usize = 0;
    while (written < total) {
        const count = @min(chunk.len, total - written);
        try response.writer.writeAll(chunk[0..count]);
        written += count;
    }
    try response.end();
}
