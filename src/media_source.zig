//! Cached random access over a bounded sequential reader. Small container table
//! lookups share a caller-owned cache instead of becoming individual SD reads.
const std = @import("std");
pub fn Source(comptime Reader: type) type {
    return struct {
        const Self = @This();
        reader: *Reader,
        length: u64,
        cache: []u8,
        cache_start: u64 = 0,
        cache_bytes: usize = 0,
        position: u64 = 0,
        pub fn init(reader: *Reader, length: u64, cache: []u8) !Self {
            if (cache.len < 512) return error.InvalidCache;
            if (length > std.math.maxInt(u32)) return error.FileTooLarge;
            try reader.seekTo(0);
            return .{ .reader = reader, .length = length, .cache = cache };
        }
        pub fn read(self: *Self, offset: u64, output: []u8) !void {
            if (offset > self.length or output.len > self.length - offset) return error.Truncated;
            var done: usize = 0;
            while (done < output.len) {
                const at = offset + done;
                if (at >= self.cache_start and at - self.cache_start < self.cache_bytes) {
                    const start: usize = @intCast(at - self.cache_start);
                    const count = @min(output.len - done, self.cache_bytes - start);
                    @memcpy(output[done..][0..count], self.cache[start..][0..count]);
                    done += count;
                } else if (output.len - done >= self.cache.len) {
                    try self.exact(at, output[done..]);
                    return;
                } else {
                    self.cache_start = at & ~@as(u64, 511);
                    const count: usize = @intCast(@min(self.cache.len, self.length - self.cache_start));
                    self.cache_bytes = 0;
                    try self.exact(self.cache_start, self.cache[0..count]);
                    self.cache_bytes = count;
                }
            }
        }
        fn exact(self: *Self, offset: u64, output: []u8) !void {
            if (offset != self.position) try self.reader.seekTo(@intCast(offset));
            self.position = offset;
            var done: usize = 0;
            while (done < output.len) {
                const count = try self.reader.read(output[done..]);
                if (count == 0) return error.Truncated;
                if (count > output.len - done) return error.InvalidReadCount;
                done += count;
                self.position += count;
            }
        }
        pub fn int(self: *Self, comptime T: type, offset: u64, comptime endian: std.builtin.Endian) !T {
            var bytes: [@sizeOf(T)]u8 = undefined;
            try self.read(offset, &bytes);
            return std.mem.readInt(T, &bytes, endian);
        }
    };
}
const MemoryReader = struct {
    bytes: []const u8,
    position: usize = 0,
    fragment: usize = 7,
    calls: usize = 0,
    fn seekTo(self: *MemoryReader, offset: u32) !void {
        if (offset > self.bytes.len) return error.SeekBounds;
        self.position = offset;
    }
    fn read(self: *MemoryReader, output: []u8) !usize {
        self.calls += 1;
        const count = @min(output.len, self.fragment, self.bytes.len - self.position);
        @memcpy(output[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};
test "random cached reads preserve bytes under one-byte source fragments" {
    var bytes: [4096]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 73 + i / 11);
    var reader = MemoryReader{ .bytes = &bytes, .fragment = 1 };
    var cache: [1024]u8 = undefined;
    var source = try Source(MemoryReader).init(&reader, bytes.len, &cache);
    var random = std.Random.DefaultPrng.init(0x4741494e);
    var out: [1500]u8 = undefined;
    for (0..1000) |_| {
        const count = random.random().uintLessThan(usize, out.len + 1);
        const offset = random.random().uintLessThan(usize, bytes.len - count + 1);
        try source.read(offset, out[0..count]);
        try std.testing.expectEqualSlices(u8, bytes[offset..][0..count], out[0..count]);
    }
    try std.testing.expectError(error.Truncated, source.read(bytes.len - 1, out[0..2]));
    try source.read(bytes.len, out[0..0]);
}
test "small table reads reuse the cache and truncated readers fail explicitly" {
    const bytes: [1024]u8 = @splat(0x12);
    var reader = MemoryReader{ .bytes = &bytes, .fragment = 1024 };
    var cache: [1024]u8 = undefined;
    var source = try Source(MemoryReader).init(&reader, bytes.len, &cache);
    for (0..100) |i| try std.testing.expectEqual(@as(u32, 0x12121212), try source.int(u32, i * 4, .big));
    try std.testing.expectEqual(@as(usize, 1), reader.calls);
    reader = .{ .bytes = bytes[0..10] };
    source = try Source(MemoryReader).init(&reader, 1024, &cache);
    var output: [12]u8 = undefined;
    try std.testing.expectError(error.Truncated, source.read(0, &output));
}

test "a failed cache refill cannot publish partially initialized cache bytes" {
    const FlakyReader = struct {
        bytes: [1024]u8 = @splat(0x73),
        position: usize = 0,
        failed: bool = false,
        fn seekTo(self: *@This(), target: u32) !void {
            self.position = target;
        }
        fn read(self: *@This(), output: []u8) !usize {
            if (self.position >= 7 and !self.failed) {
                self.failed = true;
                return error.ReadFailed;
            }
            const count = @min(output.len, 7, self.bytes.len - self.position);
            @memcpy(output[0..count], self.bytes[self.position..][0..count]);
            self.position += count;
            return count;
        }
    };
    var reader = FlakyReader{};
    var cache: [512]u8 = @splat(0xa5);
    var source = try Source(FlakyReader).init(&reader, reader.bytes.len, &cache);
    var output: [16]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, source.read(0, &output));
    try source.read(0, &output);
    try std.testing.expectEqualSlices(u8, reader.bytes[0..output.len], &output);
}
