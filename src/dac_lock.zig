//! Cooperative DAC lock acquisition: never sleep across audio DMA periods.
const std = @import("std");

pub const State = struct {
    pending: bool = false,
    started: u32 = 0,
    polled: u32 = 0,

    pub fn begin(self: *State, now: u32) void {
        self.* = .{ .pending = true, .started = now, .polled = now };
    }

    pub fn due(self: State, now: u32, interval: u32) bool {
        return self.pending and now -% self.polled >= interval;
    }

    pub fn observe(self: *State, now: u32, locked: bool, timeout: u32) error{DacLockTimeout}!bool {
        self.polled = now;
        if (locked) {
            self.pending = false;
            return true;
        }
        if (now -% self.started >= timeout) return error.DacLockTimeout;
        return false;
    }
};

/// stop_div is 1024 edges on revision V at <=96 kHz; revision W and >96 kHz
/// require 16384 edges (ESS v3.7 register 10). Zero is the conservative setting.
pub fn stopDivider(rate: u32, revision_v: bool) u4 {
    return if (revision_v and rate <= 96000) 15 else 0;
}

test "slow and high-rate acquisition services every period while waiting through timer wrap" {
    for ([_]u32{ 8000, 11025, 44100, 48000, 96000, 176400, 192000 }) |rate| {
        for ([_]bool{ false, true }) |revision_v| {
            const edges: u32 = if (stopDivider(rate, revision_v) == 15) 1024 else 16384;
            // Inputs requiring >500 ms are explicitly unsupported by this
            // startup policy, e.g. revision W at 8 kHz; never unmute on timeout.
            const lock_ms = (edges * 1000 + rate - 1) / rate;
            var state = State{};
            const origin: u32 = 0xfffffff0;
            state.begin(origin);
            var unlocked = false;
            var periods: usize = 0;
            for (1..501) |elapsed| {
                const now = origin +% @as(u32, @intCast(elapsed));
                if (elapsed % 10 == 0) periods += 1;
                if (state.due(now, 5)) {
                    unlocked = state.observe(now, elapsed >= lock_ms, 500) catch {
                        try std.testing.expect(lock_ms > 500 and state.pending);
                        break;
                    };
                }
                if (unlocked) break;
            }
            try std.testing.expectEqual(lock_ms <= 500, unlocked);
            try std.testing.expect(periods >= @min(lock_ms / 10, 50));
        }
    }
}

test "lock observation precedes timeout but missing lock remains muted" {
    var state = State{};
    state.begin(100);
    try std.testing.expect(try state.observe(600, true, 500));
    try std.testing.expect(!state.pending);
    state.begin(100);
    try std.testing.expectError(error.DacLockTimeout, state.observe(600, false, 500));
    try std.testing.expect(state.pending);
}
