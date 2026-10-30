//! FLAC linear-predictive reconstruction kept separate so the decoder's
//! dominant CPU kernel can be measured on both the host and target device.

pub const Error = error{InvalidSubframe};

pub fn restore(output: []i32, order: u6, coefficients: []const i32, shift: u5) Error!void {
    for (output[order..], order..) |*sample, index| {
        var prediction: i64 = 0;
        for (coefficients, 0..) |coefficient, past| {
            prediction += @as(i64, coefficient) * output[index - past - 1];
        }
        const reconstructed = @as(i64, sample.*) + (prediction >> shift);
        if (reconstructed < minimum_i32 or reconstructed > maximum_i32) {
            return error.InvalidSubframe;
        }
        sample.* = @intCast(reconstructed);
    }
}

const minimum_i32 = -0x8000_0000;
const maximum_i32 = 0x7fff_ffff;

test "restore linear prediction" {
    const std = @import("std");
    var samples = [_]i32{ 2, 5, 0, 0 };
    try restore(&samples, 2, &.{ 2, -1 }, 0);
    try std.testing.expectEqualSlices(i32, &.{ 2, 5, 8, 11 }, &samples);
}

test "reject reconstructed sample overflow" {
    const std = @import("std");
    var samples = [_]i32{ maximum_i32, 1 };
    try std.testing.expectError(error.InvalidSubframe, restore(&samples, 1, &.{1}, 0));
}
