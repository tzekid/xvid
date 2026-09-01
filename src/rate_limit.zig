const std = @import("std");

pub const Decision = enum { allowed, probes_limited, jobs_limited, table_full };

const Entry = struct {
    used: bool = false,
    key: u64 = 0,
    probe_tokens: f64 = 0,
    job_tokens: f64 = 0,
    updated_at: i64 = 0,
};

pub const Limiter = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    probes_per_minute: u16,
    jobs_per_hour: u16,
    mutex: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, capacity: u16, probes_per_minute: u16, jobs_per_hour: u16) !Limiter {
        if (capacity == 0 or probes_per_minute == 0 or jobs_per_hour == 0) return error.InvalidRateLimit;
        const entries = try allocator.alloc(Entry, capacity);
        @memset(entries, .{});
        return .{
            .allocator = allocator,
            .entries = entries,
            .probes_per_minute = probes_per_minute,
            .jobs_per_hour = jobs_per_hour,
        };
    }

    pub fn deinit(limiter: *Limiter) void {
        limiter.allocator.free(limiter.entries);
    }

    pub fn allow(limiter: *Limiter, key: u64, now: i64) Decision {
        limiter.lock();
        defer limiter.unlock();
        var available: ?*Entry = null;
        for (limiter.entries) |*entry| {
            if (entry.used and entry.key == key) return limiter.consume(entry, now);
            if (!entry.used or now - entry.updated_at >= 2 * 60 * 60) available = entry;
        }
        const entry = available orelse return .table_full;
        entry.* = .{
            .used = true,
            .key = key,
            .probe_tokens = @floatFromInt(limiter.probes_per_minute),
            .job_tokens = @floatFromInt(limiter.jobs_per_hour),
            .updated_at = now,
        };
        return limiter.consume(entry, now);
    }

    fn consume(limiter: *Limiter, entry: *Entry, now: i64) Decision {
        const elapsed: f64 = @floatFromInt(@max(0, now - entry.updated_at));
        entry.probe_tokens = @min(@as(f64, @floatFromInt(limiter.probes_per_minute)), entry.probe_tokens + elapsed * @as(f64, @floatFromInt(limiter.probes_per_minute)) / 60.0);
        entry.job_tokens = @min(@as(f64, @floatFromInt(limiter.jobs_per_hour)), entry.job_tokens + elapsed * @as(f64, @floatFromInt(limiter.jobs_per_hour)) / 3600.0);
        entry.updated_at = now;
        if (entry.probe_tokens < 1) return .probes_limited;
        if (entry.job_tokens < 1) return .jobs_limited;
        entry.probe_tokens -= 1;
        entry.job_tokens -= 1;
        return .allowed;
    }

    fn lock(limiter: *Limiter) void {
        while (limiter.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(limiter: *Limiter) void {
        limiter.mutex.store(false, .release);
    }
};

test "fixed token buckets deny and then refill" {
    var limiter = try Limiter.init(std.testing.allocator, 2, 2, 3);
    defer limiter.deinit();
    try std.testing.expectEqual(Decision.allowed, limiter.allow(7, 100));
    try std.testing.expectEqual(Decision.allowed, limiter.allow(7, 100));
    try std.testing.expectEqual(Decision.probes_limited, limiter.allow(7, 100));
    try std.testing.expectEqual(Decision.allowed, limiter.allow(7, 130));
    try std.testing.expectEqual(Decision.jobs_limited, limiter.allow(7, 160));
}

test "a full key table fails closed until an entry expires" {
    var limiter = try Limiter.init(std.testing.allocator, 1, 1, 1);
    defer limiter.deinit();
    try std.testing.expectEqual(Decision.allowed, limiter.allow(1, 100));
    try std.testing.expectEqual(Decision.table_full, limiter.allow(2, 101));
    try std.testing.expectEqual(Decision.allowed, limiter.allow(2, 100 + 2 * 60 * 60));
}
