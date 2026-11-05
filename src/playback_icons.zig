//! Native-size playback symbols. Geometry is supersampled at compile time;
//! painting only blends a small immutable coverage mask with the active theme.
const std = @import("std");
const draw = @import("canvas.zig");

pub const Kind = enum { shuffle, repeat_all, repeat_one, speaker };
pub const width = 22;
pub const height = 16;
const Mask = [width * height]u8;
const Point = struct { x: f32, y: f32 };
const Segment = struct { a: Point, b: Point };

fn segment(x1: f32, y1: f32, x2: f32, y2: f32) Segment {
    return .{ .a = .{ .x = x1, .y = y1 }, .b = .{ .x = x2, .y = y2 } };
}

const shuffle_path = [_]Segment{
    segment(2, 3, 5, 3),       segment(5, 3, 9, 7),
    segment(12, 10, 15, 13),   segment(15, 13, 19, 13),
    segment(2, 13, 5, 13),     segment(5, 13, 15, 3),
    segment(15, 3, 19, 3),     segment(16, 0.8, 19, 3),
    segment(16, 5.2, 19, 3),   segment(16, 10.8, 19, 13),
    segment(16, 15.2, 19, 13),
};
const repeat_path = [_]Segment{
    segment(3, 9, 3, 6),       segment(3, 6, 4, 4),       segment(4, 4, 6, 3),       segment(6, 3, 18, 3),
    segment(15.5, 0.8, 18, 3), segment(15.5, 5.2, 18, 3), segment(19, 7, 19, 10),    segment(19, 10, 18, 12),
    segment(18, 12, 16, 13),   segment(16, 13, 4, 13),    segment(6.5, 10.8, 4, 13), segment(6.5, 15.2, 4, 13),
};
const numeral = [_]Segment{ segment(9, 7, 11, 6), segment(11, 6, 11, 10), segment(9, 10, 13, 10) };

const speaker_path = [_]Segment{
    segment(14, 5, 16, 7),   segment(16, 7, 16, 9), segment(16, 9, 14, 11),
    segment(17, 2, 20, 5),   segment(20, 5, 21, 8), segment(21, 8, 20, 11),
    segment(20, 11, 17, 14),
};

fn speaker(point: Point) bool {
    const body = point.x >= 2 and point.x <= 6 and point.y >= 6 and point.y <= 10;
    const cone = point.x >= 6 and point.x <= 11 and @abs(point.y - 8) <= 2 + (point.x - 6) * 0.6;
    return body or cone or covered(point, &speaker_path);
}

fn covered(point: Point, path: []const Segment) bool {
    for (path) |edge| {
        const dx = edge.b.x - edge.a.x;
        const dy = edge.b.y - edge.a.y;
        const t = std.math.clamp(((point.x - edge.a.x) * dx + (point.y - edge.a.y) * dy) / (dx * dx + dy * dy), 0, 1);
        const x = point.x - (edge.a.x + t * dx);
        const y = point.y - (edge.a.y + t * dy);
        if (x * x + y * y <= 0.75 * 0.75) return true;
    }
    return false;
}

fn mask(comptime kind: Kind) Mask {
    @setEvalBranchQuota(3000000);
    var result: Mask = undefined;
    for (0..height) |y| for (0..width) |x| {
        var samples: u16 = 0;
        for (0..4) |sy| for (0..4) |sx| {
            const point = Point{ .x = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / 4, .y = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / 4 };
            if (if (kind == .speaker) speaker(point) else covered(point, if (kind == .shuffle) &shuffle_path else &repeat_path) or (kind == .repeat_one and covered(point, &numeral))) samples += 1;
        };
        result[y * width + x] = @intCast(samples * 255 / 16);
    };
    return result;
}

const masks = [_]Mask{ mask(.shuffle), mask(.repeat_all), mask(.repeat_one), mask(.speaker) };

pub fn paint(c: draw.Canvas, x: i32, y: i32, kind: Kind, color: draw.Color) void {
    paintFaded(c, x, y, kind, color, 255);
}

pub fn paintFaded(c: draw.Canvas, x: i32, y: i32, kind: Kind, color: draw.Color, opacity: u8) void {
    for (masks[@backingInt(kind)], 0..) |alpha, i| {
        if (alpha != 0) c.blendPixel(x + @as(i32, @intCast(i % width)), y + @as(i32, @intCast(i / width)), color, @intCast(@as(u16, alpha) * opacity / 255));
    }
}

test "native masks have solid strokes and antialiasing, and repeat one adds a distinct numeral" {
    for (masks) |coverage| {
        try std.testing.expect(std.mem.indexOfScalar(u8, &coverage, 255) != null);
        var antialiased = false;
        for (coverage) |alpha| if (alpha > 0 and alpha < 255) {
            antialiased = true;
        };
        try std.testing.expect(antialiased);
    }
    try std.testing.expect(!std.mem.eql(u8, &masks[1], &masks[2]));
}
