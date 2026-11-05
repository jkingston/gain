//! Bounded, stable-ID play order. Canonical order is retained so disabling
//! shuffle never reconstructs the queue from a changing library snapshot.
const std = @import("std");

pub const Repeat = enum { off, all, one };

pub const Queue = struct {
    bytes: []u8,
    count: usize = 0,
    cursor: usize = 0,
    shuffled: bool = false,
    repeat: Repeat = .off,

    pub fn init(bytes: []u8) Queue {
        return .{ .bytes = bytes };
    }

    pub fn capacity(self: Queue) usize {
        return self.bytes.len / (2 * @sizeOf(u64));
    }

    pub fn clear(self: *Queue) void {
        self.count = 0;
        self.cursor = 0;
        self.shuffled = false;
        self.repeat = .off;
    }

    fn read(self: Queue, index: usize, shuffled: bool) u64 {
        const offset = (index + if (shuffled) self.capacity() else 0) * 8;
        return std.mem.readInt(u64, self.bytes[offset..][0..8], .little);
    }

    fn write(self: *Queue, index: usize, shuffled: bool, id: u64) void {
        const offset = (index + if (shuffled) self.capacity() else 0) * 8;
        std.mem.writeInt(u64, self.bytes[offset..][0..8], id, .little);
    }

    pub fn append(self: *Queue, id: u64) !void {
        if (id == 0) return error.InvalidTrackIdentity;
        if (self.count == self.capacity()) return error.QueueFull;
        self.write(self.count, false, id);
        self.write(self.count, true, id);
        self.count += 1;
    }

    pub fn at(self: Queue, index: usize) ?u64 {
        return if (index < self.count) self.read(index, self.shuffled) else null;
    }

    pub fn select(self: *Queue, id: u64) bool {
        for (0..self.count) |i| if (self.at(i).? == id) {
            self.cursor = i;
            return true;
        };
        return false;
    }

    /// Starting a shuffled collection randomizes everything. Enabling shuffle
    /// during playback keeps the current track and visited prefix in place.
    pub fn shuffle(self: *Queue, seed: u64, preserve_current: bool) void {
        if (self.shuffled) return;
        for (0..self.count) |i| self.write(i, true, self.read(i, false));
        var generator = std.Random.DefaultPrng.init(seed);
        const random = generator.random();
        const first = if (preserve_current and self.count != 0) self.cursor + 1 else 0;
        var end = self.count;
        while (end > first + 1) {
            end -= 1;
            const other = first + random.uintLessThan(usize, end - first + 1);
            const id = self.read(end, true);
            self.write(end, true, self.read(other, true));
            self.write(other, true, id);
        }
        self.shuffled = true;
        if (!preserve_current) self.cursor = 0;
    }

    pub fn sortCanonical(self: *Queue, resolver: anytype) void {
        std.debug.assert(!self.shuffled);
        const Sort = struct {
            queue: *Queue,
            resolver: @TypeOf(resolver),
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return ctx.resolver.less(ctx.queue.read(a, false), ctx.queue.read(b, false));
            }
            pub fn swap(ctx: @This(), a: usize, b: usize) void {
                const id = ctx.queue.read(a, false);
                ctx.queue.write(a, false, ctx.queue.read(b, false));
                ctx.queue.write(b, false, id);
            }
        };
        std.sort.heapContext(0, self.count, Sort{ .queue = self, .resolver = resolver });
    }

    pub fn unshuffle(self: *Queue) void {
        const current = self.at(self.cursor);
        self.shuffled = false;
        if (current) |id| _ = self.select(id);
    }

    /// Missing tracks are skipped with a bounded search. Manual skips ignore
    /// Repeat One; Repeat All wraps only inside this captured queue.
    pub fn adjacent(self: *Queue, direction: i2, resolver: anytype) ?u64 {
        std.debug.assert(direction == -1 or direction == 1);
        if (self.count == 0) return null;
        var position = self.cursor;
        for (0..self.count) |_| {
            if (direction < 0) {
                if (position == 0) {
                    if (self.repeat != .all) return null;
                    position = self.count;
                }
                position -= 1;
            } else {
                position += 1;
                if (position >= self.count) {
                    if (self.repeat != .all) return null;
                    position = 0;
                }
            }
            const id = self.at(position).?;
            if (resolver.contains(id)) {
                self.cursor = position;
                return id;
            }
        }
        return null;
    }

    pub fn finished(self: *Queue, resolver: anytype) ?u64 {
        if (self.repeat == .one) {
            if (self.at(self.cursor)) |id| if (resolver.contains(id)) return id;
        }
        return self.adjacent(1, resolver);
    }
};

const Present = struct {
    pub fn contains(_: @This(), id: u64) bool {
        return id != 3;
    }
};

test "play order survives browsing changes, removals and retags without inserting new scans" {
    var bytes: [64]u8 = undefined;
    var queue = Queue.init(&bytes);
    for ([_]u64{ 8, 5, 3, 9 }) |id| try queue.append(id);
    try std.testing.expect(queue.select(5));
    try std.testing.expectEqual(9, queue.adjacent(1, Present{}).?);
    try std.testing.expectEqual(null, queue.adjacent(1, Present{}));
    try std.testing.expectEqual(5, queue.adjacent(-1, Present{}).?);
    try std.testing.expectEqual(8, queue.adjacent(-1, Present{}).?);
    try std.testing.expectEqual(null, queue.adjacent(-1, Present{}));
    try std.testing.expectEqual(3, queue.at(2).?);
    try std.testing.expectError(error.QueueFull, queue.append(10));
}

test "seeded shuffle is a permutation, retains current playback and restores canonical order" {
    for (0..100) |seed| {
        var bytes: [64 * 16]u8 = undefined;
        var queue = Queue.init(&bytes);
        for (1..65) |id| try queue.append(id);
        try std.testing.expect(queue.select(12));
        queue.shuffle(seed, true);
        try std.testing.expectEqual(12, queue.at(queue.cursor).?);
        var seen: u64 = 0;
        for (0..queue.count) |i| {
            const mask = @as(u64, 1) << @as(u6, @intCast(queue.at(i).? - 1));
            try std.testing.expectEqual(0, seen & mask);
            seen |= mask;
            if (i < 12) try std.testing.expectEqual(i + 1, queue.at(i).?);
        }
        try std.testing.expectEqual(std.math.maxInt(u64), seen);
        const next = queue.adjacent(1, Present{}).?;
        queue.unshuffle();
        try std.testing.expectEqual(next, queue.at(queue.cursor).?);
        for (0..queue.count) |i| try std.testing.expectEqual(i + 1, queue.at(i).?);
    }
}

test "collection shuffle includes its first track and is reproducible" {
    var left: [128]u8 = undefined;
    var right: [128]u8 = undefined;
    var a = Queue.init(&left);
    var b = Queue.init(&right);
    for (1..9) |id| {
        try a.append(id);
        try b.append(id);
    }
    a.shuffle(42, false);
    b.shuffle(42, false);
    try std.testing.expectEqualSlices(u8, &left, &right);
    var different = false;
    for (0..a.count) |i| different = different or a.at(i).? != i + 1;
    try std.testing.expect(different);
}

test "repeat boundaries, manual skips and a wholly missing queue terminate correctly" {
    var bytes: [64]u8 = undefined;
    var queue = Queue.init(&bytes);
    for ([_]u64{ 8, 3, 9 }) |id| try queue.append(id);
    try std.testing.expect(queue.select(9));
    try std.testing.expectEqual(null, queue.finished(Present{}));
    queue.repeat = .all;
    try std.testing.expectEqual(8, queue.finished(Present{}).?);
    try std.testing.expectEqual(9, queue.adjacent(-1, Present{}).?);
    queue.repeat = .one;
    try std.testing.expectEqual(9, queue.finished(Present{}).?);
    try std.testing.expectEqual(8, queue.adjacent(-1, Present{}).?);
    const Missing = struct {
        pub fn contains(_: @This(), _: u64) bool {
            return false;
        }
    };
    queue.repeat = .all;
    try std.testing.expectEqual(null, queue.finished(Missing{}));
    queue.clear();
    try std.testing.expectEqual(null, queue.finished(Present{}));
    try std.testing.expectEqual(Repeat.off, queue.repeat);
    try std.testing.expect(!queue.shuffled);
}
