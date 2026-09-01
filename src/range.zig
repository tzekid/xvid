const std = @import("std");

pub const ByteRange = struct {
    start: u64,
    end: u64,

    pub fn length(value: ByteRange) u64 {
        return value.end - value.start + 1;
    }
};

pub fn parse(value: []const u8, size: u64) !ByteRange {
    if (size == 0 or value.len > 128 or !std.ascii.startsWithIgnoreCase(value, "bytes=")) return error.RangeNotSatisfiable;
    const specification = std.mem.trim(u8, value[6..], " \t");
    if (specification.len == 0 or std.mem.indexOfScalar(u8, specification, ',') != null) return error.MultipleOrMissingRanges;
    const dash = std.mem.indexOfScalar(u8, specification, '-') orelse return error.InvalidRange;
    if (std.mem.indexOfScalarPos(u8, specification, dash + 1, '-') != null) return error.InvalidRange;
    const first = std.mem.trim(u8, specification[0..dash], " \t");
    const last = std.mem.trim(u8, specification[dash + 1 ..], " \t");
    if (first.len == 0) {
        const suffix = std.fmt.parseInt(u64, last, 10) catch return error.InvalidRange;
        if (suffix == 0) return error.RangeNotSatisfiable;
        const length = @min(suffix, size);
        return .{ .start = size - length, .end = size - 1 };
    }
    const start = std.fmt.parseInt(u64, first, 10) catch return error.InvalidRange;
    if (start >= size) return error.RangeNotSatisfiable;
    if (last.len == 0) return .{ .start = start, .end = size - 1 };
    const requested_end = std.fmt.parseInt(u64, last, 10) catch return error.InvalidRange;
    if (requested_end < start) return error.RangeNotSatisfiable;
    return .{ .start = start, .end = @min(requested_end, size - 1) };
}

test "single byte ranges cover fixed open and suffix forms" {
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 9 }, try parse("bytes=0-9", 100));
    try std.testing.expectEqual(ByteRange{ .start = 90, .end = 99 }, try parse("bytes=-10", 100));
    try std.testing.expectEqual(ByteRange{ .start = 50, .end = 99 }, try parse("bytes=50-", 100));
    try std.testing.expectEqual(ByteRange{ .start = 95, .end = 99 }, try parse("bytes=95-200", 100));
    try std.testing.expectError(error.MultipleOrMissingRanges, parse("bytes=0-1,3-4", 100));
    try std.testing.expectError(error.RangeNotSatisfiable, parse("bytes=100-", 100));
}
