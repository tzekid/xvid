const std = @import("std");

const Statvfs = extern struct {
    block_size: c_ulong,
    fragment_size: c_ulong,
    blocks: u64,
    blocks_free: u64,
    blocks_available: u64,
    files: u64,
    files_free: u64,
    files_available: u64,
    filesystem_id: c_ulong,
    flags: c_ulong,
    maximum_name_length: c_ulong,
    filesystem_type: c_uint,
    spare: [5]c_int,
};

extern "c" fn statvfs(path: [*:0]const u8, facts: *Statvfs) c_int;

pub fn availableBytes(allocator: std.mem.Allocator, path: []const u8) !u64 {
    const terminated = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(terminated);
    var facts: Statvfs = undefined;
    if (statvfs(terminated.ptr, &facts) != 0) return error.StatvfsFailed;
    return std.math.mul(u64, @intCast(facts.blocks_available), @intCast(facts.fragment_size)) catch error.DiskSizeOverflow;
}
