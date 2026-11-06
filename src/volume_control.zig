//! UI attenuation endpoints and pop-suppressed DAC volume changes. The bottom
//! of the bar is silence, not merely the quietest half-decibel code.
const std = @import("std");

pub const loudest: u8 = 16;
pub const silent: u8 = 128;

pub fn clamp(value: u8) u8 {
    return std.math.clamp(value, loudest, silent);
}

pub const State = struct {
    attenuation: u8 = 64,

    pub fn muted(self: State) bool {
        return self.attenuation >= silent;
    }

    /// Routing owns other mute reasons. Raising volume may release our mute
    /// only when routing, clock lock and playback all permit audible output.
    pub fn change(self: *State, dac: anytype, requested: u8, may_unmute: bool) !void {
        const was_muted = self.muted();
        const next = clamp(requested);
        if (next == silent) try dac.setMute(true);
        try dac.setVolume(next, next);
        self.attenuation = next;
        if (was_muted and !self.muted() and may_unmute) try dac.setMute(false);
    }
};

const Fake = struct {
    soft_mute: bool = false,
    left: u8 = 64,
    right: u8 = 64,
    fail_volume: bool = false,

    fn setMute(self: *@This(), value: bool) !void {
        self.soft_mute = value;
    }

    fn setVolume(self: *@This(), left: u8, right: u8) !void {
        if (self.fail_volume) return error.Communication;
        self.left = left;
        self.right = right;
    }
};

test "empty volume bar asserts DAC mute and the next step releases it safely" {
    var state: State = .{};
    var dac: Fake = .{};
    try state.change(&dac, silent, true);
    try std.testing.expect(state.muted() and dac.soft_mute);
    try std.testing.expectEqual(silent, dac.left);
    try std.testing.expectEqual(silent, dac.right);
    try state.change(&dac, silent - 1, true);
    try std.testing.expect(!state.muted() and !dac.soft_mute);
    try std.testing.expectEqual(silent - 1, dac.left);
}

test "volume never releases a routing mute and a failed write stays silent" {
    var state = State{ .attenuation = silent };
    var dac = Fake{ .soft_mute = true };
    try state.change(&dac, 100, false);
    try std.testing.expect(dac.soft_mute);
    dac.fail_volume = true;
    try std.testing.expectError(error.Communication, state.change(&dac, silent, true));
    try std.testing.expect(dac.soft_mute);
    try std.testing.expectEqual(@as(u8, 100), state.attenuation);
}
