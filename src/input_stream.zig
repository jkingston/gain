//! Buffered file input with one storage producer and one codec consumer. Seeks
//! are acknowledged only after the producer has stopped using the old window.
const std = @import("std");
const ByteRing = @import("byte_ring.zig").Ring;

pub fn Stream(comptime Reader: type, comptime Services: type) type {
    return struct {
        const Self = @This();
        reader: *Reader,
        services: *Services,
        ring: ByteRing,
        size: u32,
        position: u32 = 0,
        producer_position: u32 = 0,
        requested: std.atomic.Value(u32) = .init(0),
        acknowledged: std.atomic.Value(u32) = .init(0),
        target: u32 = 0,
        failure: ?anyerror = null,
        producer_end: bool = false,

        pub fn init(reader: *Reader, size: u32, storage: []u8, services: *Services) !Self {
            return .{ .reader = reader, .services = services, .ring = try ByteRing.init(storage), .size = size, .producer_end = size == 0 };
        }

        pub fn read(self: *Self, output: []u8) !usize {
            if (output.len == 0 or self.position == self.size) return 0;
            while (true) {
                if (self.services.cancelled()) return error.Cancelled;
                if (self.failure) |failure| return failure;
                const count = self.ring.read(output[0..@min(output.len, self.size - self.position)]);
                if (count != 0) {
                    self.position += @intCast(count);
                    if (self.ring.available() < self.ring.capacity() / 2) self.services.wakeStorage();
                    return count;
                }
                if (self.producer_end) return error.Truncated;
                self.services.prepareInputWait();
                // Recheck after clearing notifications: a producer completion
                // between the first observation and the wait must not be lost.
                if (self.ring.available() != 0 or self.failure != null or self.producer_end or self.services.cancelled()) continue;
                self.services.wakeStorage();
                self.services.waitInput();
            }
        }

        pub fn seekTo(self: *Self, target: u32) !void {
            if (target > self.size) return error.SeekBounds;
            if (target == self.position) return;
            const token = self.requestSeek(target);
            while (self.acknowledged.load(.acquire) != token) {
                if (self.services.cancelled()) return error.Cancelled;
                if (self.failure) |failure| return failure;
                self.services.prepareInputWait();
                if (self.acknowledged.load(.acquire) == token) break;
                if (self.failure != null or self.services.cancelled()) continue;
                self.services.wakeStorage();
                self.services.waitInput();
            }
            self.position = target;
        }

        fn requestSeek(self: *Self, target: u32) u32 {
            self.target = target;
            const token = self.requested.load(.monotonic) +% 1;
            self.requested.store(token, .release);
            self.services.wakeStorage();
            return token;
        }

        pub fn producerReady(self: *Self, burst_bytes: usize) bool {
            return self.requested.load(.acquire) != self.acknowledged.load(.monotonic) or
                (!self.producer_end and self.failure == null and self.ring.free() >= @min(burst_bytes, self.size - self.producer_position));
        }

        /// Runs in storage context. A single bounded read lets the executive
        /// schedule output/UI work between bursts and sleep at high water.
        pub fn produce(self: *Self, buffer: []u8) !bool {
            if (buffer.len == 0 or buffer.len > self.ring.capacity()) return error.InvalidBurst;
            const token = self.requested.load(.acquire);
            if (token != self.acknowledged.load(.monotonic)) {
                // The only consumer is blocked awaiting this acknowledgement.
                self.reader.seekTo(self.target) catch |failure| {
                    self.failure = failure;
                    self.services.wakeInput();
                    return false;
                };
                self.ring.clear();
                self.producer_position = self.target;
                self.producer_end = self.target == self.size;
                self.failure = null;
                self.acknowledged.store(token, .release);
                self.services.wakeInput();
                return true;
            }
            if (self.failure != null or self.producer_end) return false;
            const count = @min(buffer.len, self.size - self.producer_position);
            if (self.ring.free() < count) return false;
            const actual = self.reader.read(buffer[0..count]) catch |failure| {
                if (self.requested.load(.acquire) != token) return true;
                self.failure = failure;
                self.services.wakeInput();
                return false;
            };
            if (self.requested.load(.acquire) != token) return true;
            if (actual == 0 or actual > count) {
                self.failure = error.Truncated;
                self.services.wakeInput();
                return false;
            }
            const written = self.ring.write(buffer[0..actual]);
            std.debug.assert(written == actual);
            self.producer_position += @intCast(actual);
            self.producer_end = self.producer_position == self.size;
            self.services.wakeInput();
            return true;
        }
    };
}

const Test = struct {
    const Input = Stream(Reader, @This());

    const Reader = struct {
        owner: *Test,
        position: usize = 0,
        reads: usize = 0,
        fail: bool = false,
        fail_seek: bool = false,
        seek_on_read: ?u32 = null,
        zero_read: bool = false,
        oversize_read: bool = false,

        fn read(self: *Reader, output: []u8) !usize {
            self.reads += 1;
            if (self.seek_on_read) |target| {
                self.seek_on_read = null;
                _ = self.owner.input.requestSeek(target);
            }
            if (self.zero_read) return 0;
            if (self.oversize_read) return output.len + 1;
            if (self.fail) return error.CardRemoved;
            const count = @min(output.len, self.owner.bytes.len - self.position);
            @memcpy(output[0..count], self.owner.bytes[self.position..][0..count]);
            self.position += count;
            return count;
        }

        fn seekTo(self: *Reader, target: u32) !void {
            if (self.fail_seek) return error.CardRemoved;
            self.position = target;
        }
    };
    bytes: [1024]u8 = undefined,
    storage: [127]u8 = undefined,
    burst: [31]u8 = undefined,
    reader: Reader = undefined,
    input: Input = undefined,
    cancelled_flag: bool = false,
    notifications: usize = 0,
    waits: usize = 0,
    complete_on_prepare: bool = false,
    cancel_on_prepare: bool = false,

    fn init(self: *Test) !void {
        for (&self.bytes, 0..) |*byte, i| byte.* = @truncate(i * 31 + i / 17);
        self.reader = .{ .owner = self };
        self.input = try Input.init(&self.reader, self.bytes.len, &self.storage, self);
    }

    fn cancelled(self: *Test) bool {
        return self.cancelled_flag;
    }

    fn wakeStorage(_: *Test) void {}

    fn wakeInput(self: *Test) void {
        self.notifications += 1;
    }

    fn prepareInputWait(self: *Test) void {
        if (self.cancel_on_prepare) self.cancelled_flag = true;
        if (self.complete_on_prepare) {
            self.complete_on_prepare = false;
            _ = self.input.produce(&self.burst) catch unreachable;
        }
    }

    fn waitInput(self: *Test) void {
        self.waits += 1;
        _ = self.input.produce(&self.burst) catch unreachable;
    }
};

test "buffered input preserves fragmented reads seeks and producer backpressure" {
    var harness = Test{};
    try harness.init();
    var output: [73]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x4741494e);
    for (0..1000) |_| {
        const target = random.random().uintLessThan(u32, harness.bytes.len + 1);
        try harness.input.seekTo(target);
        const count = try harness.input.read(&output);
        try std.testing.expectEqualSlices(u8, harness.bytes[target..][0..count], output[0..count]);
    }
    try harness.input.seekTo(0);
    while (try harness.input.produce(&harness.burst)) {}
    try std.testing.expect(harness.input.ring.available() <= harness.storage.len);
    const reads = harness.reader.reads;
    try std.testing.expect(!try harness.input.produce(&harness.burst));
    try std.testing.expectEqual(reads, harness.reader.reads);
}

test "completion between empty observation and wait is consumed without sleeping" {
    var harness = Test{ .complete_on_prepare = true };
    try harness.init();
    var output: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try harness.input.read(&output));
    try std.testing.expectEqual(@as(usize, 0), harness.waits);
    try std.testing.expectEqualSlices(u8, harness.bytes[0..4], &output);
}

test "cancellation and storage failure wake the consumer with explicit errors" {
    var harness = Test{};
    try harness.init();
    var output: [4]u8 = undefined;
    harness.cancelled_flag = true;
    try std.testing.expectError(error.Cancelled, harness.input.read(&output));
    harness.cancelled_flag = false;
    harness.reader.fail = true;
    try std.testing.expectError(error.CardRemoved, harness.input.read(&output));
    try std.testing.expect(harness.notifications > 0);
}

test "EOF and invalid seeks are bounded and do not publish old bytes" {
    var harness = Test{};
    try harness.init();
    try harness.input.seekTo(harness.bytes.len);
    var output: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try harness.input.read(&output));
    try std.testing.expectError(error.SeekBounds, harness.input.seekTo(harness.bytes.len + 1));
    try harness.input.seekTo(10);
    const count = try harness.input.read(&output);
    try std.testing.expectEqualSlices(u8, harness.bytes[10..][0..count], output[0..count]);
}

test "empty input and invalid storage bursts never access the reader" {
    var harness = Test{};
    try harness.init();
    harness.input = try Test.Input.init(&harness.reader, 0, &harness.storage, &harness);
    var output: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try harness.input.read(&output));
    try std.testing.expect(!harness.input.producerReady(harness.burst.len));
    try std.testing.expect(!try harness.input.produce(&harness.burst));
    try std.testing.expectError(error.InvalidBurst, harness.input.produce(output[0..0]));
    var oversized: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidBurst, harness.input.produce(&oversized));
    try std.testing.expectEqual(@as(usize, 0), harness.reader.reads);
}

test "seek failure and invalid read results notify blocked consumers" {
    var harness = Test{};
    try harness.init();
    harness.reader.fail_seek = true;
    try std.testing.expectError(error.CardRemoved, harness.input.seekTo(99));
    try std.testing.expectEqual(@as(u32, 0), harness.input.position);
    try std.testing.expect(harness.notifications > 0);
    for ([_]bool{ false, true }) |oversize| {
        try harness.init();
        harness.reader.zero_read = !oversize;
        harness.reader.oversize_read = oversize;
        var output: [4]u8 = undefined;
        try std.testing.expectError(error.Truncated, harness.input.read(&output));
        try std.testing.expectEqual(@as(usize, 0), harness.input.ring.available());
    }
}

test "seek during in-flight read discards the old completion including errors" {
    for ([_]bool{ false, true }) |failure| {
        var harness = Test{};
        try harness.init();
        harness.reader.seek_on_read = 777;
        harness.reader.fail = failure;
        try std.testing.expect(try harness.input.produce(&harness.burst));
        try std.testing.expectEqual(@as(usize, 0), harness.input.ring.available());
        try std.testing.expect(harness.input.failure == null);
        harness.reader.fail = false;
        try std.testing.expect(try harness.input.produce(&harness.burst));
        // Model the consumer resuming after its seek acknowledgement.
        harness.input.position = 777;
        var output: [19]u8 = undefined;
        const count = try harness.input.read(&output);
        try std.testing.expectEqualSlices(u8, harness.bytes[777..][0..count], output[0..count]);
    }
}

test "cancellation in the prepare-wait window never blocks read or seek" {
    var harness = Test{ .cancel_on_prepare = true };
    try harness.init();
    var output: [4]u8 = undefined;
    try std.testing.expectError(error.Cancelled, harness.input.read(&output));
    try std.testing.expectEqual(@as(usize, 0), harness.waits);
    harness.cancelled_flag = false;
    try std.testing.expectError(error.Cancelled, harness.input.seekTo(99));
    try std.testing.expectEqual(@as(usize, 0), harness.waits);
}
