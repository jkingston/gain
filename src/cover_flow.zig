//! Shared Cover Flow geometry and RGB565 rasterizer for F20 and desktop.
//! Seven prepared covers, bounded column scratch, no allocation or media I/O.
const std = @import("std");

pub const source_edge = @import("artwork_tile.zig").edge;
pub const texture_edge = 128;
pub const background: u16 = rgb(247, 247, 242);
pub const Quad = struct {
    left: f32,
    right: f32,
    top_left: f32,
    top_right: f32,
    bottom_left: f32,
    bottom_right: f32,
    reciprocal_left: f32 = 1,
    reciprocal_right: f32 = 1,
    reflection: u8 = 0,
};
pub const Texture = struct {
    pixels: []const u16,
    x: usize = 0,
    y: usize = 0,
    width: usize = source_edge,
    height: usize = source_edge,
};
pub const Prepared = struct {
    // Column-major: the perspective rasterizer walks vertical columns. Keeping
    // neighbouring source rows adjacent avoids 128-pixel stride cache conflicts.
    pixels: [texture_edge * texture_edge]u16 = @splat(0),
    x: usize = 0,
    y: usize = 0,
    width: usize = 0,
    height: usize = 0,
};

/// Filter once when the storage/host owner loads artwork, never during motion.
const Uninterrupted = struct {
    pub fn cancelled(_: @This()) bool {
        return false;
    }
};

pub fn prepare(texture: Texture, output: *Prepared) void {
    _ = prepareCooperative(texture, output, Uninterrupted{});
}

pub fn prepareCooperative(texture: Texture, output: *Prepared, observer: anytype) bool {
    output.* = .{};
    if (texture.pixels.len < source_edge * source_edge or texture.width == 0 or texture.height == 0 or texture.x >= source_edge or texture.y >= source_edge or texture.width > source_edge - texture.x or texture.height > source_edge - texture.y) return true;
    output.x = (texture.x * texture_edge + source_edge - 1) / source_edge;
    output.y = (texture.y * texture_edge + source_edge - 1) / source_edge;
    const end_x = (texture.x + texture.width) * texture_edge / source_edge;
    const end_y = (texture.y + texture.height) * texture_edge / source_edge;
    output.width = end_x - output.x;
    output.height = end_y - output.y;
    for (output.x..end_x) |x| {
        if ((x - output.x) % 4 == 0 and observer.cancelled()) {
            output.width = 0;
            output.height = 0;
            return false;
        }
        for (output.y..end_y) |y| {
            const fx: u32 = @intCast(@max(0, @as(i32, @intCast((x * 2 + 1) * source_edge * 32768 / texture_edge)) - 32768));
            const fy: u32 = @intCast(@max(0, @as(i32, @intCast((y * 2 + 1) * source_edge * 32768 / texture_edge)) - 32768));
            const sx = std.math.clamp(fx >> 16, texture.x, texture.x + texture.width - 1);
            const sy = std.math.clamp(fy >> 16, texture.y, texture.y + texture.height - 1);
            const nx = @min(sx + 1, texture.x + texture.width - 1);
            const ny = @min(sy + 1, texture.y + texture.height - 1);
            const a = mix(texture.pixels[sy * source_edge + sx], texture.pixels[sy * source_edge + nx], (fx >> 11) & 31);
            const b = mix(texture.pixels[ny * source_edge + sx], texture.pixels[ny * source_edge + nx], (fx >> 11) & 31);
            output.pixels[x * texture_edge + y] = mix(a, b, (fy >> 11) & 31);
        }
    }
    return true;
}

pub const Surface = struct { pixels: []u16, width: usize = 320, height: usize = 240, origin_x: usize = 0, origin_y: usize = 0 };

pub fn project(distance: f32) Quad {
    const magnitude = @min(3.5, @abs(distance));
    const turn = @min(1, magnitude);
    const stack = @max(0, magnitude - 1);
    const direction: f32 = if (distance < 0) -1 else 1;
    const size: f32 = 128;
    // Side sleeves have a tall outer edge and a receding inner edge. Their
    // screen-space translation stays independent of the local perspective.
    const yaw = -direction * turn * (68.0 * std.math.pi / 180.0);
    const depth = turn * 60 + stack * 12;
    const center_x = 160 + direction * (turn * 84 + stack * 28);
    const center_y: f32 = 102;
    const focal: f32 = 380;
    const half_width = size / 2 * @cos(yaw);
    const half_depth = size / 2 * @sin(yaw);
    const left_scale = focal / (focal + depth - half_depth);
    const right_scale = focal / (focal + depth + half_depth);
    return .{
        .left = center_x - half_width * left_scale,
        .right = center_x + half_width * right_scale,
        .top_left = center_y - size / 2 * left_scale,
        .top_right = center_y - size / 2 * right_scale,
        .bottom_left = center_y + size / 2 * left_scale,
        .bottom_right = center_y + size / 2 * right_scale,
        .reciprocal_left = left_scale,
        .reciprocal_right = right_scale,
        .reflection = 22,
    };
}

fn rgb(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | (b >> 3);
}

/// RGB565 channels have 5/6 bits. Five-bit interpolation weights retain that
/// precision with one packed-channel multiplication and no division.
pub inline fn mix(a: u16, b: u16, weight: u32) u16 {
    std.debug.assert(weight <= 32);
    // Five guard bits between packed components let one wrapping multiply
    // interpolate all channels; the final mask discards inter-channel borrow.
    const mask: u32 = 0x07e0f81f;
    const first = (@as(u32, a) | (@as(u32, a) << 16)) & mask;
    const second = (@as(u32, b) | (@as(u32, b) << 16)) & mask;
    const rounded = (first +% (((second -% first) *% weight +% 0x02008010) >> 5)) & mask;
    return @truncate(rounded | (rounded >> 16));
}

const missing: Prepared = blk: {
    @setEvalBranchQuota(100000);
    var tile: Prepared = .{ .width = texture_edge, .height = texture_edge };
    for (0..texture_edge) |y| for (0..texture_edge) |x| {
        const dx = @as(i32, @intCast(x)) - 64;
        const dy = @as(i32, @intCast(y)) - 64;
        const radius = dx * dx + dy * dy;
        tile.pixels[x * texture_edge + y] = if ((radius >= 1200 and radius <= 1369) or (radius >= 36 and radius <= 64)) rgb(197, 207, 200) else rgb(228, 232, 226);
    };
    break :blk tile;
};

fn pixel(surface: Surface, x: usize, y: usize, color: u16, opacity: u32) void {
    if (opacity == 0 or x < surface.origin_x or y < surface.origin_y or x >= surface.origin_x + surface.width or y >= surface.origin_y + surface.height) return;
    const at = (y - surface.origin_y) * surface.width + x - surface.origin_x;
    surface.pixels[at] = if (opacity >= 32) color else mix(surface.pixels[at], color, opacity);
}

pub const Card = struct { texture: ?*const Prepared, quad: Quad };

pub fn paintScene(surface: Surface, cards: []const Card) void {
    for (cards, 0..) |card, i| paintColumns(surface, card.texture, card.quad, cards[i + 1 ..]);
}

/// Paint a single prepared cover. No allocation, storage access or DMA changes.
pub fn paint(surface: Surface, texture: ?*const Prepared, quad: Quad) void {
    paintColumns(surface, texture, quad, &.{});
}

fn paintColumns(surface: Surface, texture: ?*const Prepared, quad: Quad, occluders: []const Card) void {
    std.debug.assert(surface.pixels.len == surface.width * surface.height);
    const left: usize = @intFromFloat(std.math.clamp(@floor(quad.left), @as(f32, @floatFromInt(surface.origin_x)), @as(f32, @floatFromInt(surface.origin_x + surface.width))));
    const right: usize = @intFromFloat(std.math.clamp(@ceil(quad.right), @as(f32, @floatFromInt(surface.origin_x)), @as(f32, @floatFromInt(surface.origin_x + surface.width))));
    if (right <= left or quad.right <= quad.left) return;
    const candidate = texture orelse &missing;
    const tile = if (candidate.width > 0 and candidate.height > 0 and candidate.x < texture_edge and candidate.y < texture_edge and candidate.width <= texture_edge - candidate.x and candidate.height <= texture_edge - candidate.y) candidate else &missing;
    var reflection_opacity: [256]u8 = undefined;
    if (quad.reflection > 0) for (0..quad.reflection) |row| {
        const remaining: u32 = quad.reflection - @as(u32, @intCast(row));
        reflection_opacity[row] = @intCast(remaining * remaining * 8 / (@as(u32, quad.reflection) * quad.reflection));
    };
    for (left..right) |x| {
        const t = std.math.clamp((@as(f32, @floatFromInt(x)) + 0.5 - quad.left) / (quad.right - quad.left), 0, 1);
        const reciprocal = quad.reciprocal_left * (1 - t) + quad.reciprocal_right * t;
        const u = t * quad.reciprocal_right / reciprocal;
        const source_x: u32 = @intFromFloat(std.math.clamp(u * texture_edge - 0.5, 0, texture_edge - 1) * 65536);
        const sx: usize = source_x >> 16;
        if (sx < tile.x or sx >= tile.x + tile.width) continue;
        const source_first = tile.y;
        const source_end = tile.y + tile.height;
        const x_coverage: u32 = @intFromFloat(std.math.clamp(@min(@as(f32, @floatFromInt(x + 1)) - quad.left, quad.right - @as(f32, @floatFromInt(x))), 0, 1) * 32);
        const top = quad.top_left + (quad.top_right - quad.top_left) * t;
        const bottom = quad.bottom_left + (quad.bottom_right - quad.bottom_left) * t;
        const height = bottom - top;
        if (height <= 0) continue;
        const first: usize = @intFromFloat(std.math.clamp(@floor(top), @as(f32, @floatFromInt(surface.origin_y)), @as(f32, @floatFromInt(surface.origin_y + surface.height))));
        const end: usize = @intFromFloat(std.math.clamp(@ceil(bottom), @as(f32, @floatFromInt(surface.origin_y)), @as(f32, @floatFromInt(surface.origin_y + surface.height))));
        const step: u32 = @intFromFloat(texture_edge * 65536 / height);
        var sy_fixed: u32 = @intFromFloat(@max(0, (@as(f32, @floatFromInt(first)) + 0.5 - top) * texture_edge / height - 0.5) * 65536);
        var hidden = false;
        // Only fully opaque bodies can hide a column, including both AA
        // boundary pixels. Rectangular artwork conservatively skips culling.
        for (occluders) |near| {
            if (near.texture) |art| if (art.width > 0 and (art.x != 0 or art.y != 0 or art.width != texture_edge or art.height != texture_edge)) continue;
            const q = near.quad;
            const screen_x: f32 = @floatFromInt(x);
            if (q.left > screen_x or q.right < screen_x + 1) continue;
            const across = (screen_x + 0.5 - q.left) / (q.right - q.left);
            const near_top = q.top_left + (q.top_right - q.top_left) * across;
            const near_bottom = q.bottom_left + (q.bottom_right - q.bottom_left) * across;
            if (near_top <= @floor(top) and near_bottom >= @ceil(bottom)) {
                hidden = true;
                break;
            }
        }
        var destination = (first - surface.origin_y) * surface.width + x - surface.origin_x;
        for (first..if (hidden) first else end) |y| {
            const at = destination;
            destination += surface.width;
            const sy: usize = @min(texture_edge - 1, sy_fixed >> 16);
            const weight = (sy_fixed >> 11) & 31;
            sy_fixed +|= step;
            if (sy < source_first or sy >= source_end) continue;
            const ny = @min(sy + 1, source_end - 1);
            const first_color = tile.pixels[sx * texture_edge + sy];
            const color = if (weight == 0) first_color else mix(first_color, tile.pixels[sx * texture_edge + ny], weight);
            // Fractional coverage belongs only to the two boundary pixels;
            // the interior has no floating-point work or destination read.
            if (y == first or y + 1 == end) {
                const edge = std.math.clamp(@min(@as(f32, @floatFromInt(y + 1)) - top, bottom - @as(f32, @floatFromInt(y))), 0, 1);
                pixel(surface, x, y, color, @intFromFloat(edge * @as(f32, @floatFromInt(x_coverage))));
            } else if (x_coverage == 32) surface.pixels[at] = color else pixel(surface, x, y, color, x_coverage);
        }
        const reflection_top: usize = @intFromFloat(@max(0, @ceil(bottom) + 1));
        var reflection_source: u32 = (texture_edge - 1) << 16;
        for (0..quad.reflection) |row| {
            const y = reflection_top + row;
            if (y >= surface.origin_y + surface.height) break;
            const sy: usize = reflection_source >> 16;
            reflection_source -|= step;
            if (sy < source_first or sy >= source_end) continue;
            const opacity: u32 = reflection_opacity[row];
            pixel(surface, x, y, tile.pixels[sx * texture_edge + sy], opacity * x_coverage / 32);
        }
    }
}

test "classic geometry mirrors, remains finite and fits above the caption" {
    for (0..701) |i| {
        const distance = @as(f32, @floatFromInt(i)) / 100 - 3.5;
        const q = project(distance);
        const opposite = project(-distance);
        try std.testing.expect(q.right > q.left);
        try std.testing.expect(q.top_left >= 32 and q.top_right >= 32);
        try std.testing.expect(q.bottom_left + q.reflection + 2 < 194 and q.bottom_right + q.reflection + 2 < 194);
        try std.testing.expectApproxEqAbs(320 - q.left, opposite.right, 0.001);
        try std.testing.expectApproxEqAbs(q.top_left, opposite.top_right, 0.001);
    }
    const center = project(0);
    try std.testing.expectEqual(@as(f32, 128), center.right - center.left);
    const side = project(-1);
    try std.testing.expect(side.bottom_left - side.top_left > side.bottom_right - side.top_right);
}

test "packed interpolation preserves endpoints and every solid RGB565 value" {
    for (0..65536) |value| {
        const color: u16 = @intCast(value);
        for (0..33) |weight| try std.testing.expectEqual(color, mix(color, color, @intCast(weight)));
        try std.testing.expectEqual(color, mix(color, ~color, 0));
        try std.testing.expectEqual(~color, mix(color, ~color, 32));
    }
}

test "real textures, missing covers and rectangular padding survive motion and clipping" {
    var pixels: [320 * 240]u16 = undefined;
    var source: [source_edge * source_edge]u16 = undefined;
    for (&source, 0..) |*color, i| color.* = @truncate(i * 197);
    var tile: Prepared = undefined;
    prepare(.{ .pixels = &source }, &tile);
    var rectangular: Prepared = undefined;
    prepare(.{ .pixels = &source, .y = 24, .height = 64 }, &rectangular);
    for (0..71) |phase| {
        @memset(&pixels, background);
        const distance = @as(f32, @floatFromInt(phase)) / 10 - 3.5;
        paint(.{ .pixels = &pixels }, &tile, project(distance));
        paint(.{ .pixels = &pixels }, null, project(-distance));
        paint(.{ .pixels = &pixels }, &rectangular, project(distance));
        for (pixels[194 * 320 ..]) |color| try std.testing.expectEqual(background, color);
    }
}

test "prepared columns preserve artwork orientation and paint pixel-exactly at rest" {
    var source: [source_edge * source_edge]u16 = undefined;
    for (0..source_edge) |y| {
        for (0..source_edge) |x| source[y * source_edge + x] = rgb(@intCast(x * 255 / (source_edge - 1)), @intCast(y * 255 / (source_edge - 1)), 0);
    }
    var tile: Prepared = undefined;
    prepare(.{ .pixels = &source }, &tile);
    try std.testing.expectEqual(rgb(0, 0, 0), tile.pixels[0]);
    try std.testing.expectEqual(rgb(255, 0, 0), tile.pixels[(texture_edge - 1) * texture_edge]);
    try std.testing.expectEqual(rgb(0, 255, 0), tile.pixels[texture_edge - 1]);
    var canvas: [320 * 240]u16 = @splat(background);
    paint(.{ .pixels = &canvas }, &tile, project(0));
    for (0..texture_edge) |y| for (0..texture_edge) |x| try std.testing.expectEqual(tile.pixels[x * texture_edge + y], canvas[(y + 38) * 320 + x + 96]);
}

test "single multiply interpolation matches independent rounded channel arithmetic" {
    var random: u64 = 23;
    for (0..200000) |_| {
        random = random *% 6364136223846793005 +% 1;
        const a: u16 = @truncate(random >> 16);
        const b: u16 = @truncate(random >> 32);
        const weight: u32 = @intCast((random >> 48) % 33);
        const inv = 32 - weight;
        const red = ((@as(u32, a >> 11) * inv + @as(u32, b >> 11) * weight + 16) >> 5) << 11;
        const green = ((@as(u32, (a >> 5) & 63) * inv + @as(u32, (b >> 5) & 63) * weight + 16) >> 5) << 5;
        const blue = (@as(u32, a & 31) * inv + @as(u32, b & 31) * weight + 16) >> 5;
        try std.testing.expectEqual(@as(u16, @intCast(red | green | blue)), mix(a, b, weight));
    }
}

test "hidden-column culling exactly preserves the full scene, reflection and rectangular artwork" {
    var source: [source_edge * source_edge]u16 = undefined;
    for (&source, 0..) |*color, i| color.* = @truncate(i * 197);
    var square: Prepared = undefined;
    var rectangle: Prepared = undefined;
    prepare(.{ .pixels = &source }, &square);
    prepare(.{ .pixels = &source, .y = 24, .height = 64 }, &rectangle);
    var reference: [320 * 240]u16 = undefined;
    var culled: [320 * 240]u16 = undefined;
    for (0..41) |phase| {
        const position = @as(f32, @floatFromInt(phase)) / 40;
        const anchor = @round(position);
        var cards: [7]Card = undefined;
        for ([_]i32{ -3, 3, -2, 2, -1, 1, 0 }, 0..) |offset, i| cards[i] = .{
            .quad = project(anchor + @as(f32, @floatFromInt(offset)) - position),
            .texture = if (i == 0) null else if (i == 3) &rectangle else &square,
        };
        @memset(&reference, background);
        @memset(&culled, background);
        for (cards) |card| paint(.{ .pixels = &reference }, card.texture, card.quad);
        paintScene(.{ .pixels = &culled }, &cards);
        try std.testing.expectEqualSlices(u16, &reference, &culled);
    }
}

test "cooperative preparation has identical pixels and invalidates a cancelled partial tile" {
    var source: [source_edge * source_edge]u16 = undefined;
    for (&source, 0..) |*color, i| color.* = @truncate(i * 197);
    var expected: Prepared = undefined;
    var actual: Prepared = undefined;
    prepare(.{ .pixels = &source }, &expected);
    const Observer = struct {
        calls: usize = 0,
        cancel_at: usize = 1000,
        pub fn cancelled(self: *@This()) bool {
            self.calls += 1;
            return self.calls >= self.cancel_at;
        }
    };
    var observer: Observer = .{};
    try std.testing.expect(prepareCooperative(.{ .pixels = &source }, &actual, &observer));
    try std.testing.expectEqualSlices(u16, &expected.pixels, &actual.pixels);
    try std.testing.expectEqual(32, observer.calls);
    observer = .{ .cancel_at = 5 };
    try std.testing.expect(!prepareCooperative(.{ .pixels = &source }, &actual, &observer));
    try std.testing.expectEqual(0, actual.width);
    try std.testing.expectEqual(0, actual.height);
}
