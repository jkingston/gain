//! Bounded development commands. SETUP only proposes an action; a matching
//! completed ACK publishes it to the application owner.
const std = @import("std");

pub const Action = enum(u8) { quick = 1, verify = 2, play = 3, stop = 4, reconnect = 5, rom = 6, flush = 7, rebuild = 8, input = 9, input_sample = 10 };

pub const Command = struct { action: Action, value: u16 = 0 };

pub const State = struct {
    setup: [8]u8 = @splat(0),
    waiting: ?Command = null,
    ready: ?Command = null,

    pub fn begin(self: *State, bytes: [8]u8, player_allowed: bool) ?Command {
        self.waiting = null;
        self.setup = bytes;
        if (self.ready != null or !player_allowed or bytes[0] != 0xc0 or std.mem.readInt(u16, bytes[4..6], .little) != 0 or std.mem.readInt(u16, bytes[6..8], .little) != 4) return null;
        const action: Action = std.enums.fromInt(Action, bytes[1] -| 0x60) orelse return null;
        const value = std.mem.readInt(u16, bytes[2..4], .little);
        if (action != .play and action != .input and action != .input_sample and value != 0) return null;
        if (action == .input and value > 6) return null;
        if (action == .input_sample and value != 0xffff and (value > 0x3ff or value & 0x80 != 0)) return null;
        self.waiting = .{ .action = action, .value = value };
        return self.waiting;
    }

    pub fn ack(self: *State, bytes: [8]u8) void {
        if (!std.mem.eql(u8, &bytes, &self.setup)) return;
        if (self.waiting) |command| self.ready = command;
        self.waiting = null;
    }

    pub fn take(self: *State) ?Command {
        const command = self.ready;
        self.ready = null;
        return command;
    }
};

test "commands require matching ACK and cannot execute twice" {
    var state: State = .{};
    const play = [_]u8{ 0xc0, 0x63, 17, 0, 0, 0, 4, 0 };
    try std.testing.expectEqual(Action.play, state.begin(play, true).?.action);
    try std.testing.expect(state.take() == null);
    var wrong = play;
    wrong[2] = 18;
    state.ack(wrong);
    try std.testing.expect(state.take() == null);
    state.ack(play);
    try std.testing.expectEqual(17, state.take().?.value);
    state.ack(play);
    try std.testing.expect(state.take() == null);
    _ = state.begin(play, true);
    _ = state.begin(.{ 0xc0, 0x60, 0, 0, 0, 0, 128, 0 }, true);
    state.ack(play);
    try std.testing.expect(state.take() == null);
}

test "unknown requests, host ownership, OUT direction and malformed lengths cannot queue commands" {
    for (0..256) |request| for ([_]u8{ 0, 1, 4, 8, 255 }) |length| {
        var state: State = .{};
        const bytes = [_]u8{ 0xc0, @intCast(request), 0, 0, 0, 0, length, 0 };
        const proposed = state.begin(bytes, true);
        if (proposed != null) try std.testing.expect(length == 4 and request >= 0x61 and request <= 0x6a);
        try std.testing.expect(state.begin(bytes, false) == null);
        state.ack(bytes);
        try std.testing.expect(state.take() == null);
        var invalid = bytes;
        invalid[0] = 0x40;
        try std.testing.expect(state.begin(invalid, true) == null);
        invalid = bytes;
        invalid[4] = 1;
        try std.testing.expect(state.begin(invalid, true) == null);
    };
}

test "raw input development samples reject power and malformed levels and permit release" {
    var state: State = .{};
    for ([_]u16{ 0, 0x20, 0x300, 0xffff }) |value| {
        var request = [_]u8{ 0xc0, 0x6a, 0, 0, 0, 0, 4, 0 };
        std.mem.writeInt(u16, request[2..4], value, .little);
        try std.testing.expectEqual(Action.input_sample, state.begin(request, true).?.action);
        state.ack(request);
        try std.testing.expectEqual(value, state.take().?.value);
    }
    for ([_]u16{ 0x80, 0x180, 0x400, 0xfffe }) |value| {
        var request = [_]u8{ 0xc0, 0x6a, 0, 0, 0, 0, 4, 0 };
        std.mem.writeInt(u16, request[2..4], value, .little);
        try std.testing.expect(state.begin(request, true) == null);
    }
}
