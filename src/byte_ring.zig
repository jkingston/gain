//! Bounded SPSC input storage. Storage publishes bytes; the codec consumes them.
const std = @import("std");

pub const Ring = struct {
    storage: []u8,
    read_index: usize = 0,
    write_index: usize = 0,
    read_sequence: std.atomic.Value(u32) = .init(0),
    write_sequence: std.atomic.Value(u32) = .init(0),

    pub fn init(storage: []u8) error{InvalidCapacity}!Ring {
        if (storage.len == 0 or storage.len > std.math.maxInt(u31)) return error.InvalidCapacity;
        return .{ .storage = storage };
    }

    pub fn capacity(self: *const Ring) usize {
        return self.storage.len;
    }

    pub fn available(self: *const Ring) usize {
        const consumed = self.read_sequence.load(.acquire);
        return self.write_sequence.load(.acquire) -% consumed;
    }

    pub fn free(self: *const Ring) usize {
        return self.storage.len - self.available();
    }

    /// Requires both participants to be stopped, as on a session change.
    pub fn clear(self: *Ring) void {
        self.read_index = 0;
        self.write_index = 0;
        self.read_sequence.store(0, .release);
        self.write_sequence.store(0, .release);
    }

    pub fn write(self: *Ring, source: []const u8) usize {
        const sequence = self.write_sequence.load(.monotonic);
        const used: usize = sequence -% self.read_sequence.load(.acquire);
        const count = @min(source.len, self.storage.len - used);
        const first = @min(count, self.storage.len - self.write_index);
        @memcpy(self.storage[self.write_index..][0..first], source[0..first]);
        @memcpy(self.storage[0 .. count - first], source[first..count]);
        self.write_index += count;
        if (self.write_index >= self.storage.len) self.write_index -= self.storage.len;
        self.write_sequence.store(sequence +% @as(u32, @intCast(count)), .release);
        return count;
    }

    pub fn read(self: *Ring, output: []u8) usize {
        const sequence = self.read_sequence.load(.monotonic);
        const count = @min(output.len, self.write_sequence.load(.acquire) -% sequence);
        const first = @min(count, self.storage.len - self.read_index);
        @memcpy(output[0..first], self.storage[self.read_index..][0..first]);
        @memcpy(output[first..count], self.storage[0 .. count - first]);
        self.read_index += count;
        if (self.read_index >= self.storage.len) self.read_index -= self.storage.len;
        self.read_sequence.store(sequence +% @as(u32, @intCast(count)), .release);
        return count;
    }
};

test "compressed queue preserves bytes through index and sequence wraps" {
    var guarded: [19]u8 = @splat(0xa5);
    var ring = try Ring.init(guarded[1..18]);
    ring.read_sequence.store(0xffff_fff0, .monotonic);
    ring.write_sequence.store(0xffff_fff0, .monotonic);
    var model: [17]u8 = undefined;
    var model_used: usize = 0;
    var generated: u32 = 0;
    var consumed: u32 = 0;
    var random: u32 = 123;
    for (0..20_000) |_| {
        random = random *% 1_664_525 +% 1_013_904_223;
        if (random & 1 == 0) {
            var source: [11]u8 = undefined;
            for (&source, 0..) |*byte, offset| byte.* = @truncate(generated +% @as(u32, @intCast(offset)));
            const count = ring.write(source[0 .. (random >> 8) % 12]);
            @memcpy(model[model_used..][0..count], source[0..count]);
            model_used += count;
            generated +%= @intCast(count);
        } else {
            var output: [13]u8 = undefined;
            const count = ring.read(output[0 .. (random >> 8) % 14]);
            try std.testing.expectEqualSlices(u8, model[0..count], output[0..count]);
            for (output[0..count]) |byte| {
                try std.testing.expectEqual(@as(u8, @truncate(consumed)), byte);
                consumed +%= 1;
            }
            std.mem.copyForwards(u8, model[0 .. model_used - count], model[count..model_used]);
            model_used -= count;
        }
        try std.testing.expectEqual(model_used, ring.available());
        try std.testing.expectEqual(@as(u8, 0xa5), guarded[0]);
        try std.testing.expectEqual(@as(u8, 0xa5), guarded[18]);
    }
}

test "empty rings fail admission and quiescent reset discards old bytes" {
    try std.testing.expectError(error.InvalidCapacity, Ring.init(&.{}));
    var storage: [4]u8 = undefined;
    var ring = try Ring.init(&storage);
    _ = ring.write("old");
    ring.clear();
    try std.testing.expectEqual(@as(usize, 0), ring.available());
    _ = ring.write("new");
    var output: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), ring.read(&output));
    try std.testing.expectEqualStrings("new", output[0..3]);
}
