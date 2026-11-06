//! Sparse decoder checkpoints owned by one playback session. Identity includes
//! the caller's content stamp, so offsets never survive replacement of a file.
//! This is a cache: cold seeking remains correct when it is absent or exhausted.
const std = @import("std");

pub const Kind = enum { flac, mpeg, ogg };
pub const Point = struct { sample: u64, offset: u32, auxiliary: u32 = 0 };
pub const capacity = 1024;

pub const Index = struct {
    points: [capacity]Point = undefined,
    count: usize = 0,
    source: u64 = 0,
    length: u32 = 0,
    kind: Kind = .flac,
    interval: u64 = 1,
    disabled: bool = false,

    /// Reset only published metadata. Point storage is unreadable while count
    /// is zero; clearing/copying its entire plane wastes boot and handoff time.
    pub fn reset(self: *Index) void {
        self.count = 0;
        self.source = 0;
        self.length = 0;
        self.kind = .flac;
        self.interval = 1;
        self.disabled = false;
    }

    pub fn bind(self: *Index, source: u64, length: u64, kind: Kind) bool {
        if (source == 0 or length > std.math.maxInt(u32)) return false;
        if (self.source != source or self.length != length or self.kind != kind) {
            self.reset();
            self.source = source;
            self.length = @intCast(length);
            self.kind = kind;
        }
        return !self.disabled;
    }

    pub fn disable(self: *Index) void {
        self.count = 0;
        self.disabled = true;
    }

    pub fn before(self: *const Index, sample: u64) ?Point {
        if (self.disabled or self.count == 0 or self.points[0].sample > sample) return null;
        var first: usize = 0;
        var last = self.count;
        while (first < last) {
            const middle = first + (last - first) / 2;
            if (self.points[middle].sample <= sample) first = middle + 1 else last = middle;
        }
        return self.points[first - 1];
    }

    pub fn observe(self: *Index, point: Point, rate: u32) void {
        if (self.disabled or point.offset >= self.length) return;
        self.interval = @max(self.interval, rate / 2);
        var position: usize = 0;
        while (position < self.count and self.points[position].sample < point.sample) : (position += 1) {}
        if (position < self.count and self.points[position].sample == point.sample) return;
        if (position != 0 and point.sample - self.points[position - 1].sample < self.interval) return;
        if (position != self.count and self.points[position].sample - point.sample < self.interval) return;
        if (self.count == self.points.len) {
            // Retain an evenly spaced history rather than evicting the beginning
            // of a long track. Later backwards seeks can still reuse it.
            var out: usize = 0;
            for (0..self.count) |i| if (i % 2 == 0) {
                self.points[out] = self.points[i];
                out += 1;
            };
            self.count = out;
            self.interval *= 2;
            return self.observe(point, rate);
        }
        var i = self.count;
        while (i > position) : (i -= 1) self.points[i] = self.points[i - 1];
        self.points[position] = point;
        self.count += 1;
    }
};

/// Lookahead can decode the next file while the current file is still audible.
/// Retain both sets of checkpoints, plus the previous file, within bounded RAM.
pub const Cache = struct {
    indexes: [3]Index = @splat(.{}),
    used: [3]u32 = @splat(0),
    clock: u32 = 0,

    pub fn reset(self: *Cache) void {
        for (&self.indexes) |*index| index.reset();
        self.used = @splat(0);
        self.clock = 0;
    }

    pub fn forSource(self: *Cache, identity: u64, length: u64) ?*Index {
        if (identity == 0 or length > std.math.maxInt(u32)) return null;
        self.clock +%= 1;
        var selected: usize = 0;
        for (&self.indexes, 0..) |*index, i| {
            if (index.source == identity and index.length == length) {
                self.used[i] = self.clock;
                return index;
            }
            if (index.source == 0 or self.clock -% self.used[i] > self.clock -% self.used[selected]) selected = i;
        }
        self.indexes[selected].reset();
        self.indexes[selected].source = identity;
        self.indexes[selected].length = @intCast(length);
        self.used[selected] = self.clock;
        return &self.indexes[selected];
    }
};

test "lookahead retains current and previous source anchors and evicts the least recently used source" {
    var cache = Cache{};
    const a = cache.forSource(1, 10000).?;
    try std.testing.expect(a.bind(1, 10000, .mpeg));
    a.observe(.{ .sample = 0, .offset = 100 }, 48000);
    const b = cache.forSource(2, 10000).?;
    try std.testing.expect(a != b);
    _ = cache.forSource(3, 10000).?;
    try std.testing.expectEqual(a, cache.forSource(1, 10000).?);
    _ = cache.forSource(4, 10000).?;
    try std.testing.expectEqual(a, cache.forSource(1, 10000).?);
    try std.testing.expectEqual(1, a.count);
    try std.testing.expectEqual(null, cache.forSource(0, 10000));
    try std.testing.expectEqual(null, cache.forSource(1, @as(u64, std.math.maxInt(u32)) + 1));
    const changed = cache.forSource(1, 9999).?;
    try std.testing.expectEqual(0, changed.count);
}

test "seek cache is bounded, ordered and invalidated by source, length or format changes" {
    var index = Index{};
    try std.testing.expect(!index.bind(0, 1000, .flac));
    try std.testing.expect(index.bind(4, 4_000_000_000, .flac));
    for (0..20000) |i| index.observe(.{ .sample = i * 48000, .offset = @intCast(i * 10000) }, 48000);
    try std.testing.expect(index.count <= capacity and index.count > capacity / 2);
    try std.testing.expectEqual(0, index.before(0).?.sample);
    for (index.points[1..index.count], index.points[0 .. index.count - 1]) |a, b| {
        try std.testing.expect(a.sample > b.sample);
    }
    try std.testing.expect(index.bind(4, 4_000_000_000, .flac));
    try std.testing.expect(index.count != 0);
    try std.testing.expect(index.bind(5, 4_000_000_000, .flac));
    try std.testing.expectEqual(0, index.count);
    index.observe(.{ .sample = 12, .offset = 100 }, 48000);
    try std.testing.expectEqual(null, index.before(11));
    try std.testing.expectEqual(12, index.before(12).?.sample);
    try std.testing.expect(index.bind(5, 1000, .ogg));
    try std.testing.expectEqual(0, index.count);
    index.disable();
    try std.testing.expect(!index.bind(5, 1000, .ogg));
    try std.testing.expect(index.bind(6, 1000, .ogg));
}

test "metadata-only reset and source rebinding never touch unpublished point planes" {
    var cache: Cache = undefined;
    for (&cache.indexes) |*index| @memset(std.mem.asBytes(&index.points), 0xa5);
    cache.reset();
    for (&cache.indexes) |*index| {
        try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&index.points), 0xa5));
        try std.testing.expectEqual(null, index.before(std.math.maxInt(u64)));
    }
    for (1..9) |identity| {
        const index = cache.forSource(identity, 10000).?;
        try std.testing.expect(index.bind(identity, 10000, .mpeg));
        try std.testing.expectEqual(0, index.count);
        try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&index.points), 0xa5));
    }
    const index = cache.forSource(8, 10000).?;
    index.observe(.{ .sample = 0, .offset = 12 }, 48000);
    index.reset();
    try std.testing.expectEqual(0, index.count);
    try std.testing.expectEqual(12, index.points[0].offset);
    try std.testing.expect(index.bind(9, 10000, .ogg));
    try std.testing.expectEqual(12, index.points[0].offset);
}
