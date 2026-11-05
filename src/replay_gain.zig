//! ReplayGain is selected once per track, then applied in the fixed-point output
//! stage. The original PCM and user hardware-volume setting remain unchanged.
const std = @import("std");
const core = @import("library.zig");
const output = @import("audio_output.zig");
pub const Mode = enum { off, track, album };
pub const Settings = struct {
    mode: Mode = .off,
    preamp_db: f32 = 0,
    prevent_clipping: bool = true,

    pub fn gain(self: Settings, metadata: core.Gain) u32 {
        if (self.mode == .off) return output.unity_gain_q24;
        const album = self.mode == .album and valid(metadata.album_db);
        const db = (if (album) metadata.album_db else metadata.track_db) orelse return output.unity_gain_q24;
        if (!std.math.isFinite(db) or !std.math.isFinite(self.preamp_db)) return output.unity_gain_q24;
        // Tag/preamp limits bound exponentiation and the Q24 multiplier.
        const requested = amplitude(std.math.clamp(db + self.preamp_db, -96, 24));
        var multiplier = @min(16, requested);
        if (self.prevent_clipping) {
            const peak = (if (album) metadata.album_peak else metadata.track_peak);
            if (peak) |value| {
                if (std.math.isFinite(value) and value > 0) multiplier = @min(multiplier, 1 / value) else multiplier = @min(multiplier, 1);
            } else multiplier = @min(multiplier, 1);
        }
        return @intFromFloat(@floor(std.math.clamp(multiplier * output.unity_gain_q24, 0, output.maximum_gain_q24)));
    }
};
// Integer-dB anchors plus a fourth-order exponential over [0, 1) dB.
// This avoids linking a general exponent/power implementation into the small
// boot image. The maximum relative error is below 2e-7 before Q24 rounding.
const anchors = blk: {
    @setEvalBranchQuota(100_000);
    var result: [121]f64 = undefined;
    for (&result, 0..) |*value, i| value.* = @exp((@as(f64, @floatFromInt(i)) - 96) * 0.1151292546497022842);
    break :blk result;
};
fn amplitude(db: f64) f64 {
    const whole = @floor(db);
    const index: usize = @intFromFloat(whole + 96);
    const x = (db - whole) * 0.1151292546497022842;
    return anchors[index] * (1 + x * (1 + x * (0.5 + x * (1.0 / 6.0 + x / 24))));
}

fn valid(value: ?f64) bool {
    return if (value) |v| std.math.isFinite(v) else false;
}

test "album gain falls back to track and missing or invalid tags preserve unity" {
    try std.testing.expectEqual(output.unity_gain_q24, (Settings{}).gain(.{ .track_db = -9 }));
    try std.testing.expectEqual(output.unity_gain_q24, (Settings{ .mode = .album }).gain(.{}));
    const settings = Settings{ .mode = .album };
    try std.testing.expectEqual((Settings{ .mode = .track }).gain(.{ .track_db = -6 }), settings.gain(.{ .track_db = -6 }));
    try std.testing.expectEqual(output.unity_gain_q24, settings.gain(.{ .album_db = std.math.nan(f64) }));
    try std.testing.expect(settings.gain(.{ .album_db = -12, .track_db = -1 }) < settings.gain(.{ .track_db = -1 }));
}

test "positive gain is peak limited and never guesses missing peak headroom" {
    const settings = Settings{ .mode = .track };
    try std.testing.expectEqual(output.unity_gain_q24, settings.gain(.{ .track_db = 12 }));
    try std.testing.expectEqual(output.unity_gain_q24 * 2, settings.gain(.{ .track_db = 12, .track_peak = 0.5 }));
    try std.testing.expectEqual(output.unity_gain_q24 / 2, settings.gain(.{ .track_db = 12, .track_peak = 2 }));
    const bounded = (Settings{ .mode = .track, .prevent_clipping = false }).gain(.{ .track_db = 1000 });
    try std.testing.expect(bounded <= output.maximum_gain_q24 and bounded > 15 * output.unity_gain_q24);
}

test "bounded gain approximation stays below 0.00001 dB error" {
    for (0..12001) |i| {
        const db: f64 = -96 + @as(f64, @floatFromInt(i)) / 100;
        const reference = std.math.pow(f64, 10, db / 20);
        try std.testing.expect(@abs(amplitude(db) / reference - 1) < 2e-7);
    }
}
