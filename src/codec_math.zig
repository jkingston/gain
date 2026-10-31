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
