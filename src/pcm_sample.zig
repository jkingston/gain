//! Scalar PCM conversion to signed Q1.31. No floating-point instructions or heap.
const std = @import("std");
pub const Encoding = enum { signed, unsigned, float };
pub const Format = struct {
    encoding: Encoding = .signed,
    bytes: u4,
    valid_bits: u7,
    endian: std.builtin.Endian = .little,
    pub fn valid(self: Format) bool {
        return switch (self.encoding) {
            .float => (self.bytes == 4 or self.bytes == 8) and self.valid_bits == @as(u7, self.bytes) * 8,
            .unsigned => self.bytes == 1 and self.valid_bits == 8,
            .signed => self.bytes >= 1 and self.bytes <= 4 and self.valid_bits > 0 and self.valid_bits <= @as(u7, self.bytes) * 8,
        };
    }
    pub fn decode(self: Format, input: []const u8) i32 {
        std.debug.assert(self.valid() and input.len >= self.bytes);
        var bits: u64 = 0;
        for (0..self.bytes) |index| {
            const source = if (self.endian == .little) self.bytes - 1 - index else index;
            bits = (bits << 8) | input[source];
        }
        return switch (self.encoding) {
            .unsigned => (@as(i32, @intCast(bits)) - 128) << 24,
            .signed => blk: {
                // AIFF and extensible WAV valid bits are left aligned. Clear
                // unused bits so malformed padding cannot add signal/noise.
                const container: u6 = @intCast(@as(u7, self.bytes) * 8);
                const unused: u5 = @intCast(container - self.valid_bits);
                const word = @as(u32, @truncate(bits)) & (~@as(u32, 0) << unused);
                break :blk @bitCast(word << @as(u5, @intCast(32 - @as(u7, container))));
            },
            .float => floatToQ31(bits, self.bytes == 8),
        };
    }
};
/// Decoder libraries return native f32 values; normalize once before buffering.
pub fn fromFloat32(value: f32) i32 {
    return floatToQ31(@as(u32, @bitCast(value)), false);
}

fn floatToQ31(bits: u64, double: bool) i32 {
    const mantissa_bits: u6 = if (double) 52 else 23;
    const exponent_mask: u64 = if (double) 0x7ff else 0xff;
    const exponent = (bits >> mantissa_bits) & exponent_mask;
    const mantissa = bits & ((@as(u64, 1) << mantissa_bits) - 1);
    const negative = bits & (@as(u64, 1) << (if (double) @as(u6, 63) else 31)) != 0;
    // NaN is silence; infinities clip. Subnormals are below one Q1.31 LSB.
    if (exponent == exponent_mask and mantissa != 0) return 0;
    if (exponent == 0) return 0;
    const unbiased: i32 = @as(i32, @intCast(exponent)) - @as(i32, if (double) 1023 else 127);
    if (unbiased >= 0) return if (negative) std.math.minInt(i32) else std.math.maxInt(i32);
    const shift: i32 = 31 - @as(i32, mantissa_bits) + unbiased;
    const significant = mantissa | (@as(u64, 1) << mantissa_bits);
    const magnitude = if (shift >= 0) significant << @as(u6, @intCast(shift)) else if (shift <= -64) 0 else significant >> @as(u6, @intCast(-shift));
    const value: i32 = @intCast(magnitude);
    return if (negative) -value else value;
}
/// TPDF dither is used only when reducing a source with >24 valid bits. Native
/// <=24-bit PCM remains exact. Fixed seeds make decoding reproducible in tests.
pub const Quantizer = struct {
    random: u32 = 0x91e10da5,
    pub fn to24(self: *Quantizer, sample: i32, dither: bool) i32 {
        if (!dither) return sample >> 8;
        var value = self.random;
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        self.random = value;
        const noise: i32 = @as(i32, @intCast(value & 255)) - @as(i32, @intCast((value >> 8) & 255));
        const rounded = (@as(i64, sample) + noise + 128) >> 8;
        return @intCast(std.math.clamp(rounded, -8388608, 8388607));
    }
};
test "integer endian, unsigned bias and valid bits preserve native samples exactly" {
    const little = Format{ .bytes = 3, .valid_bits = 24 };
    const big = Format{ .bytes = 3, .valid_bits = 24, .endian = .big };
    for ([_]u32{ 0, 1, 0x7fffff, 0x800000, 0xffffff }) |value| {
        const le = [3]u8{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16) };
        const be = [3]u8{ le[2], le[1], le[0] };
        const expected: i32 = @bitCast(value << 8);
        try std.testing.expectEqual(expected, little.decode(&le));
        try std.testing.expectEqual(expected, big.decode(&be));
    }
    try std.testing.expectEqual(@as(i32, -2147483648), (Format{ .encoding = .unsigned, .bytes = 1, .valid_bits = 8 }).decode(&.{0}));
    try std.testing.expectEqual(@as(i32, 0), (Format{ .bytes = 4, .valid_bits = 24 }).decode(&.{ 0xff, 0, 0, 0 }));
}
test "IEEE float32 and float64 conversion handles boundaries, denormals and non-finite values" {
    for ([_]f64{ -2, -1, -0.75, -0.5, -0.0001, -0.0, 0, 0.0001, 0.5, 0.75, 1, 2, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |value| {
        const expected: i32 = if (std.math.isNan(value)) 0 else if (value >= 1) std.math.maxInt(i32) else if (value <= -1) std.math.minInt(i32) else @intFromFloat(value * 2147483648.0);
        const bits64: u64 = @bitCast(value);
        const bits32: u32 = @bitCast(@as(f32, @floatCast(value)));
        try std.testing.expectEqual(expected, floatToQ31(bits64, true));
        const difference = @as(i64, expected) - floatToQ31(bits32, false);
        try std.testing.expect(@abs(difference) <= 64);
    }
    try std.testing.expectEqual(@as(i32, 0), floatToQ31(1, true));
    try std.testing.expectEqual(@as(i32, 0), floatToQ31(1, false));
}
test "deterministic TPDF is bounded, clips safely and has no DC bias" {
    var quantizer = Quantizer{};
    var duplicate = Quantizer{};
    var sum: i64 = 0;
    var nonzero: usize = 0;
    for (0..100000) |_| {
        const value = quantizer.to24(0, true);
        try std.testing.expectEqual(value, duplicate.to24(0, true));
        try std.testing.expect(value >= -1 and value <= 1);
        sum += value;
        nonzero += @intFromBool(value != 0);
    }
    try std.testing.expect(@abs(sum) < 1000 and nonzero > 20000);
    try std.testing.expectEqual(@as(i32, -8388608), quantizer.to24(std.math.minInt(i32), false));
    for (0..100) |_| {
        try std.testing.expect(quantizer.to24(std.math.maxInt(i32), true) <= 8388607);
        try std.testing.expect(quantizer.to24(std.math.minInt(i32), true) >= -8388608);
    }
}
