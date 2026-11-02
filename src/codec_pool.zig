//! Caller-owned, bounded C decoder allocation. One codec task binds a pool for
//! each library call; other firmware services never use these C entry points.
const std = @import("std");

const alignment = 16;

const Header = extern struct { capacity: u32, requested: u32 = 0, used: u32 = 0, reserved: u32 = 0 };
const header_bytes = @sizeOf(Header);
var active: ?*Pool = null;

pub const Statistics = struct { live: u32 = 0, peak: u32 = 0, allocations: u32 = 0, failures: u32 = 0 };

pub const Pool = struct {
    storage: []align(alignment) u8,
    statistics: Statistics = .{},

    pub fn init(storage: []align(alignment) u8) error{InvalidCapacity}!Pool {
        if (storage.len < header_bytes + alignment or storage.len > std.math.maxInt(u31)) return error.InvalidCapacity;
        var pool = Pool{ .storage = storage[0 .. storage.len & ~@as(usize, alignment - 1)] };
        pool.header(0).* = .{ .capacity = @intCast(pool.storage.len - header_bytes) };
        return pool;
    }

    pub fn bind(self: *Pool) Binding {
        const previous = active;
        active = self;
        return .{ .previous = previous };
    }

    fn header(self: *Pool, offset: usize) *Header {
        return @ptrCast(@alignCast(self.storage.ptr + offset));
    }

    pub fn allocate(self: *Pool, bytes: usize) ?*anyopaque {
        self.statistics.allocations +%= 1;
        if (bytes == 0 or bytes > self.storage.len - header_bytes) return self.failed();
        const rounded = (bytes + alignment - 1) & ~@as(usize, alignment - 1);
        var offset: usize = 0;
        while (offset < self.storage.len) {
            const block = self.header(offset);
            if (block.used == 0 and block.capacity >= rounded) {
                if (block.capacity >= rounded + header_bytes + alignment) {
                    self.header(offset + header_bytes + rounded).* = .{ .capacity = block.capacity - @as(u32, @intCast(rounded)) - header_bytes };
                    block.capacity = @intCast(rounded);
                }
                block.used = 1;
                block.requested = @intCast(bytes);
                self.statistics.live += @intCast(bytes);
                self.statistics.peak = @max(self.statistics.peak, self.statistics.live);
                return @ptrCast(self.storage.ptr + offset + header_bytes);
            }
            offset += header_bytes + block.capacity;
        }
        return self.failed();
    }

    fn failed(self: *Pool) ?*anyopaque {
        self.statistics.failures +%= 1;
        return null;
    }

    pub fn release(self: *Pool, pointer: ?*anyopaque) void {
        const ptr = pointer orelse return;
        const offset = @intFromPtr(ptr) - @intFromPtr(self.storage.ptr) - header_bytes;
        std.debug.assert(offset < self.storage.len and offset % alignment == 0);
        const block = self.header(offset);
        std.debug.assert(block.used == 1);
        self.statistics.live -= block.requested;
        block.used = 0;
        block.requested = 0;
        var cursor: usize = 0;
        while (cursor < self.storage.len) {
            const current = self.header(cursor);
            const next = cursor + header_bytes + current.capacity;
            if (next < self.storage.len and current.used == 0 and self.header(next).used == 0) {
                current.capacity += header_bytes + self.header(next).capacity;
            } else cursor = next;
        }
    }

    pub fn resize(self: *Pool, pointer: ?*anyopaque, bytes: usize) ?*anyopaque {
        const old = pointer orelse return self.allocate(bytes);
        if (bytes == 0) {
            self.release(old);
            return null;
        }
        const block = self.header(@intFromPtr(old) - @intFromPtr(self.storage.ptr) - header_bytes);
        if (bytes <= block.capacity) {
            self.statistics.live -= block.requested;
            block.requested = @intCast(bytes);
            self.statistics.live += @intCast(bytes);
            self.statistics.peak = @max(self.statistics.peak, self.statistics.live);
            return old;
        }
        const replacement = self.allocate(bytes) orelse return null;
        @memcpy(@as([*]u8, @ptrCast(replacement))[0..block.requested], @as([*]const u8, @ptrCast(old))[0..block.requested]);
        self.release(old);
        return replacement;
    }
};

pub const Binding = struct {
    previous: ?*Pool,

    pub fn end(self: Binding) void {
        active = self.previous;
    }
};

export fn gain_codec_malloc(bytes: usize) ?*anyopaque {
    return if (active) |pool| pool.allocate(bytes) else null;
}

export fn gain_codec_free(pointer: ?*anyopaque) void {
    if (active) |pool| pool.release(pointer) else std.debug.assert(pointer == null);
}

export fn gain_codec_realloc(pointer: ?*anyopaque, bytes: usize) ?*anyopaque {
    return if (active) |pool| pool.resize(pointer, bytes) else null;
}

export fn gain_codec_calloc(count: usize, bytes: usize) ?*anyopaque {
    const total = std.math.mul(usize, count, bytes) catch return null;
    const pointer = gain_codec_malloc(total) orelse return null;
    @memset(@as([*]u8, @ptrCast(pointer))[0..total], 0);
    return pointer;
}

test "allocation failure preserves contents and releases coalesce" {
    var storage: [1024]u8 align(alignment) = undefined;
    var pool = try Pool.init(&storage);
    const first = pool.allocate(31).?;
    const second = pool.allocate(67).?;
    @memset(@as([*]u8, @ptrCast(first))[0..31], 0x5a);
    try std.testing.expect(pool.resize(first, 4096) == null);
    for (@as([*]u8, @ptrCast(first))[0..31]) |value| try std.testing.expectEqual(@as(u8, 0x5a), value);
    const resized = pool.resize(first, 100).?;
    for (@as([*]u8, @ptrCast(resized))[0..31]) |value| try std.testing.expectEqual(@as(u8, 0x5a), value);
    pool.release(second);
    pool.release(resized);
    try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
    const full = pool.allocate(storage.len - header_bytes).?;
    pool.release(full);
}

test "C bindings restore the previous owner and calloc checks multiplication" {
    var a: [1024]u8 align(alignment) = undefined;
    var b: [1024]u8 align(alignment) = undefined;
    var first = try Pool.init(&a);
    var second = try Pool.init(&b);
    const outer = first.bind();
    defer outer.end();
    const pointer = gain_codec_calloc(3, 7).?;
    for (@as([*]u8, @ptrCast(pointer))[0..21]) |value| try std.testing.expectEqual(@as(u8, 0), value);
    {
        const inner = second.bind();
        defer inner.end();
        const temporary = gain_codec_malloc(32).?;
        gain_codec_free(temporary);
    }
    try std.testing.expect(gain_codec_calloc(std.math.maxInt(usize), 2) == null);
    gain_codec_free(pointer);
    try std.testing.expectEqual(@as(u32, 0), first.statistics.live);
    try std.testing.expectEqual(@as(u32, 0), second.statistics.live);
}

test "seeded allocator reuse preserves live C state through resize and fragmentation" {
    const Lease = struct {
        pointer: *anyopaque,
        length: usize,
        pattern: u8,

        fn verify(self: @This()) !void {
            for (@as([*]const u8, @ptrCast(self.pointer))[0..self.length]) |value|
                try std.testing.expectEqual(self.pattern, value);
        }

        fn fill(self: @This()) void {
            @memset(@as([*]u8, @ptrCast(self.pointer))[0..self.length], self.pattern);
        }
    };

    var storage: [16 * 1024]u8 align(alignment) = undefined;
    var pool = try Pool.init(&storage);
    var leases: [32]?Lease = @splat(null);
    var random = std.Random.DefaultPrng.init(0x4741494e);
    for (0..8000) |_| {
        const slot = random.random().uintLessThan(usize, leases.len);
        if (leases[slot]) |old| {
            try old.verify();
            if (random.random().boolean()) {
                const length = 1 + random.random().uintLessThan(usize, 1024);
                if (pool.resize(old.pointer, length)) |pointer| {
                    const kept = Lease{ .pointer = pointer, .length = @min(length, old.length), .pattern = old.pattern };
                    try kept.verify();
                    leases[slot] = .{ .pointer = pointer, .length = length, .pattern = old.pattern };
                    leases[slot].?.fill();
                } else try old.verify();
            } else {
                pool.release(old.pointer);
                leases[slot] = null;
            }
        } else {
            const length = 1 + random.random().uintLessThan(usize, 1024);
            if (pool.allocate(length)) |pointer| {
                leases[slot] = .{ .pointer = pointer, .length = length, .pattern = random.random().int(u8) };
                leases[slot].?.fill();
            }
        }
        var live: usize = 0;
        for (leases) |maybe| if (maybe) |lease| {
            try lease.verify();
            try std.testing.expectEqual(@as(usize, 0), @intFromPtr(lease.pointer) % alignment);
            live += lease.length;
        };
        try std.testing.expectEqual(live, pool.statistics.live);
    }
    for (leases) |maybe| if (maybe) |lease| pool.release(lease.pointer);
    try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
    const entire = pool.allocate(storage.len - header_bytes).?;
    pool.release(entire);
}
