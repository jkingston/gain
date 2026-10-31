//! Pop-suppressed output routing. Deadlines never block the audio service loop.
const std = @import("std");
pub const Output = enum { headphones, line_out, muted };
pub const Stage = enum { idle, mute, disconnect, select, amplifier, unmute };
pub const State = struct {
    current: Output = .headphones,
    target: Output = .headphones,
    stage: Stage = .idle,
    since: u32 = 0,
    /// Coalesce requests; restart through mute even during an older transition.
    pub fn request(self: *State, output: Output) void {
        if (self.target == output and (self.stage != .idle or self.current == output)) return;
        self.target = output;
        self.stage = .mute;
    }
    /// Backend operations must fail closed. Advance at most one hardware action
    /// per poll. Delays begin after the action completes, not before I2C starts.
    pub fn poll(self: *State, backend: anytype, settle_ticks: u32) !void {
        errdefer {
            backend.hardMute(true);
            self.current = .muted;
            self.stage = .idle;
        }
        switch (self.stage) {
            .idle => {},
            .mute => {
                backend.hardMute(true);
                try backend.softMute(true);
                self.since = backend.now();
                self.stage = .disconnect;
            },
            .disconnect => if (backend.now() -% self.since >= settle_ticks) {
                backend.amplifierShutdown(false);
                backend.amplifierPower(false);
                self.stage = .select;
            },
            .select => {
                backend.selectLine(self.target == .line_out);
                backend.amplifierPower(self.target == .headphones);
                self.since = backend.now();
                self.stage = .amplifier;
            },
            .amplifier => if (backend.now() -% self.since >= settle_ticks) {
                backend.amplifierShutdown(self.target == .headphones);
                self.since = backend.now();
                self.stage = .unmute;
            },
            .unmute => if (backend.now() -% self.since >= settle_ticks) {
                if (self.target != .muted) {
                    try backend.softMute(false);
                    if (backend.playing()) backend.hardMute(false);
                }
                self.current = self.target;
                self.stage = .idle;
            },
        }
    }
};
const Fake = struct {
    ticks: u32 = 0xfffffff0,
    hard: bool = false,
    soft: bool = false,
    powered: bool = true,
    enabled: bool = true,
    line: bool = false,
    running: bool = true,
    fail: bool = false,
    pub fn now(self: *Fake) u32 {
        return self.ticks;
    }
    pub fn hardMute(self: *Fake, value: bool) void {
        self.hard = value;
    }
    pub fn softMute(self: *Fake, value: bool) !void {
        if (self.fail) return error.NoAcknowledge;
        self.soft = value;
    }
    pub fn amplifierShutdown(self: *Fake, value: bool) void {
        std.debug.assert(self.hard and self.soft);
        self.enabled = value;
    }
    pub fn amplifierPower(self: *Fake, value: bool) void {
        std.debug.assert(self.hard and self.soft);
        self.powered = value;
    }
    pub fn selectLine(self: *Fake, value: bool) void {
        std.debug.assert(self.hard and self.soft and !self.enabled);
        self.line = value;
    }
    pub fn playing(self: *Fake) bool {
        return self.running;
    }
};
test "all routes remain muted until each hardware settling interval passes including wrap" {
    for (std.enums.values(Output)) |destination| {
        var state = State{};
        var fake = Fake{};
        state.request(destination);
        if (destination == .headphones) continue;
        try state.poll(&fake, 32);
        try std.testing.expect(fake.hard and fake.soft);
        for (0..200) |_| {
            fake.ticks +%= 1;
            try state.poll(&fake, 32);
            if (state.stage != .idle) try std.testing.expect(fake.hard);
        }
        try std.testing.expectEqual(destination, state.current);
        try std.testing.expectEqual(destination == .muted, fake.hard);
        try std.testing.expectEqual(destination == .line_out, fake.line);
        try std.testing.expect(!fake.powered and !fake.enabled);
    }
}
test "request reversal and every soft mute failure stay fail closed" {
    for (0..6) |failure_stage| {
        var state = State{};
        var fake = Fake{};
        state.request(.line_out);
        var index: usize = 0;
        while (state.stage != .idle) : (index += 1) {
            fake.ticks +%= 32;
            fake.fail = index == failure_stage;
            state.poll(&fake, 32) catch {
                try std.testing.expect(fake.hard);
                try std.testing.expectEqual(Output.muted, state.current);
                break;
            };
        }
    }
    var state = State{};
    var fake = Fake{};
    state.request(.line_out);
    try state.poll(&fake, 32);
    state.request(.headphones);
    for (0..8) |_| {
        fake.ticks +%= 32;
        try state.poll(&fake, 32);
    }
    try std.testing.expectEqual(Output.headphones, state.current);
    try std.testing.expect(fake.powered and fake.enabled and !fake.line and !fake.hard);
    fake.running = false;
    state.request(.line_out);
    for (0..8) |_| {
        fake.ticks +%= 32;
        try state.poll(&fake, 32);
    }
    try std.testing.expect(fake.hard);
}
