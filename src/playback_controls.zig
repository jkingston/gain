pub const Button = enum(u3) {
    play,
    volume_up,
    volume_down,
    menu,
    previous,
    next,
    back,
    power,

    pub fn mask(self: Button) u8 {
        return @as(u8, 1) << @backingInt(self);
    }
};

pub const Action = union(enum) {
    none,
    stop,
    next,
    previous,
    set_attenuation: u8,
};

pub const minimum_attenuation: u8 = 16;
pub const maximum_attenuation: u8 = 128;
pub const attenuation_step: u8 = 4;

/// Deterministic playback-button reducer. A controller starts disarmed so the
/// press that opened the player cannot immediately stop it. Actions occur only
/// on rising edges, preventing held buttons from changing two tracks or volume
/// steps.
pub const State = struct {
    attenuation: u8,
    last_buttons: u8 = 0,
    armed: bool = false,

    pub fn init(attenuation: u8) State {
        return .{ .attenuation = clampAttenuation(attenuation) };
    }

    pub fn update(self: *State, buttons: u8) Action {
        if (!self.armed) {
            if (buttons == 0) self.armed = true;
            self.last_buttons = buttons;
            return .none;
        }

        const pressed = buttons & ~self.last_buttons;
        self.last_buttons = buttons;
        if (pressed & Button.next.mask() != 0) return .next;
        if (pressed & Button.previous.mask() != 0) return .previous;
        const stop_mask = Button.play.mask() | Button.back.mask() |
            Button.menu.mask() | Button.power.mask();
        if (pressed & stop_mask != 0) return .stop;
        if (pressed & Button.volume_up.mask() != 0) {
            self.attenuation = self.attenuation -| attenuation_step;
            self.attenuation = @max(self.attenuation, minimum_attenuation);
            return .{ .set_attenuation = self.attenuation };
        }
        if (pressed & Button.volume_down.mask() != 0) {
            self.attenuation = self.attenuation +| attenuation_step;
            self.attenuation = @min(self.attenuation, maximum_attenuation);
            return .{ .set_attenuation = self.attenuation };
        }
        return .none;
    }
};

fn clampAttenuation(value: u8) u8 {
    return @min(@max(value, minimum_attenuation), maximum_attenuation);
}

test "opening press is ignored and a held stop fires once" {
    const testing = @import("std").testing;

    const play = Button.play.mask();
    var state = State.init(64);
    try testing.expectEqual(Action.none, state.update(play));
    try testing.expectEqual(Action.none, state.update(0));
    try testing.expectEqual(Action.stop, state.update(play));
    try testing.expectEqual(Action.none, state.update(play));
}

test "volume changes one step per press and remains bounded" {
    const testing = @import("std").testing;

    var state = State.init(20);
    _ = state.update(0);
    try testing.expectEqual(Action{ .set_attenuation = 16 }, state.update(Button.volume_up.mask()));
    try testing.expectEqual(Action.none, state.update(Button.volume_up.mask()));
    _ = state.update(0);
    try testing.expectEqual(Action{ .set_attenuation = 16 }, state.update(Button.volume_up.mask()));

    state = State.init(124);
    _ = state.update(0);
    try testing.expectEqual(Action{ .set_attenuation = 128 }, state.update(Button.volume_down.mask()));
    _ = state.update(0);
    try testing.expectEqual(Action{ .set_attenuation = 128 }, state.update(Button.volume_down.mask()));
}

test "previous and next are distinct edge-triggered actions" {
    const testing = @import("std").testing;

    var state = State.init(64);
    _ = state.update(0);
    try testing.expectEqual(Action.next, state.update(Button.next.mask()));
    try testing.expectEqual(Action.none, state.update(Button.next.mask()));
    _ = state.update(0);
    try testing.expectEqual(Action.previous, state.update(Button.previous.mask()));
}

test "every input trace preserves attenuation bounds" {
    const testing = @import("std").testing;

    var initial: u16 = 0;
    while (initial <= 255) : (initial += 1) {
        var state = State.init(@intCast(initial));
        var buttons: u16 = 0;
        while (buttons <= 255) : (buttons += 1) {
            _ = state.update(@intCast(buttons));
            try testing.expect(state.attenuation >= minimum_attenuation);
            try testing.expect(state.attenuation <= maximum_attenuation);
        }
    }
}
