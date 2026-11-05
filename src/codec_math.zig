// Standard libm primitives come from Zig compiler-rt. Defining exp/log wrappers
// using @exp/@log would lower back to the same C symbol on MIPS and recurse.
fn nearestEven(v: anytype) @TypeOf(v) {
    return if (@abs(v - @trunc(v)) == 0.5) 2 * @round(v / 2) else @round(v);
}

export fn lrintf(v: f32) c_long {
    return @intFromFloat(nearestEven(v));
}

export fn lrint(v: f64) c_long {
    return @intFromFloat(nearestEven(v));
}

export fn abs(v: c_int) c_int {
    return if (v < 0) -v else v;
}

const std = @import("std");

// musl's math.h uses this C classification ABI even in freestanding objects.
// Its categories are NAN=0, INFINITE=1, ZERO=2, SUBNORMAL=3, NORMAL=4.
export fn __fpclassifyf(value: f32) c_int {
    const magnitude = @as(u32, @bitCast(value)) & 0x7fff_ffff;
    if (magnitude == 0) return 2;
    if (magnitude < 0x0080_0000) return 3;
    if (magnitude >= 0x7f80_0000) return if (magnitude == 0x7f80_0000) 1 else 0;
    return 4;
}

test "C float classification preserves zero signs, subnormals and non-finite values" {
    for ([_]u32{ 0, 0x8000_0000 }) |bits| try std.testing.expectEqual(2, __fpclassifyf(@bitCast(bits)));
    for ([_]u32{ 1, 0x007f_ffff, 0x8000_0001 }) |bits| try std.testing.expectEqual(3, __fpclassifyf(@bitCast(bits)));
    for ([_]f32{ 1, -1, std.math.floatMin(f32), std.math.floatMax(f32) }) |value| try std.testing.expectEqual(4, __fpclassifyf(value));
    try std.testing.expectEqual(1, __fpclassifyf(std.math.inf(f32)));
    try std.testing.expectEqual(0, __fpclassifyf(std.math.nan(f32)));
}

export fn pow(x: f64, y: f64) f64 {
    return std.math.pow(f64, x, y);
}

export fn atan(x: f64) f64 {
    return std.math.atan(x);
}

export fn ldexp(x: f64, y: c_int) f64 {
    return std.math.ldexp(x, y);
}

export fn rint(x: f64) f64 {
    return nearestEven(x);
}
