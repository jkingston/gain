//! Native RGB565 software drawing, sharing gain's production surface and clipping.
const std = @import("std");
const ui = @import("ui.zig");
pub const fonts = @import("font_data.zig");

pub const Color = ui.Color;
pub const rgb = ui.rgb;
pub const Rect = ui.Rect;

pub const Canvas = struct {
    surface: ui.Surface,
    text_cache: ?*@import("text/cache.zig").Cache = null,

    pub fn init(pixels: *[ui.pixel_count]u16) Canvas {
        return .{ .surface = .{ .pixels = pixels } };
    }

    pub fn clear(self: Canvas, color: Color) void {
        self.surface.clear(color);
    }

    pub fn fill(self: Canvas, x: i32, y: i32, w: u16, h: u16, color: Color) void {
        self.surface.fill(.{ .x = x, .y = y, .width = w, .height = h }, color);
    }

    pub fn pixel(self: Canvas, x: i32, y: i32, color: Color) void {
        self.fill(x, y, 1, 1, color);
    }

    pub fn blendPixel(self: Canvas, x: i32, y: i32, color: Color, alpha: u8) void {
        if (x < 0 or y < 0 or x >= 320 or y >= 240 or alpha == 0) return;
        const clip = self.surface.clip;
        if (x < clip.x or y < clip.y or x >= clip.x + clip.width or y >= clip.y + clip.height) return;
        const index: usize = @intCast(y * 320 + x);
        self.surface.pixels[index] = blend(self.surface.pixels[index], color, alpha);
    }

    pub fn rounded(self: Canvas, x: i32, y: i32, w: u16, h: u16, radius: u16, color: Color) void {
        const r = @min(radius, @min(w, h) / 2);
        var row: u16 = 0;
        while (row < h) : (row += 1) {
            const dy: f32 = if (row < r) @floatFromInt(r - row) else if (row >= h - r) @floatFromInt(row - (h - r) + 1) else 0;
            const rf: f32 = @floatFromInt(r);
            const inset: u16 = if (dy == 0) 0 else @intFromFloat(@ceil(rf - @sqrt(@max(0, rf * rf - dy * dy))));
            self.fill(x + inset, y + row, w - 2 * inset, 1, color);
        }
    }

    pub fn text(self: Canvas, x: i32, y: i32, max_width: u16, value: []const u8, role: fonts.Role, color: Color) void {
        if (self.prepared(x, y, max_width, value, role, color, false, .left)) return;
        var clipped = self;
        const screen_clip = ui.intersection(self.surface.clip, .{ .x = 0, .y = 0, .width = ui.screen_width, .height = ui.screen_height });
        clipped.surface.clip = ui.intersection(screen_clip, .{ .x = x, .y = y, .width = max_width, .height = 48 });
        var iter = std.unicode.Utf8View.init(value) catch return;
        var it = iter.iterator();
        var cursor = x;
        while (it.nextCodepoint()) |code| {
            const g = fonts.glyph(role, code);
            if (cursor >= x + max_width) break;
            const ink_x = cursor + g.ink_x;
            const ink_y = y + g.ink_y;
            const bounds = ui.intersection(clipped.surface.clip, .{ .x = ink_x, .y = ink_y, .width = g.ink_width, .height = g.ink_height });
            if (bounds.width > 0 and bounds.height > 0) {
                // Clip once per glyph. Interior mask samples already have valid
                // canvas/clip coordinates, so no per-pixel rectangle tests recur.
                const width: usize = @intCast(bounds.width);
                const left: usize = @intCast(bounds.x - ink_x);
                var mask_at = @as(usize, g.offset) + @as(usize, @intCast(bounds.y - ink_y)) * g.ink_width + left;
                var destination: usize = @intCast(bounds.y * ui.screen_width + bounds.x);
                for (0..@intCast(bounds.height)) |_| {
                    const masks = fonts.masks[mask_at..][0..width];
                    const row = clipped.surface.pixels[destination..][0..width];
                    for (masks, row) |alpha, *destination_pixel| {
                        if (alpha == 0) continue;
                        destination_pixel.* = if (alpha == 255) color else blend(destination_pixel.*, color, alpha);
                    }
                    mask_at += g.ink_width;
                    destination += ui.screen_width;
                }
            }
            cursor += g.advance;
        }
    }

    pub fn ellipsis(self: Canvas, x: i32, y: i32, width: u16, value: []const u8, role: fonts.Role, color: Color) void {
        if (self.prepared(x, y, width, value, role, color, true, .left)) return;
        var fallback = self;
        fallback.text_cache = null;
        fallback.embeddedEllipsis(x, y, width, value, role, color);
    }

    fn embeddedEllipsis(self: Canvas, x: i32, y: i32, width: u16, value: []const u8, role: fonts.Role, color: Color) void {
        const view = std.unicode.Utf8View.init(value) catch return;
        var iterator = view.iterator();
        const tail = textWidth("…", role);
        var cursor: u32 = 0;
        var extent: u32 = 0;
        var prefix: usize = 0;
        while (iterator.nextCodepoint()) |code| {
            const glyph = fonts.glyph(role, code);
            extent = @max(extent, cursor + glyph.width - 1);
            cursor += glyph.advance;
            const measured = @max(extent, cursor);
            if (measured > width) {
                if (width < tail) return;
                self.text(x, y, width, value[0..prefix], role, color);
                self.text(x + textWidth(value[0..prefix], role), y, tail + 1, "…", role, color);
                return;
            }
            if (measured + tail <= width) prefix = iterator.i;
        }
        self.text(x, y, width, value, role, color);
    }

    pub fn right(self: Canvas, right_x: i32, y: i32, value: []const u8, role: fonts.Role, color: Color) void {
        if (self.prepared(right_x - 320, y, 320, value, role, color, true, .right)) return;
        const width = textWidth(value, role);
        self.text(right_x - width, y, width + 1, value, role, color);
    }

    pub fn centered(self: Canvas, x: i32, y: i32, width: u16, value: []const u8, role: fonts.Role, color: Color) void {
        if (self.prepared(x, y, width, value, role, color, true, .center)) return;
        const measured = @min(width, textWidth(value, role));
        var fallback = self;
        fallback.text_cache = null;
        fallback.ellipsis(x + @divTrunc(@as(i32, width) - measured, 2), y, measured, value, role, color);
    }

    const Alignment = enum { left, center, right };
    fn prepared(self: Canvas, x: i32, y: i32, width: u16, value: []const u8, role: fonts.Role, color: Color, ellipsize: bool, alignment: Alignment) bool {
        const cache = self.text_cache orelse return false;
        if (!@import("text/cache.zig").needsEngine(value)) return false;
        const label = cache.lookup(value, role, width, ellipsize) orelse return false;
        const left = x + switch (alignment) {
            .left => @as(i32, 0),
            .center => @divTrunc(@as(i32, width) - label.width, 2),
            .right => @as(i32, width) - label.width,
        };
        const bounds = ui.intersection(ui.intersection(self.surface.clip, .{ .x = 0, .y = 0, .width = ui.screen_width, .height = ui.screen_height }), .{ .x = left, .y = y, .width = label.width, .height = label.height });
        if (bounds.width == 0 or bounds.height == 0) return true;
        for (0..@intCast(bounds.height)) |row| {
            const mask_at = @as(usize, @intCast(bounds.y - y)) * 320 + @as(usize, @intCast(bounds.x - left)) + row * 320;
            const pixel_at = @as(usize, @intCast(bounds.y * 320 + bounds.x)) + row * 320;
            for (label.pixels[mask_at..][0..@intCast(bounds.width)], self.surface.pixels[pixel_at..][0..@intCast(bounds.width)]) |alpha, *destination| {
                if (alpha != 0) destination.* = if (alpha == 255) color else blend(destination.*, color, alpha);
            }
        }
        return true;
    }

    pub fn chevron(self: Canvas, x: i32, y: i32, color: Color) void {
        for (0..5) |i| {
            const d: i32 = @intCast(i);
            self.fill(x + d, y + d, 2, 1, color);
            self.fill(x + d, y + 8 - d, 2, 1, color);
        }
    }

    pub fn playIcon(self: Canvas, x: i32, y: i32, paused: bool, color: Color) void {
        if (!paused) {
            self.fill(x, y, 3, 11, color);
            self.fill(x + 6, y, 3, 11, color);
            return;
        }
        for (0..10) |i| {
            const d: i32 = @intCast(i);
            self.fill(x + d, y + @divTrunc(d, 2), 1, @intCast(11 - d), color);
        }
    }
};

pub fn blend(a: Color, b: Color, alpha: u8) Color {
    const t: u32 = alpha;
    const inv = 255 - t;
    const r = (((@as(u32, a) >> 11) & 31) * inv + ((@as(u32, b) >> 11) & 31) * t + 127) / 255;
    const g = (((@as(u32, a) >> 5) & 63) * inv + ((@as(u32, b) >> 5) & 63) * t + 127) / 255;
    const blue = ((@as(u32, a) & 31) * inv + (@as(u32, b) & 31) * t + 127) / 255;
    return @intCast((r << 11) | (g << 5) | blue);
}

test "glyph row clipping matches the pixel reference for roles, edge clips and backgrounds" {
    var expected: [ui.pixel_count]u16 = undefined;
    var actual: [ui.pixel_count]u16 = undefined;
    var random = std.Random.DefaultPrng.init(0x4741494e);
    const rng = random.random();
    const values = [_][]const u8{ "A clipped synthetic title — Café", "á…artist’s song", "Mixed 0123456789", "", "架空楽団" };
    for (0..500) |i| {
        const x = rng.intRangeAtMost(i32, -120, 350);
        const y = rng.intRangeAtMost(i32, -60, 270);
        const width = rng.uintLessThan(u16, 400);
        const color = rng.int(u16);
        const background = rng.int(u16);
        const role = std.enums.values(fonts.Role)[i % std.enums.values(fonts.Role).len];
        const value = values[i % values.len];
        @memset(&actual, background);
        @memset(&expected, background);
        var canvas = Canvas.init(&actual);
        canvas.surface.clip = if (i % 2 == 0) .{ .x = 3, .y = 7, .width = 310, .height = 220 } else .{ .x = -30, .y = -10, .width = 400, .height = 270 };
        canvas.text(x, y, width, value, role, color);
        var reference = Canvas.init(&expected);
        reference.surface.clip = ui.intersection(canvas.surface.clip, .{ .x = x, .y = y, .width = width, .height = 48 });
        var iterator = (try std.unicode.Utf8View.init(value)).iterator();
        var cursor = x;
        while (iterator.nextCodepoint()) |code| {
            if (cursor >= x + width) break;
            const glyph = fonts.glyph(role, code);
            for (0..glyph.ink_height) |yy| for (0..glyph.ink_width) |xx| {
                reference.blendPixel(cursor + glyph.ink_x + @as(i32, @intCast(xx)), y + glyph.ink_y + @as(i32, @intCast(yy)), color, fonts.masks[glyph.offset + yy * glyph.ink_width + xx]);
            };
            cursor += glyph.advance;
        }
        try std.testing.expectEqualSlices(u16, &expected, &actual);
    }
}

pub fn textWidth(value: []const u8, role: fonts.Role) u16 {
    const view = std.unicode.Utf8View.init(value) catch return 0;
    var it = view.iterator();
    var cursor: u32 = 0;
    var extent: u32 = 0;
    while (it.nextCodepoint()) |code| {
        const glyph = fonts.glyph(role, code);
        extent = @max(extent, cursor + glyph.width - 1);
        cursor += glyph.advance;
    }
    return @intCast(@min(std.math.maxInt(u16), @max(extent, cursor)));
}

test "linear ellipsis preserves the reference composition and UTF-8 boundaries" {
    const values = [_][]const u8{ "", "I", "Short", "Café — longer album title with multiple words", "á…artist’s song" };
    var expected: [ui.pixel_count]u16 = undefined;
    var actual: [ui.pixel_count]u16 = undefined;
    for (values) |value| for (0..80) |width| {
        const bound: u16 = @intCast(width);
        @memset(&expected, 0xffff);
        @memset(&actual, 0xffff);
        const reference = Canvas.init(&expected);
        if (textWidth(value, .reading) <= bound) {
            reference.text(7, 11, bound, value, .reading, 0);
        } else {
            const tail = textWidth("…", .reading);
            if (bound >= tail) {
                var length = value.len;
                while (length > 0 and textWidth(value[0..length], .reading) + tail > bound) {
                    length -= 1;
                    while (length > 0 and value[length] & 0xc0 == 0x80) length -= 1;
                }
                reference.text(7, 11, bound, value[0..length], .reading, 0);
                reference.text(7 + textWidth(value[0..length], .reading), 11, tail + 1, "…", .reading, 0);
            }
        }
        Canvas.init(&actual).ellipsis(7, 11, bound, value, .reading, 0);
        try std.testing.expectEqualSlices(u16, &expected, &actual);
    };
}

test "prepared labels obey clipping and alignment without font work in drawing" {
    const text = @import("text/cache.zig");
    var cache: text.Cache = undefined;
    cache.reset();
    cache.beginFrame();
    try std.testing.expect(cache.lookup("日本語", .body, 100, true) == null);
    const job = cache.claim().?;
    const label = cache.destination(job);
    label.* = .{ .width = 17, .height = 11 };
    for (0..11) |y| @memset(label.pixels[y * 320 ..][0..17], 255);
    cache.publish(job, .ready);
    var pixels: [ui.pixel_count]u16 = @splat(0xffff);
    var c = Canvas.init(&pixels);
    c.text_cache = &cache;
    c.surface.clip = .{ .x = 20, .y = 10, .width = 40, .height = 30 };
    c.centered(0, 5, 100, "日本語", .body, 0);
    for (0..240) |y| for (0..320) |x| {
        const expected: u16 = if (y >= 10 and y < 16 and x >= 41 and x < 58) 0 else 0xffff;
        try std.testing.expectEqual(expected, pixels[y * 320 + x]);
    };
    const revision = cache.revision.load(.acquire);
    for (0..100) |_| c.centered(0, 5, 100, "日本語", .body, 0);
    try std.testing.expectEqual(revision, cache.revision.load(.acquire));
    try std.testing.expect(!cache.pending());
    try std.testing.expectEqual(@as(u32, 101), cache.hits);
}
