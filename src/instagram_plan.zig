const std = @import("std");

pub const maximum_items = 32;
pub const maximum_url_bytes = 4096;
pub const Kind = enum { image, video, unknown };

pub const Item = struct {
    id: []const u8,
    ordinal: u8,
    kind: Kind,
    url: ?[]const u8 = null,
    thumbnail_url: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    duration_ms: ?u64 = null,

    pub fn available(item: Item) bool {
        return item.kind != .unknown and item.url != null;
    }
};

pub const Plan = struct {
    shortcode: []const u8,
    resolved_at: i64,
    highlighted_ordinal: ?u8 = null,
    items: []const Item,

    pub fn find(plan: Plan, id: []const u8) ?Item {
        for (plan.items) |item| if (std.mem.eql(u8, item.id, id)) return item;
        return null;
    }

    pub fn validate(plan: Plan) !void {
        if (!validId(plan.shortcode) or plan.resolved_at <= 0 or plan.items.len == 0 or plan.items.len > maximum_items) return error.InvalidInstagramPlan;
        if (plan.highlighted_ordinal) |ordinal| if (ordinal == 0 or ordinal > plan.items.len) return error.InvalidInstagramPlan;
        for (plan.items, 0..) |item, index| {
            if (!validId(item.id) or item.ordinal != index + 1) return error.InvalidInstagramPlan;
            for (plan.items[0..index]) |previous| if (std.mem.eql(u8, previous.id, item.id)) return error.InvalidInstagramPlan;
            if (item.url) |url| if (!validUrl(url) or item.kind == .unknown) return error.InvalidInstagramPlan;
            if (item.thumbnail_url) |url| if (!validUrl(url)) return error.InvalidInstagramPlan;
            if (item.width) |width| if (width == 0 or width > 65535) return error.InvalidInstagramPlan;
            if (item.height) |height| if (height == 0 or height > 65535) return error.InvalidInstagramPlan;
        }
    }

    pub fn clone(plan: Plan, allocator: std.mem.Allocator) !Plan {
        const items = try allocator.alloc(Item, plan.items.len);
        for (plan.items, 0..) |item, index| {
            items[index] = item;
            items[index].id = try allocator.dupe(u8, item.id);
            items[index].url = if (item.url) |url| try allocator.dupe(u8, url) else null;
            items[index].thumbnail_url = if (item.thumbnail_url) |url| try allocator.dupe(u8, url) else null;
        }
        return .{
            .shortcode = try allocator.dupe(u8, plan.shortcode),
            .resolved_at = plan.resolved_at,
            .highlighted_ordinal = plan.highlighted_ordinal,
            .items = items,
        };
    }
};

pub fn validId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

fn validUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > maximum_url_bytes or std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return false;
    const uri = std.Uri.parse(value) catch return false;
    return uri.host != null and uri.user == null and uri.password == null and uri.fragment == null and
        (std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "http"));
}

test "Instagram collection preserves unavailable positions and rejects duplicate IDs" {
    const plan = Plan{ .shortcode = "Ab_C-1", .resolved_at = 1, .items = &.{
        .{ .id = "100", .ordinal = 1, .kind = .image, .url = "https://cdn.example/1.jpg" },
        .{ .id = "101", .ordinal = 2, .kind = .video },
        .{ .id = "102", .ordinal = 3, .kind = .video, .url = "https://cdn.example/3.mp4" },
    } };
    try plan.validate();
    try std.testing.expect(!plan.items[1].available());
    try std.testing.expectEqual(@as(u8, 3), plan.find("102").?.ordinal);
    var bad = plan;
    bad.items = &.{ plan.items[0], plan.items[0] };
    try std.testing.expectError(error.InvalidInstagramPlan, bad.validate());
}
