const std = @import("std");

pub const Parsed = struct {
    uri: std.Uri,
    host: []const u8,
};

pub fn validate(raw: []const u8, host_buffer: []u8) !Parsed {
    if (raw.len == 0 or raw.len > 4096 or !std.unicode.utf8ValidateSlice(raw) or std.mem.indexOfAny(u8, raw, "\r\n\x00<>\"") != null) return error.InvalidUrl;
    const uri = std.Uri.parse(raw) catch return error.InvalidUrl;
    if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null) return error.InvalidUrl;
    const raw_host = uri.host.?.toRaw(host_buffer) catch return error.InvalidUrl;
    const host = if (raw_host.len >= 2 and raw_host[0] == '[' and raw_host[raw_host.len - 1] == ']') raw_host[1 .. raw_host.len - 1] else raw_host;
    if (host.len == 0 or host.len > 253 or std.mem.indexOfAny(u8, host, "\r\n\x00/") != null) return error.InvalidUrl;
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.endsWithIgnoreCase(host, ".localhost")) return error.PrivateAddress;
    if (std.Io.net.IpAddress.parse(host, 0)) |address| {
        if (!publicAddress(address)) return error.PrivateAddress;
    } else |_| {}
    return .{ .uri = uri, .host = host };
}

fn publicAddress(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip| publicV4(ip.bytes),
        .ip6 => |ip| publicV6(ip.bytes),
    };
}

fn publicV4(bytes: [4]u8) bool {
    if (bytes[0] == 0 or bytes[0] == 10 or bytes[0] == 127 or bytes[0] >= 224) return false;
    if (bytes[0] == 100 and bytes[1] >= 64 and bytes[1] <= 127) return false;
    if (bytes[0] == 169 and bytes[1] == 254) return false;
    if (bytes[0] == 172 and bytes[1] >= 16 and bytes[1] <= 31) return false;
    if (bytes[0] == 192 and (bytes[1] == 0 or bytes[1] == 168)) return false;
    if (bytes[0] == 198 and (bytes[1] == 18 or bytes[1] == 19 or bytes[1] == 51)) return false;
    if (bytes[0] == 203 and bytes[1] == 0 and bytes[2] == 113) return false;
    return true;
}

fn publicV6(bytes: [16]u8) bool {
    var all_zero = true;
    for (bytes) |byte| if (byte != 0) {
        all_zero = false;
        break;
    };
    if (all_zero) return false;
    var loopback = true;
    for (bytes[0..15]) |byte| if (byte != 0) {
        loopback = false;
        break;
    };
    if (loopback and bytes[15] == 1) return false;
    if ((bytes[0] & 0xfe) == 0xfc or (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80) or bytes[0] == 0xff) return false;
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0x0d and bytes[3] == 0xb8) return false;
    const mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    if (std.mem.eql(u8, bytes[0..12], &mapped_prefix)) return publicV4(bytes[12..16].*);
    return true;
}

test "URL validation accepts public HTTP and rejects local targets" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings("example.com", (try validate("https://example.com/media?id=1", &buffer)).host);
    try std.testing.expectError(error.InvalidUrl, validate("file:///etc/passwd", &buffer));
    try std.testing.expectError(error.InvalidUrl, validate("https://user:secret@example.com/file", &buffer));
    try std.testing.expectError(error.PrivateAddress, validate("http://127.0.0.1/file", &buffer));
    try std.testing.expectError(error.PrivateAddress, validate("http://10.2.3.4/file", &buffer));
    try std.testing.expectError(error.PrivateAddress, validate("http://[::1]/file", &buffer));
}
