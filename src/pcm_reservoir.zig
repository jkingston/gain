const std = @import("std");

pub const StereoFrame = extern struct {
    /// Full-scale signed Q1.31 PCM. Codecs normalize into this domain before
    /// committing a frame; device output quantizes it exactly once.
    left: i32,
    right: i32,
};

pub const Error = error{
    EmptyStorage,
    InvalidInitialLength,
    CapacityTooLarge,
};

/// Allocation-free single-producer/single-consumer PCM ring. Each side owns its
/// local index and publishes a monotonic sequence with release ordering after
/// touching storage. The other side acquires that sequence before using data or
/// reclaiming space. `clear` requires producer and consumer to be quiescent.
pub const Ring = struct {
    storage: []StereoFrame,
    consumer_index: usize = 0,
    producer_index: usize = 0,
    read_sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    write_sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(storage: []StereoFrame) Error!Ring {
        return initFilled(storage, 0);
    }

    pub fn initFilled(storage: []StereoFrame, initial_frames: usize) Error!Ring {
        if (storage.len == 0) return error.EmptyStorage;
        if (initial_frames > storage.len) return error.InvalidInitialLength;
        if (storage.len > std.math.maxInt(u31)) return error.CapacityTooLarge;
        return .{
            .storage = storage,
            .producer_index = if (initial_frames == storage.len) 0 else initial_frames,
            .write_sequence = std.atomic.Value(u32).init(@intCast(initial_frames)),
        };
    }

    pub fn capacity(self: Ring) usize {
        return self.storage.len;
    }

    pub fn available(self: *const Ring) usize {
        const read = self.read_sequence.load(.acquire);
        const write_value = self.write_sequence.load(.acquire);
        return @intCast(write_value -% read);
    }

    pub fn free(self: *const Ring) usize {
        return self.storage.len - self.available();
    }

    pub fn clear(self: *Ring) void {
        self.consumer_index = 0;
        self.producer_index = 0;
        self.read_sequence.store(0, .release);
        self.write_sequence.store(0, .release);
    }

    pub fn write(self: *Ring, source: []const StereoFrame) usize {
        const write_value = self.write_sequence.load(.monotonic);
        const read = self.read_sequence.load(.acquire);
        const used: usize = @intCast(write_value -% read);
        const count = @min(source.len, self.storage.len - used);
        if (count == 0) return 0;

        const first = @min(count, self.storage.len - self.producer_index);
        @memcpy(self.storage[self.producer_index..][0..first], source[0..first]);
        const second = count - first;
        if (second != 0) @memcpy(self.storage[0..second], source[first..][0..second]);
        self.producer_index += count;
        if (self.producer_index >= self.storage.len) self.producer_index -= self.storage.len;
        self.write_sequence.store(write_value +% @as(u32, @intCast(count)), .release);
        return count;
    }

    pub inline fn pop(self: *Ring) ?StereoFrame {
        const read = self.read_sequence.load(.monotonic);
        if (read == self.write_sequence.load(.acquire)) return null;
        const frame = self.storage[self.consumer_index];
        self.consumer_index += 1;
        if (self.consumer_index == self.storage.len) self.consumer_index = 0;
        self.read_sequence.store(read +% 1, .release);
        return frame;
    }

    /// Borrow a contiguous published span without releasing any storage. Only
    /// the consumer may call this; the producer cannot reuse it until consume.
    pub fn readable(self: *const Ring, maximum: usize) []const StereoFrame {
        const read = self.read_sequence.load(.monotonic);
        const available_frames = self.write_sequence.load(.acquire) -% read;
        const count = @min(maximum, available_frames, self.storage.len - self.consumer_index);
        return self.storage[self.consumer_index..][0..count];
    }

    /// Release a prefix of the borrowed span after all sample reads complete.
    /// One release per span replaces per-sample publication in period output.
    pub fn consume(self: *Ring, count: usize) void {
        std.debug.assert(count <= self.storage.len - self.consumer_index and count <= self.available());
        const read = self.read_sequence.load(.monotonic);
        self.consumer_index += count;
        if (self.consumer_index == self.storage.len) self.consumer_index = 0;
        self.read_sequence.store(read +% @as(u32, @intCast(count)), .release);
    }
};

test "borrowed PCM remains owned until consumption and producer reuse preserves unread suffix" {
    var storage: [5]StereoFrame = undefined;
    var ring = try Ring.init(&storage);
    const source = [_]StereoFrame{ .{ .left = 1, .right = 2 }, .{ .left = 3, .right = 4 }, .{ .left = 5, .right = 6 }, .{ .left = 7, .right = 8 } };
    try std.testing.expectEqual(4, ring.write(&source));
    const borrowed = ring.readable(4);
    try std.testing.expectEqual(1, ring.free());
    try std.testing.expectEqual(1, ring.write(&source));
    try std.testing.expectEqualSlices(StereoFrame, &source, borrowed);
    ring.consume(3);
    try std.testing.expectEqual(3, ring.write(source[1..]));
    try std.testing.expectEqual(7, borrowed[3].left);
    ring.consume(1);
    try std.testing.expectEqual(1, ring.readable(5).len);
    try std.testing.expectEqual(1, ring.readable(5)[0].left);
    ring.consume(1);
    try std.testing.expectEqualSlices(StereoFrame, source[1..], ring.readable(5));
    ring.consume(3);
    try std.testing.expectEqual(0, ring.readable(5).len);
}

comptime {
    if (@sizeOf(StereoFrame) != 8) @compileError("stereo PCM frames must contain two i32 samples");
}

test "ring preserves order across producer and consumer wrap" {
    var storage: [5]StereoFrame = undefined;
    var ring = try Ring.init(&storage);
    const first = [_]StereoFrame{
        .{ .left = 0, .right = 10 },
        .{ .left = 1, .right = 11 },
        .{ .left = 2, .right = 12 },
        .{ .left = 3, .right = 13 },
    };
    try std.testing.expectEqual(@as(usize, 4), ring.write(&first));
    try std.testing.expectEqual(@as(i32, 0), ring.pop().?.left);
    try std.testing.expectEqual(@as(i32, 1), ring.pop().?.left);

    const second = [_]StereoFrame{
        .{ .left = 4, .right = 14 },
        .{ .left = 5, .right = 15 },
        .{ .left = 6, .right = 16 },
    };
    try std.testing.expectEqual(@as(usize, 3), ring.write(&second));
    for ([_]i32{ 2, 3, 4, 5, 6 }) |expected| {
        try std.testing.expectEqual(expected, ring.pop().?.left);
    }
    try std.testing.expect(ring.pop() == null);
}

test "producer backpressure is bounded by external storage" {
    var storage: [2]StereoFrame = undefined;
    var ring = try Ring.init(&storage);
    const source: [3]StereoFrame = @splat(.{ .left = 1, .right = -1 });
    try std.testing.expectEqual(@as(usize, 2), ring.write(&source));
    try std.testing.expectEqual(@as(usize, 0), ring.free());
    try std.testing.expectEqual(@as(usize, 0), ring.write(source[0..1]));
}

test "sequence wrap preserves occupancy and order" {
    var storage: [4]StereoFrame = undefined;
    var ring = try Ring.init(&storage);
    ring.read_sequence.store(0xffff_fffe, .monotonic);
    ring.write_sequence.store(0xffff_fffe, .monotonic);
    const source = [_]StereoFrame{
        .{ .left = 10, .right = -10 },
        .{ .left = 11, .right = -11 },
        .{ .left = 12, .right = -12 },
    };
    try std.testing.expectEqual(@as(usize, 3), ring.write(&source));
    try std.testing.expectEqual(@as(usize, 3), ring.available());
    for (source) |expected| try std.testing.expectEqual(expected, ring.pop().?);
    try std.testing.expectEqual(@as(usize, 0), ring.available());
}

test "producer and scalar or borrowed consumers contend without loss or torn stereo frames" {
    const frame_count = 250_000;
    var storage: [127]StereoFrame = undefined;
    var ring = try Ring.init(&storage);

    const Producer = struct {
        fn run(target: *Ring) void {
            var next: u32 = 0;
            var batch: [13]StereoFrame = undefined;
            while (next < frame_count) {
                const wanted = @min(batch.len, frame_count - next);
                for (batch[0..wanted], 0..) |*frame, offset| {
                    const value: i32 = @intCast(next + offset);
                    frame.* = .{ .left = value, .right = ~value };
                }
                next += @intCast(target.write(batch[0..wanted]));
                if (next < frame_count) std.Thread.yield() catch {};
            }
        }
    };

    const producer = try std.Thread.spawn(.{}, Producer.run, .{&ring});
    var expected: u32 = 0;
    while (expected < frame_count) {
        if (expected % 2 == 0) {
            const span = ring.readable(33);
            // Let the producer run while these samples are still borrowed.
            std.Thread.yield() catch {};
            for (span) |frame| {
                const value: i32 = @intCast(expected);
                try std.testing.expectEqual(value, frame.left);
                try std.testing.expectEqual(~value, frame.right);
                expected += 1;
            }
            ring.consume(span.len);
        } else if (ring.pop()) |frame| {
            const value: i32 = @intCast(expected);
            try std.testing.expectEqual(value, frame.left);
            try std.testing.expectEqual(~value, frame.right);
            expected += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }
    producer.join();
    try std.testing.expectEqual(@as(usize, 0), ring.available());
}
