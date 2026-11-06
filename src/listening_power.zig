//! Event policy only: hardware reads and the orderly mute/checkpoint/shutdown
//! sequence belong to the platform. Missing I2C observations are never an unplug.
const std = @import("std");
const axp = @import("axp192.zig");
const media = @import("f20_media.zig");

pub const Idle = enum(u8) {
    minutes5,
    minutes15,
    minutes30,
    off,

    pub fn milliseconds(self: Idle) u64 {
        return switch (self) {
            .minutes5 => 5 * 60 * 1000,
            .minutes15 => 15 * 60 * 1000,
            .minutes30 => 30 * 60 * 1000,
            .off => 0,
        };
    }
};

pub const Sleep = enum(u8) {
    off,
    minutes15,
    minutes30,
    minutes60,

    pub fn milliseconds(self: Sleep) u64 {
        return switch (self) {
            .off => 0,
            .minutes15 => 15 * 60 * 1000,
            .minutes30 => 30 * 60 * 1000,
            .minutes60 => 60 * 60 * 1000,
        };
    }
};

pub const Route = enum { none, headphone, line };
pub const Action = enum { none, pause, shutdown };
pub const Input = struct { playing: bool, host_owned: bool, route: Route, jacks: ?axp.Jacks };

/// An unplug pause survives competing controls and replacement workers. Sending
/// a toggle is not acknowledgement: wait for a paused status before clearing it.
pub const PauseRequest = struct {
    pending: bool = false,
    issued: bool = false,

    pub fn request(self: *PauseRequest) void {
        if (!self.pending) self.issued = false;
        self.pending = true;
    }

    pub fn observe(self: *PauseRequest, running: bool, phase: media.PlaybackPhase, replacement_pending: bool) void {
        if (phase == .paused or (!running and !replacement_pending)) self.* = .{};
    }

    pub fn command(self: *PauseRequest, phase: media.PlaybackPhase, ordinary: media.PlaybackCommand) media.PlaybackCommand {
        switch (ordinary) {
            .toggle_pause => {
                if (self.pending and phase == .playing) self.issued = true;
                return ordinary;
            },
            .seek_to, .next, .previous, .stop => {
                // A retiring worker may never acknowledge its pause. Transfer
                // the request into the replacement's initial paused state.
                self.issued = false;
                return ordinary;
            },
            .set_attenuation => return ordinary,
            .none => {},
        }
        if (self.pending and !self.issued and phase == .playing) {
            self.issued = true;
            return .toggle_pause;
        }
        return .none;
    }
};

/// Own physical debounce and route choice in the control actor. On this board
/// headphone detection wins; line output is the idle default because its sense
/// input may become meaningful only while that output drives a high-Z load.
pub const OutputPolicy = struct {
    debounce: axp.JackDebounce = .{},
    confirmed: ?axp.Jacks = null,
    settle_ticks: u32 = 40,

    pub const Decision = struct { route: Route, pause: bool };

    /// Caller supplies one clock domain (milliseconds by default). Capture the
    /// actual route before applying this decision, then retain the pause event
    /// until the UI actor consumes it; later route changes cannot erase it.
    pub fn observe(self: *OutputPolicy, now: u32, sample: ?axp.Jacks, actual: Route, playing: bool) ?Decision {
        const stable = self.debounce.update(now, sample, self.settle_ticks) orelse return null;
        if (self.confirmed) |previous| if (std.meta.eql(previous, stable)) return null;
        const unplug = if (self.confirmed) |previous| previous.headphone and !stable.headphone else false;
        self.confirmed = stable;
        return .{
            .route = if (stable.headphone) .headphone else .line,
            .pause = unplug and actual == .headphone and playing,
        };
    }
};

pub const Policy = struct {
    debounce: axp.JackDebounce = .{},
    confirmed: ?axp.Jacks = null,
    idle_since: ?u64 = null,
    sleep: Sleep = .off,
    sleep_deadline: ?u64 = null,
    shutdown_requested: bool = false,

    pub fn activity(self: *Policy, now: u64) void {
        self.idle_since = now;
    }

    /// Sleep is deliberately not persistent across reboot. While the host owns
    /// the card an expired timer waits for eject; it never removes the volume.
    pub fn setSleep(self: *Policy, now: u64, value: Sleep) void {
        self.sleep = value;
        self.sleep_deadline = if (value == .off) null else now +| value.milliseconds();
        self.shutdown_requested = false;
    }

    pub fn tick(self: *Policy, now: u64, idle: Idle, input: Input) Action {
        var unplug = false;
        if (self.debounce.update(@truncate(now), input.jacks, 40)) |jacks| {
            if (self.confirmed) |previous| unplug = previous.headphone and !jacks.headphone;
            self.confirmed = jacks;
        }
        if (input.playing or input.host_owned) self.idle_since = null else if (self.idle_since == null) self.idle_since = now;
        if (!input.host_owned and !self.shutdown_requested) {
            const sleep_expired = if (self.sleep_deadline) |deadline| now >= deadline else false;
            const idle_expired = idle != .off and !input.playing and self.idle_since != null and now -| self.idle_since.? >= idle.milliseconds();
            if (sleep_expired or idle_expired) {
                self.shutdown_requested = true;
                return .shutdown;
            }
        }
        if (unplug and input.route == .headphone and input.playing and !input.host_owned) return .pause;
        return .none;
    }
};

test "headphone removal requires confirmed observations and never resumes on reinsertion" {
    var policy = Policy{};
    var input = Input{ .playing = true, .host_owned = false, .route = .headphone, .jacks = .{ .headphone = true, .line = false } };
    try std.testing.expectEqual(Action.none, policy.tick(0, .off, input));
    try std.testing.expectEqual(Action.none, policy.tick(40, .off, input));
    input.jacks = .{ .headphone = false, .line = false };
    try std.testing.expectEqual(Action.none, policy.tick(50, .off, input));
    input.jacks = null;
    try std.testing.expectEqual(Action.none, policy.tick(100, .off, input));
    input.jacks = .{ .headphone = false, .line = false };
    try std.testing.expectEqual(Action.none, policy.tick(110, .off, input));
    try std.testing.expectEqual(Action.pause, policy.tick(150, .off, input));
    try std.testing.expectEqual(Action.none, policy.tick(200, .off, input));
    input.playing = false;
    input.jacks = .{ .headphone = true, .line = false };
    try std.testing.expectEqual(Action.none, policy.tick(210, .off, input));
    try std.testing.expectEqual(Action.none, policy.tick(250, .off, input));
}

test "line-out, initial absent jacks and contact bounce do not pause" {
    var policy = Policy{};
    var input = Input{ .playing = true, .host_owned = false, .route = .line, .jacks = .{ .headphone = false, .line = true } };
    try std.testing.expectEqual(Action.none, policy.tick(0xfffffff0, .off, input));
    try std.testing.expectEqual(Action.none, policy.tick(0x100000020, .off, input));
    input.jacks = .{ .headphone = true, .line = true };
    _ = policy.tick(0x100000030, .off, input);
    _ = policy.tick(0x100000060, .off, input);
    input.jacks = .{ .headphone = false, .line = true };
    _ = policy.tick(0x100000070, .off, input);
    try std.testing.expectEqual(Action.none, policy.tick(0x1000000a0, .off, input));
    input.route = .headphone;
    input.jacks = .{ .headphone = true, .line = false };
    _ = policy.tick(0x1000000b0, .off, input);
    input.jacks = .{ .headphone = false, .line = false };
    _ = policy.tick(0x1000000c0, .off, input);
    try std.testing.expectEqual(Action.none, policy.tick(0x100000100, .off, input));
}

test "sleep defers through USB ownership and paused idle restarts after activity or playback" {
    var policy = Policy{};
    var input = Input{ .playing = false, .host_owned = false, .route = .none, .jacks = null };
    _ = policy.tick(0, .minutes5, input);
    policy.activity(290000);
    try std.testing.expectEqual(Action.none, policy.tick(300000, .minutes5, input));
    input.playing = true;
    try std.testing.expectEqual(Action.none, policy.tick(600000, .minutes5, input));
    input.playing = false;
    _ = policy.tick(700000, .minutes5, input);
    try std.testing.expectEqual(Action.none, policy.tick(999999, .minutes5, input));
    try std.testing.expectEqual(Action.shutdown, policy.tick(1000000, .minutes5, input));
    try std.testing.expectEqual(Action.none, policy.tick(1000001, .minutes5, input));
    policy = .{};
    policy.setSleep(0, .minutes15);
    input.playing = true;
    input.host_owned = true;
    try std.testing.expectEqual(Action.none, policy.tick(1000000, .off, input));
    input.host_owned = false;
    try std.testing.expectEqual(Action.shutdown, policy.tick(1000001, .off, input));
    policy.setSleep(1000002, .off);
    try std.testing.expectEqual(Action.none, policy.tick(2000000, .off, input));
}

test "unplug pause survives competing volume and is issued once until paused acknowledgement" {
    var pause = PauseRequest{};
    pause.request();
    const volume = media.PlaybackCommand{ .set_attenuation = 71 };
    try std.testing.expectEqual(volume, pause.command(.playing, volume));
    try std.testing.expect(pause.pending);
    try std.testing.expectEqual(media.PlaybackCommand.toggle_pause, pause.command(.playing, .none));
    pause.observe(true, .playing, false);
    try std.testing.expectEqual(media.PlaybackCommand.none, pause.command(.playing, .none));
    // Repeated observations or another unplug edge do not invert a pause whose
    // status acknowledgement has not arrived yet.
    pause.request();
    try std.testing.expectEqual(media.PlaybackCommand.none, pause.command(.playing, .none));
    pause.observe(true, .paused, false);
    try std.testing.expect(!pause.pending);
    try std.testing.expectEqual(media.PlaybackCommand.none, pause.command(.paused, .none));
    pause.observe(true, .playing, false);
    try std.testing.expectEqual(media.PlaybackCommand.none, pause.command(.playing, .none));
}

test "seek and track replacement inherit an unplug pause across worker retirement and preparation" {
    for ([_]media.PlaybackCommand{ .{ .seek_to = 96000 }, .next, .previous, .stop }) |ordinary| {
        var pause = PauseRequest{};
        pause.request();
        try std.testing.expectEqual(ordinary, pause.command(.playing, ordinary));
        pause.observe(false, .playing, true);
        try std.testing.expect(pause.pending); // Used by the new worker's initially_paused.
        const initially_paused = false or pause.pending;
        try std.testing.expect(initially_paused);
        pause.observe(true, .preparing, false);
        try std.testing.expectEqual(media.PlaybackCommand.none, pause.command(.preparing, .none));
        pause.observe(true, .paused, false);
        try std.testing.expect(!pause.pending);
        try std.testing.expectEqual(media.PlaybackCommand.none, pause.command(.paused, .none));
    }
}

test "an ordinary pause fulfils the pending request without a second toggle or an automatic resume" {
    var pause = PauseRequest{};
    pause.request();
    try std.testing.expectEqual(media.PlaybackCommand.toggle_pause, pause.command(.playing, .toggle_pause));
    try std.testing.expectEqual(media.PlaybackCommand.none, pause.command(.playing, .none));
    pause.observe(true, .paused, false);
    try std.testing.expect(!pause.pending);
    // A stopped session with no replacement does not transfer the old request
    // to an unrelated future Play selection.
    pause.request();
    pause.observe(false, .playing, false);
    try std.testing.expect(!pause.pending);
    try std.testing.expectEqual(media.PlaybackCommand.none, pause.command(.preparing, .none));
}

test "physical output policy gives headphones priority and enables line detection by default" {
    for ([_]axp.Jacks{
        .{ .headphone = false, .line = false },
        .{ .headphone = false, .line = true },
        .{ .headphone = true, .line = false },
        .{ .headphone = true, .line = true },
    }) |jacks| {
        var policy = OutputPolicy{};
        try std.testing.expect(policy.observe(0xfffffff0, jacks, .headphone, true) == null);
        const decision = policy.observe(0x20, jacks, .headphone, true).?;
        try std.testing.expectEqual(if (jacks.headphone) Route.headphone else Route.line, decision.route);
        try std.testing.expect(!decision.pause);
        try std.testing.expect(policy.observe(0x40, jacks, decision.route, true) == null);
    }
}

test "confirmed headphone removal publishes pause before route changes even if UI consumption is delayed" {
    var policy = OutputPolicy{};
    const headphones = axp.Jacks{ .headphone = true, .line = true };
    const removed = axp.Jacks{ .headphone = false, .line = true };
    _ = policy.observe(0, headphones, .headphone, true);
    _ = policy.observe(40, headphones, .headphone, true);
    try std.testing.expect(policy.observe(50, removed, .headphone, true) == null);
    const event = policy.observe(90, removed, .headphone, true).?;
    try std.testing.expect(event.pause and event.route == .line);
    // Hardware has completed its transition before the next UI poll. The
    // captured event still pauses; current-route filtering in UI would miss it.
    try std.testing.expect(policy.observe(110, removed, .line, true) == null);
    var pause = PauseRequest{};
    if (event.pause) pause.request();
    try std.testing.expectEqual(media.PlaybackCommand.toggle_pause, pause.command(.playing, .none));
    pause.observe(true, .paused, false);
    _ = policy.observe(120, headphones, .line, false);
    const inserted = policy.observe(160, headphones, .line, false).?;
    try std.testing.expect(inserted.route == .headphone and !inserted.pause);
    try std.testing.expect(!pause.pending);
    try std.testing.expectEqual(media.PlaybackCommand.none, pause.command(.paused, .none));
}

test "line-only changes, read failures and incomplete debounce do not fabricate a headphone pause" {
    var policy = OutputPolicy{};
    const line = axp.Jacks{ .headphone = false, .line = true };
    const both = axp.Jacks{ .headphone = true, .line = true };
    _ = policy.observe(0, line, .line, true);
    try std.testing.expect(!policy.observe(40, line, .line, true).?.pause);
    const neither = axp.Jacks{ .headphone = false, .line = false };
    _ = policy.observe(50, neither, .line, true);
    try std.testing.expect(!policy.observe(90, neither, .line, true).?.pause);
    _ = policy.observe(100, both, .line, true);
    _ = policy.observe(140, both, .line, true);
    try std.testing.expect(policy.observe(150, null, .headphone, true) == null);
    try std.testing.expect(policy.observe(200, null, .headphone, true) == null);
    try std.testing.expect(policy.confirmed.?.headphone);
    try std.testing.expect(policy.observe(210, line, .headphone, true) == null);
    try std.testing.expect(policy.observe(240, line, .headphone, true) == null);
    try std.testing.expect(policy.observe(250, line, .headphone, true).?.pause);
    _ = policy.observe(260, both, .line, true);
    _ = policy.observe(300, both, .line, true);
    _ = policy.observe(310, line, .line, true);
    // A forced/already active line route must not be paused by removing an
    // otherwise detected headphone connector.
    try std.testing.expect(!policy.observe(350, line, .line, true).?.pause);
}
