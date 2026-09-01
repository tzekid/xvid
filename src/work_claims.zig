const std = @import("std");
const job_mod = @import("job.zig");

pub const Kind = enum { probe, media };
const Id = [job_mod.id_length]u8;

const Entry = struct {
    used: bool = false,
    kind: Kind = .probe,
    id: Id = @splat(0),
};

pub const Claims = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    mutex: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, maximum_jobs: usize) !Claims {
        if (maximum_jobs == 0 or maximum_jobs > 4096) return error.InvalidClaimCapacity;
        const entries = try allocator.alloc(Entry, maximum_jobs * 2);
        @memset(entries, .{});
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(claims: *Claims) void {
        claims.allocator.free(claims.entries);
    }

    pub fn claim(claims: *Claims, kind: Kind, id: []const u8) !bool {
        if (!job_mod.validId(id)) return error.InvalidJobId;
        claims.lock();
        defer claims.unlock();
        var free: ?*Entry = null;
        for (claims.entries) |*entry| {
            if (entry.used and entry.kind == kind and std.mem.eql(u8, &entry.id, id)) return false;
            if (!entry.used and free == null) free = entry;
        }
        const entry = free orelse return error.ClaimTableFull;
        var copy: Id = undefined;
        @memcpy(&copy, id);
        entry.* = .{ .used = true, .kind = kind, .id = copy };
        return true;
    }

    pub fn release(claims: *Claims, kind: Kind, id: []const u8) void {
        if (!job_mod.validId(id)) return;
        claims.lock();
        defer claims.unlock();
        for (claims.entries) |*entry| {
            if (entry.used and entry.kind == kind and std.mem.eql(u8, &entry.id, id)) {
                entry.* = .{};
                return;
            }
        }
    }

    pub fn contains(claims: *Claims, kind: Kind, id: []const u8) bool {
        if (!job_mod.validId(id)) return false;
        claims.lock();
        defer claims.unlock();
        for (claims.entries) |entry| {
            if (entry.used and entry.kind == kind and std.mem.eql(u8, &entry.id, id)) return true;
        }
        return false;
    }

    fn lock(claims: *Claims) void {
        while (claims.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(claims: *Claims) void {
        claims.mutex.store(false, .release);
    }
};

test "claims permit one executor per job and phase" {
    var claims = try Claims.init(std.testing.allocator, 2);
    defer claims.deinit();
    const id = "0123456789abcdef0123456789abcdef";
    try std.testing.expect(try claims.claim(.probe, id));
    try std.testing.expect(!(try claims.claim(.probe, id)));
    try std.testing.expect(try claims.claim(.media, id));
    try std.testing.expect(claims.contains(.probe, id));
    claims.release(.probe, id);
    try std.testing.expect(!claims.contains(.probe, id));
    try std.testing.expect(try claims.claim(.probe, id));
}
