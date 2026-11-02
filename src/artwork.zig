//! Streaming baseline JPEG to a bounded RGB565 tile. Upstream owns entropy/
//! IDCT decoding; Zig owns input bounds, aspect ratio and area accumulation.
const std = @import("std");
const c = @import("c_jpeg");

pub const edge = 112;
pub const pixel_count = edge * edge;
pub const sum_words = pixel_count * 4;

pub const Tile = struct { pixels: [pixel_count]u16 = @splat(0), x: u16 = 0, y: u16 = 0, width: u16 = 0, height: u16 = 0 };

pub fn decode(source: anytype, offset: u64, length: u32, sums: []u32, tile: *Tile, observer: anytype) !void {
    if (sums.len < sum_words or offset > source.length or length > source.length - offset) return error.InvalidArtwork;
    const S = @TypeOf(source);

    const Feed = struct {
        source: S,
        offset: u64,
        left: u32,
        failure: ?anyerror = null,

        fn read(buffer: [*c]u8, size: u8, actual: [*c]u8, context: ?*anyopaque) callconv(.c) u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const n = @min(size, self.left);
            actual.* = 0;
            self.source.read(self.offset, buffer[0..n]) catch |err| {
                self.failure = err;
                return 1;
            };
            self.offset += n;
            self.left -= n;
            actual.* = @intCast(n);
            return 0;
        }
    };

    var feed = Feed{ .source = source, .offset = offset, .left = length };
    var info: c.pjpeg_image_info_t = undefined;
    if (c.pjpeg_decode_init(&info, Feed.read, &feed, 0) != 0) return feed.failure orelse error.UnsupportedArtwork;
    if (info.m_width <= 0 or info.m_height <= 0 or info.m_width > 4096 or info.m_height > 4096) return error.ArtworkDimensions;
    const reduced = @min(info.m_width, info.m_height) >= edge * 8;
    if (reduced) {
        feed.offset = offset;
        feed.left = length;
        if (c.pjpeg_decode_init(&info, Feed.read, &feed, 1) != 0) return error.UnsupportedArtwork;
    }
    const divisor: u32 = if (reduced) 8 else 1;
    const width: u32 = (@as(u32, @intCast(info.m_width)) + divisor - 1) / divisor;
    const height: u32 = (@as(u32, @intCast(info.m_height)) + divisor - 1) / divisor;
    tile.* = .{};
    const maximum = @min(edge, @max(width, height));
    tile.width = @intCast(if (width >= height) maximum else @max(1, width * maximum / height));
    tile.height = @intCast(if (height >= width) maximum else @max(1, height * maximum / width));
    tile.x = (edge - tile.width) / 2;
    tile.y = (edge - tile.height) / 2;
    @memset(sums[0..sum_words], 0);
    const mcu_w: u32 = @intCast(info.m_MCUWidth);
    const mcu_h: u32 = @intCast(info.m_MCUHeight);
    for (0..@as(usize, @intCast(info.m_MCUSPerCol))) |my| {
        if (observer.cancelled()) return error.Cancelled;
        for (0..@as(usize, @intCast(info.m_MCUSPerRow))) |mx| {
            if (c.pjpeg_decode_mcu() != 0) return feed.failure orelse error.BadArtwork;
            var py: u32 = 0;
            while (py < mcu_h) : (py += divisor) {
                var px: u32 = 0;
                while (px < mcu_w) : (px += divisor) {
                    const sx: u32 = @intCast((mx * mcu_w + px) / divisor);
                    const sy: u32 = @intCast((my * mcu_h + py) / divisor);
                    if (sx >= width or sy >= height) continue;
                    const at = (py / 8) * 128 + (px / 8) * 64 + (py % 8) * 8 + px % 8;
                    const dx = @min(tile.width - 1, sx * tile.width / width) + tile.x;
                    const dy = @min(tile.height - 1, sy * tile.height / height) + tile.y;
                    const target = (dy * edge + dx) * 4;
                    sums[target] += info.m_pMCUBufR[at];
                    sums[target + 1] += if (info.m_comps == 1) info.m_pMCUBufR[at] else info.m_pMCUBufG[at];
                    sums[target + 2] += if (info.m_comps == 1) info.m_pMCUBufR[at] else info.m_pMCUBufB[at];
                    sums[target + 3] += 1;
                }
            }
        }
    }
    for (0..pixel_count) |i| {
        const n = sums[i * 4 + 3];
        if (n == 0) continue;
        const r = sums[i * 4] / n;
        const g = sums[i * 4 + 1] / n;
        const b = sums[i * 4 + 2] / n;
        tile.pixels[i] = @intCast(((r * 31 + 127) / 255) << 11 | ((g * 63 + 127) / 255) << 5 | (b * 31 + 127) / 255);
    }
}

const TestSource = struct {
    bytes: []const u8,
    length: u64,

    pub fn read(self: *@This(), offset: u64, out: []u8) !void {
        if (offset > self.bytes.len or out.len > self.bytes.len - offset) return error.Truncated;
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
};

const TestObserver = struct {
    cancel: bool = false,

    fn cancelled(self: *@This()) bool {
        return self.cancel;
    }
};

test "JPEG bridge handles MCU sampling modes, reduction, aspect fit and cancellation" {
    const fixtures = [_][]const u8{ @embedFile("testdata/art444.jpg"), @embedFile("testdata/art420.jpg"), @embedFile("testdata/art-reduced.jpg") };
    const sums = try std.testing.allocator.alloc(u32, sum_words);
    defer std.testing.allocator.free(sums);
    var observer: TestObserver = .{};
    for (fixtures, 0..) |bytes, i| {
        var source = TestSource{ .bytes = bytes, .length = bytes.len };
        var tile: Tile = undefined;
        try decode(&source, 0, @intCast(bytes.len), sums, &tile, &observer);
        try std.testing.expectEqual(if (i == 2) @as(u16, 112) else @as(u16, 64), tile.width);
        try std.testing.expectEqual(if (i == 2) @as(u16, 112) else @as(u16, 32), tile.height);
        for (0..edge) |y| for (0..edge) |x| {
            const pixel = tile.pixels[y * edge + x];
            if (x >= tile.x and x < tile.x + tile.width and y >= tile.y and y < tile.y + tile.height) {
                // Synthetic flat red fixture: every output pixel must be filled,
                // including MCU boundaries and the last partial reduced bin.
                try std.testing.expect(pixel >> 11 >= 23 and pixel & 31 <= 11);
            } else try std.testing.expectEqual(0, pixel);
        };
        observer.cancel = true;
        try std.testing.expectError(error.Cancelled, decode(&source, 0, @intCast(bytes.len), sums, &tile, &observer));
        observer.cancel = false;
        source.bytes = bytes[0 .. bytes.len / 2];
        if (decode(&source, 0, @intCast(bytes.len), sums, &tile, &observer)) |_| return error.AcceptedTruncatedArtwork else |_| {}
        try std.testing.expectError(error.InvalidArtwork, decode(&source, bytes.len, 1, sums, &tile, &observer));
    }
}

test "JPEG MCU blocks retain their spatial arrangement and channel order" {
    const bytes = @embedFile("testdata/art-quadrants.jpg");
    var source = TestSource{ .bytes = bytes, .length = bytes.len };
    const sums = try std.testing.allocator.alloc(u32, sum_words);
    defer std.testing.allocator.free(sums);
    var observer: TestObserver = .{};
    var tile: Tile = undefined;
    try decode(&source, 0, bytes.len, sums, &tile, &observer);
    for (0..64) |y| for (0..64) |x| {
        // Exclude JPEG chroma filtering at the quadrant edges.
        if (x % 32 < 2 or x % 32 > 29 or y % 32 < 2 or y % 32 > 29) continue;
        const pixel = tile.pixels[(y + tile.y) * edge + x + tile.x];
        const r = pixel >> 11;
        const g = pixel >> 5 & 63;
        const b = pixel & 31;
        switch (@as(u2, @intFromBool(y >= 32)) * 2 + @intFromBool(x >= 32)) {
            0 => try std.testing.expect(r > 20 and g < 15 and b < 12),
            1 => try std.testing.expect(r < 8 and g > 40 and b < 12),
            2 => try std.testing.expect(r < 8 and g < 20 and b > 20),
            3 => try std.testing.expect(r > 20 and g > 40 and b < 8),
        }
    };
}

test "caller-owned tile and accumulation workspaces preserve their guards" {
    const bytes = @embedFile("testdata/art420.jpg");
    var source = TestSource{ .bytes = bytes, .length = bytes.len };
    var guarded = struct {
        before: [32]u8 = @splat(0xa5),
        tile: Tile = .{},
        after: [32]u8 = @splat(0x5a),
    }{};
    const sums = try std.testing.allocator.alloc(u32, sum_words + 16);
    defer std.testing.allocator.free(sums);
    @memset(sums, 0xdeadbeef);
    var observer: TestObserver = .{};
    try decode(&source, 0, bytes.len, sums[0..sum_words], &guarded.tile, &observer);
    for (guarded.before) |value| try std.testing.expectEqual(0xa5, value);
    for (guarded.after) |value| try std.testing.expectEqual(0x5a, value);
    for (sums[sum_words..]) |value| try std.testing.expectEqual(0xdeadbeef, value);
    try std.testing.expectEqual(64, guarded.tile.width);
}
