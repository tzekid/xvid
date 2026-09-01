const std = @import("std");
const job_mod = @import("job.zig");

pub const Id = [job_mod.id_length]u8;

pub const Queue = struct {
    allocator: std.mem.Allocator,
    items: []?Id,
    head: usize = 0,
    tail: usize = 0,
    count_value: usize = 0,
    mutex: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Queue {
        if (capacity == 0 or capacity > 4096) return error.InvalidQueueCapacity;
        const items = try allocator.alloc(?Id, capacity);
        @memset(items, null);
        return .{ .allocator = allocator, .items = items };
    }

    pub fn deinit(queue: *Queue) void {
        queue.allocator.free(queue.items);
    }

    pub fn tryPush(queue: *Queue, id: []const u8) !bool {
        if (!job_mod.validId(id)) return error.InvalidJobId;
        queue.lock();
        defer queue.unlock();
        if (queue.count_value == queue.items.len) return false;
        for (queue.items) |item| if (item) |existing| {
            if (std.mem.eql(u8, &existing, id)) return true;
        };
        var copy: Id = undefined;
        @memcpy(&copy, id);
        queue.items[queue.tail] = copy;
        queue.tail = (queue.tail + 1) % queue.items.len;
        queue.count_value += 1;
        return true;
    }

    pub fn pop(queue: *Queue) ?Id {
        queue.lock();
        defer queue.unlock();
        if (queue.count_value == 0) return null;
        const id = queue.items[queue.head].?;
        queue.items[queue.head] = null;
        queue.head = (queue.head + 1) % queue.items.len;
        queue.count_value -= 1;
        return id;
    }

    fn lock(queue: *Queue) void {
        while (queue.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(queue: *Queue) void {
        queue.mutex.store(false, .release);
    }
};

test "bounded queue coalesces duplicate job IDs" {
    var queue = try Queue.init(std.testing.allocator, 2);
    defer queue.deinit();
    const first = "0123456789abcdef0123456789abcdef";
    const second = "abcdef0123456789abcdef0123456789";
    try std.testing.expect(try queue.tryPush(first));
    try std.testing.expect(try queue.tryPush(first));
    try std.testing.expect(try queue.tryPush(second));
    try std.testing.expectEqualStrings(first, &(queue.pop().?));
    try std.testing.expectEqualStrings(second, &(queue.pop().?));
    try std.testing.expect(queue.pop() == null);
}
