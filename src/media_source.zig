//! Cached random access over a bounded sequential reader. Small container table
//! lookups retain up to four working sets in a caller-owned cache instead of
//! evicting audio data whenever a sample table lives elsewhere in the file.
const std = @import("std");

pub fn Source(comptime Reader: type) type {
    return struct {
        const Self = @This();
        const Window = struct { start: u64 = 0, bytes: usize = 0, used: u32 = 0 };
        reader: *Reader,
        length: u64,
        cache: []u8,
        windows: [4]Window = @splat(.{}),
        clock: u32 = 0,
        ways: u3,
        window_bytes: usize,
        position: u64 = 0,

        pub fn init(reader: *Reader, length: u64, cache: []u8) !Self {
            if (cache.len < 512) return error.InvalidCache;
            if (length > std.math.maxInt(u32)) return error.FileTooLarge;
            try reader.seekTo(0);
            const ways: u3 = if (cache.len >= 2048) 4 else if (cache.len >= 1024) 2 else 1;
            return .{ .reader = reader, .length = length, .cache = cache, .ways = ways, .window_bytes = (cache.len / ways) & ~@as(usize, 511) };
        }

        pub fn read(self: *Self, offset: u64, output: []u8) !void {
            if (offset > self.length or output.len > self.length - offset) return error.Truncated;
            var done: usize = 0;
            while (done < output.len) {
                const at = offset + done;
                var hit = false;
                for (self.windows[0..self.ways], 0..) |window, way| {
                    if (at >= window.start and at - window.start < window.bytes) {
                        const start: usize = @intCast(at - window.start);
                        const count = @min(output.len - done, window.bytes - start);
                        @memcpy(output[done..][0..count], self.cache[way * self.window_bytes + start ..][0..count]);
                        self.clock +%= 1;
                        self.windows[way].used = self.clock;
                        done += count;
                        hit = true;
                        break;
                    }
                }
                if (hit) continue;
                if (output.len - done >= self.window_bytes) {
                    try self.exact(at, output[done..]);
                    return;
                }
                // MP4 alternates tiny sample-table reads with packet payloads.
                // Retain table and packet working sets in the existing allocation.
                var way: usize = 0;
                for (self.windows[0..self.ways], 0..) |window, i| {
                    if (window.bytes == 0) {
                        way = i;
                        break;
                    }
                    if (self.clock -% window.used > self.clock -% self.windows[way].used) way = i;
                }
                const start = at & ~@as(u64, 511);
                const count: usize = @intCast(@min(self.window_bytes, self.length - start));
                self.windows[way].bytes = 0;
                try self.exact(start, self.cache[@as(usize, way) * self.window_bytes ..][0..count]);
                self.clock +%= 1;
                self.windows[way] = .{ .start = start, .bytes = count, .used = self.clock };
            }
        }

        fn exact(self: *Self, offset: u64, output: []u8) !void {
            if (offset != self.position) self.reader.seekTo(@intCast(offset)) catch |failure| switch (@as(anyerror, failure)) {
                error.SeekBounds, error.InvalidSeek => return error.Truncated,
                else => return failure,
            };
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

test "MP4 table and payload alternation preserves both working sets and avoids PCM starvation" {
    const pcm = @import("pcm_reservoir.zig");
    const Model = struct {
        bytes: [256 * 1024]u8 = undefined,
        storage: [48000]pcm.StereoFrame = undefined,
        cache: [64 * 1024]u8 = undefined,
        decoded: [1024]pcm.StereoFrame = @splat(.{ .left = 1, .right = 2 }),
        ring: pcm.Ring = undefined,
        lost: u32 = 0,
        remainder: u64 = 0,
        reads: u32 = 0,
        seeks: u32 = 0,

        const ModelType = @This();
        const Reader = struct {
            model: *ModelType,
            position: u32 = 0,

            pub fn seekTo(self: *@This(), position: u32) !void {
                if (position != self.position) {
                    self.model.seeks += 1;
                    self.model.advance(8000);
                }
                self.position = position;
            }

            pub fn read(self: *@This(), output: []u8) !usize {
                const count = @min(output.len, self.model.bytes.len - self.position);
                @memcpy(output[0..count], self.model.bytes[self.position..][0..count]);
                self.position += @intCast(count);
                self.model.reads += 1;
                self.model.advance(500 + @as(u64, count) * 1_000_000 / (8 * 1024 * 1024));
                return count;
            }
        };

        fn advance(self: *@This(), microseconds: u64) void {
            const numerator = self.remainder + microseconds * 48;
            self.remainder = numerator % 1000;
            for (0..numerator / 1000) |_| if (self.ring.pop() == null) {
                self.lost += 1;
            };
        }

        fn run(self: *@This(), ways: u3) !void {
            self.lost = 0;
            self.reads = 0;
            self.seeks = 0;
            self.remainder = 0;
            @memset(&self.storage, .{ .left = 1, .right = 2 });
            self.ring = try pcm.Ring.initFilled(&self.storage, 4800);
            var reader = Reader{ .model = self };
            var source = try Source(Reader).init(&reader, self.bytes.len, &self.cache);
            source.ways = ways;
            source.window_bytes = source.cache.len / ways;
            for (0..20) |i| {
                var table: [4]u8 = undefined;
                var packet: [256]u8 = undefined;
                try source.read(128 * 1024 + i * 4, &table);
                try source.read(192 * 1024 + i * 4, &table);
                try source.read(224 * 1024 + i * 4, &table);
                try source.read(4096 + i * 256, &packet);
                try std.testing.expectEqualSlices(u8, self.bytes[4096 + i * 256 ..][0..256], &packet);
                self.advance(4000);
                try std.testing.expectEqual(self.decoded.len, self.ring.write(&self.decoded));
            }
        }
    };

    const model = try std.testing.allocator.create(Model);
    defer std.testing.allocator.destroy(model);
    for (&model.bytes, 0..) |*byte, i| byte.* = @truncate(i *% 19);
    try model.run(1);
    const old_reads = model.reads;
    try std.testing.expect(model.lost > 0);
    try model.run(2);
    try std.testing.expect(model.lost > 0);
    try model.run(4);
    try std.testing.expectEqual(@as(u32, 0), model.lost);
    try std.testing.expect(model.reads * 10 < old_reads);
}
