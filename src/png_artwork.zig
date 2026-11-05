//! PNG scanlines to the cached RGB565 cover tile. Adam7 passes contribute each
//! source pixel once; no full-size image or deinterlacing canvas is allocated.
const std = @import("std");
const c = @import("c_spng");
const Pool = @import("codec_pool.zig").Pool;
const Tile = @import("artwork_tile.zig").Tile;
const edge = @import("artwork_tile.zig").edge;

comptime {
    if (@import("builtin").os.tag == .freestanding) _ = @import("text/runtime.zig");
}

const maximum_dimension = 4096;
const chunk_limit = 256 * 1024;
const chunk_count_limit = 1024;
const pixel_bytes = 4;
const adam7_start = [_]u8{ 0, 4, 0, 2, 0, 1, 0 };
const adam7_stride = [_]u8{ 8, 8, 4, 4, 2, 2, 1 };

// Artwork has one storage owner and runs only after audio workers have joined.
// Its bounded pool is independent of the codec's active allocation binding.
var active: ?*Pool = null;

export fn gain_art_malloc(bytes: usize) ?*anyopaque {
    return if (active) |pool| pool.allocate(bytes) else null;
}

export fn gain_art_calloc(count: usize, bytes: usize) ?*anyopaque {
    const total = std.math.mul(usize, count, bytes) catch return null;
    const pointer = gain_art_malloc(total) orelse return null;
    @memset(@as([*]u8, @ptrCast(pointer))[0..total], 0);
    return pointer;
}

export fn gain_art_realloc(pointer: ?*anyopaque, bytes: usize) ?*anyopaque {
    return if (active) |pool| pool.resize(pointer, bytes) else null;
}

export fn gain_art_free(pointer: ?*anyopaque) void {
    if (active) |pool| pool.release(pointer) else std.debug.assert(pointer == null);
}

fn checked(result: c_int) !void {
    if (result != 0) {
        if (result == c.SPNG_EMEM) return error.ArtworkMemory;
        if (active) |pool| if (pool.statistics.failures != 0) return error.ArtworkMemory;
    }
    if (result != 0) return error.BadArtwork;
}

fn validateChunks(source: anytype, offset: u64, length: u32, observer: anytype) !void {
    var at: u64 = offset + 8;
    const end = offset + length;
    for (0..chunk_count_limit) |_| {
        if (observer.cancelled()) return error.Cancelled;
        if (at > end or end - at < 12) return error.Truncated;
        var header: [8]u8 = undefined;
        try source.read(at, &header);
        const size = std.mem.readInt(u32, header[0..4], .big);
        if (size > end - at - 12) return error.Truncated;
        at += 12 + @as(u64, size);
        if (std.mem.eql(u8, header[4..8], "IEND")) return;
    }
    return error.ArtworkLimit;
}

pub fn decode(source: anytype, offset: u64, length: u32, sums: []u32, scratch: []u8, tile: *Tile, observer: anytype) !void {
    const sum_words = edge * edge * 4;
    if (length < 8 or sums.len < sum_words or offset > source.length or length > source.length - offset or !@import("buffer_regions.zig").disjoint(&.{ std.mem.sliceAsBytes(sums), scratch, std.mem.asBytes(tile) })) return error.InvalidArtwork;
    try validateChunks(source, offset, length, observer);
    if (active != null) return error.ArtworkBusy;
    const start = std.mem.alignForward(usize, @intFromPtr(scratch.ptr), 16) - @intFromPtr(scratch.ptr);
    if (start > scratch.len) return error.ArtworkMemory;
    var pool = Pool.init(@alignCast(scratch[start..])) catch return error.ArtworkMemory;
    active = &pool;
    defer active = null;

    var allocator = c.spng_alloc{
        .malloc_fn = gain_art_malloc,
        .calloc_fn = gain_art_calloc,
        .realloc_fn = gain_art_realloc,
        .free_fn = gain_art_free,
    };
    const context = c.spng_ctx_new2(&allocator, 0) orelse return error.ArtworkMemory;
    defer c.spng_ctx_free(context);

    const Feed = struct {
        source: @TypeOf(source),
        observer: @TypeOf(observer),
        offset: u64,
        remaining: u32,
        failure: ?anyerror = null,

        fn read(_: ?*c.spng_ctx, user: ?*anyopaque, destination: ?*anyopaque, count: usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(user));
            if (self.observer.cancelled()) {
                self.failure = error.Cancelled;
                return c.SPNG_IO_ERROR;
            }
            if (count > self.remaining) {
                self.failure = error.Truncated;
                return c.SPNG_IO_EOF;
            }
            const out = @as([*]u8, @ptrCast(destination))[0..count];
            self.source.read(self.offset, out) catch |failure| {
                self.failure = failure;
                return c.SPNG_IO_ERROR;
            };
            self.offset += count;
            self.remaining -= @intCast(count);
            return 0;
        }
    };
    var feed = Feed{ .source = source, .observer = observer, .offset = offset, .remaining = length };
    try checked(c.spng_set_png_stream(context, Feed.read, &feed));
    try checked(c.spng_set_image_limits(context, maximum_dimension, maximum_dimension));
    // libspng requires cache_limit >= chunk_size. These limits bound retained
    // and decompressed ancillary data; IDAT pixels are streamed into rows.
    try checked(c.spng_set_chunk_limits(context, chunk_limit, chunk_limit));
    try checked(c.spng_set_crc_action(context, c.SPNG_CRC_ERROR, c.SPNG_CRC_ERROR));
    var header: c.spng_ihdr = undefined;
    checked(c.spng_get_ihdr(context, &header)) catch |failure| return feed.failure orelse failure;
    if (header.width == 0 or header.height == 0 or header.width > maximum_dimension or header.height > maximum_dimension) return error.ArtworkDimensions;

    tile.* = .{};
    const maximum = @min(edge, @max(header.width, header.height));
    tile.width = @intCast(if (header.width >= header.height) maximum else @max(1, header.width * maximum / header.height));
    tile.height = @intCast(if (header.height >= header.width) maximum else @max(1, header.height * maximum / header.width));
    tile.x = (edge - tile.width) / 2;
    tile.y = (edge - tile.height) / 2;
    @memset(sums[0..sum_words], 0);
    const row_bytes = @as(usize, header.width) * pixel_bytes;
    const row_pointer = pool.allocate(row_bytes) orelse return error.ArtworkMemory;
    defer pool.release(row_pointer);
    const row = @as([*]u8, @ptrCast(row_pointer))[0..row_bytes];
    checked(c.spng_decode_image(context, null, 0, c.SPNG_FMT_RGBA8, c.SPNG_DECODE_PROGRESSIVE | c.SPNG_DECODE_TRNS | c.SPNG_DECODE_GAMMA)) catch |failure| return feed.failure orelse failure;

    while (true) {
        if (observer.cancelled()) return error.Cancelled;
        var information: c.spng_row_info = undefined;
        try checked(c.spng_get_row_info(context, &information));
        if (information.row_num >= header.height or information.pass < 0 or information.pass > 6) return error.BadArtwork;
        const result = c.spng_decode_scanline(context, row.ptr, row.len);
        if (result != c.SPNG_EOI) checked(result) catch |failure| return feed.failure orelse failure;
        const pass: usize = @intCast(information.pass);
        const first: u32 = if (header.interlace_method == 0) 0 else adam7_start[pass];
        const stride: u32 = if (header.interlace_method == 0) 1 else adam7_stride[pass];
        var x = first;
        var index: usize = 0;
        const y = information.row_num * tile.height / header.height + tile.y;
        while (x < header.width) : ({
            x += stride;
            index += pixel_bytes;
        }) {
            const target = (y * edge + x * tile.width / header.width + tile.x) * 4;
            const alpha: u32 = row[index + 3];
            // RGB565 atlas entries have no alpha. Use a stable white matte,
            // independent of the UI theme, before averaging source pixels.
            inline for (0..3) |channel| {
                const value: u32 = row[index + channel];
                sums[target + channel] += if (alpha == 255) value else (value * alpha + 255 * (255 - alpha) + 127) / 255;
            }
            sums[target + 3] += 1;
        }
        if (result == c.SPNG_EOI) break;
    }
    checked(c.spng_decode_chunks(context)) catch |failure| return feed.failure orelse failure;
    for (0..edge * edge) |i| {
        const n = sums[i * 4 + 3];
        if (n == 0) continue;
        const r = sums[i * 4] / n;
        const g = sums[i * 4 + 1] / n;
        const b = sums[i * 4 + 2] / n;
        tile.pixels[i] = @intCast(((r * 31 + 127) / 255) << 11 | ((g * 63 + 127) / 255) << 5 | (b * 31 + 127) / 255);
    }
}
