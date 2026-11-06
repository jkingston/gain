//! Player navigation policy. Physical edges and monotonic milliseconds enter;
//! bounded semantic actions leave. No rendering, allocation or host OS repeats.
const std = @import("std");
const capture = @import("input_capture.zig");
pub const Button = capture.Button;
pub const Context = enum { list, covers, transport };
pub const Action = union(enum) { none, move: i32, select, back, home, menu, queue, now_playing, jump, previous, next, scrub: i32, commit_seek, adjust_volume: i8, volume_up, volume_down };

const first_repeat_ms = 320;
const travel_start_ms = 900;
const travel_ramp_ms = 700;
const traversal_ms = 2000;
const wheel_reset_ms = 180;
const shortcut_hold_ms = 500;
const seek_hold_ms = 400;
const seek_repeat_ms = 120;
const volume_first_repeat_ms = 200;
const volume_repeat_ms = 50;
const navigation_mask = Button.previous.mask() | Button.next.mask();
const volume_mask = Button.volume_up.mask() | Button.volume_down.mask();

pub fn move(selection: usize, count: usize, delta: i32) usize {
    if (count == 0) return 0;
    const current = @min(selection, count - 1);
    return if (delta < 0) current -| @as(usize, @intCast(-@as(i64, delta))) else @min(count - 1, current +| @as(usize, @intCast(delta)));
}

/// Row-aligned window for either lists or grids, preserving the selected item.
pub fn firstVisible(selection: usize, current: usize, capacity: usize, columns: usize) usize {
    const cols = @max(1, columns);
    const count = @max(cols, capacity);
    const first = current - current % cols;
    if (selection < first) return selection - selection % cols;
    if (selection >= first +| count) return (selection / cols + 1 - count / cols) * cols;
    return first;
}

pub const Policy = struct {
    held: u8 = 0,
    suppressed: u8 = 0,
    direction: i32 = 0,
    started_at: u64 = 0,
    repeat_at: u64 = 0,
    gesture_count: usize = 0,
    gesture_context: Context = .list,
    menu_at: ?u64 = null,
    menu_consumed: bool = false,
    back_at: ?u64 = null,
    back_consumed: bool = false,
    play_at: ?u64 = null,
    play_consumed: bool = false,
    transport_button: ?Button = null,
    seeking: bool = false,
    volume_at: u64 = 0,
    volume_started_at: u64 = 0,
    volume_press_at: ?u64 = null,
    volume_direction: i2 = 0,
    volume_presses: u8 = 0,
    wheel_at: ?u64 = null,
    wheel_direction: i32 = 0,
    wheel_interval: u64 = wheel_reset_ms,
    wheel_consistent: u8 = 0,

    pub fn cancel(self: *Policy, held: u8) void {
        self.* = .{ .held = held, .suppressed = held };
    }

    fn stopWheel(self: *Policy) void {
        self.wheel_at = null;
        self.wheel_direction = 0;
        self.wheel_interval = wheel_reset_ms;
        self.wheel_consistent = 0;
    }

    pub fn edge(self: *Policy, button: Button, pressed: bool, now: u64, context: Context, count: usize) Action {
        const mask = button.mask();
        if ((self.held & mask != 0) == pressed) return .none;
        if (pressed) self.held |= mask else self.held &= ~mask;
        if (self.suppressed & mask != 0) {
            if (!pressed) self.suppressed &= ~mask;
            return .none;
        }
        if (button == .previous or button == .next) {
            self.stopWheel();
            if (context == .transport) {
                if (pressed) {
                    // A tap skips on release. Waiting distinguishes it from a
                    // hold without starting a different track first.
                    if (self.held & navigation_mask == navigation_mask) {
                        self.transport_button = null;
                        self.suppressed |= navigation_mask;
                        return if (self.seeking) .commit_seek else .none;
                    }
                    self.transport_button = button;
                    self.seeking = false;
                    self.started_at = now;
                    self.repeat_at = now +| seek_hold_ms;
                    self.gesture_context = context;
                    return .none;
                }
                if (self.transport_button != button) return .none;
                self.transport_button = null;
                return if (self.seeking) .commit_seek else if (now -| self.started_at >= seek_hold_ms) .none else if (button == .previous) .previous else .next;
            }
            const active = self.held & ~self.suppressed & navigation_mask;
            self.direction = if (active == Button.next.mask()) 1 else if (active == Button.previous.mask()) -1 else 0;
            self.started_at = now;
            self.repeat_at = now +| first_repeat_ms;
            self.gesture_count = count;
            self.gesture_context = context;
            if (!pressed or self.direction == 0) return .none;
            return .{ .move = self.direction };
        }
        if (button == .volume_up or button == .volume_down) {
            self.volume_at = now +| volume_first_repeat_ms;
            if (!pressed) return .none;
            if (self.held & volume_mask == volume_mask) {
                self.volume_press_at = null;
                self.volume_presses = 0;
                return .none;
            }
            const direction: i2 = if (button == .volume_up) 1 else -1;
            const rapid = self.volume_direction == direction and if (self.volume_press_at) |at| now -| at <= 250 else false;
            self.volume_presses = if (rapid) self.volume_presses +| 1 else 1;
            self.volume_press_at = now;
            self.volume_direction = direction;
            self.volume_started_at = now;
            // Same-direction taps ramp 0.5, 1, then at most 2 dB. A pause or
            // reversal immediately restores half-decibel control.
            const step: i8 = if (self.volume_presses == 1) 1 else if (self.volume_presses == 2) 2 else 4;
            return .{ .adjust_volume = @as(i8, direction) * step };
        }
        if (button == .play) {
            if (pressed) {
                self.play_at = now;
                self.play_consumed = false;
                return .none;
            }
            const at = self.play_at orelse return .none;
            self.play_at = null;
            if (self.play_consumed) return .none;
            // A complete hold may arrive between UI polls. Its captured
            // release still opens Now Playing, never the selected song.
            return if (now -| at >= shortcut_hold_ms) .now_playing else .select;
        }
        if (button == .back) {
            if (pressed) {
                self.back_at = now;
                self.back_consumed = false;
                return .none;
            }
            defer self.back_at = null;
            return if (self.back_at != null and !self.back_consumed) .back else .none;
        }
        if (button == .menu) {
            if (pressed) {
                self.menu_at = now;
                self.menu_consumed = false;
                return .none;
            }
            defer self.menu_at = null;
            return if (self.menu_at != null and !self.menu_consumed) .menu else .none;
        }
        if (!pressed) return .none;
        return switch (button) {
            .back => .back,
            .volume_up => .volume_up,
            .volume_down => .volume_down,
            .play, .power, .menu, .previous, .next => .none,
        };
    }

    pub fn wheel(self: *Policy, direction: i2, now: u64, context: Context, count: usize) Action {
        std.debug.assert(direction == -1 or direction == 1);
        // Switching source cancels held-button travel until physical release.
        self.suppressed |= self.held & navigation_mask;
        self.direction = 0;
        const elapsed = if (self.wheel_at) |at| now -| at else wheel_reset_ms;
        if (self.wheel_direction != direction or elapsed >= wheel_reset_ms) {
            self.wheel_interval = wheel_reset_ms;
            self.wheel_consistent = 0;
        } else {
            self.wheel_consistent +|= 1;
            self.wheel_interval = (self.wheel_interval + @max(1, elapsed)) / 2;
        }
        self.wheel_at = now;
        self.wheel_direction = direction;
        if (context == .transport) return .none;
        var gain: i32 = 1;
        if (count > 8 and self.wheel_consistent >= 3) {
            gain = if (self.wheel_interval < 35) 8 else if (self.wheel_interval < 60) 4 else if (self.wheel_interval < 100) 2 else 1;
            if (context == .covers) gain = @min(3, gain);
        }
        return .{ .move = direction * gain };
    }

    /// raw_held inhibits a repeat on the first observed release, before debounce.
    /// Call after draining captured edges, so a queued release wins over a tick.
    pub fn tick(self: *Policy, now: u64, context: Context, _: usize, raw_held: u8) Action {
        if (self.back_at) |at| {
            if (!self.back_consumed and raw_held & Button.back.mask() != 0 and now -| at >= shortcut_hold_ms) {
                self.back_consumed = true;
                return .queue;
            }
        }
        if (self.menu_at) |at| {
            if (!self.menu_consumed and raw_held & Button.menu.mask() != 0 and now -| at >= shortcut_hold_ms) {
                self.menu_consumed = true;
                self.direction = 0;
                self.suppressed |= self.held & navigation_mask;
                return .home;
            }
        }
        if (self.play_at) |at| {
            if (!self.play_consumed and raw_held & Button.play.mask() != 0 and now -| at >= shortcut_hold_ms) {
                self.play_consumed = true;
                return .now_playing;
            }
        }
        if (context != self.gesture_context) {
            self.direction = 0;
            self.transport_button = null;
            self.suppressed |= self.held & navigation_mask;
        }
        const volume = self.held & raw_held & ~self.suppressed & volume_mask;
        if (now >= self.volume_at and (volume == Button.volume_up.mask() or volume == Button.volume_down.mask())) {
            self.volume_at = now +| volume_repeat_ms;
            const age = now -| self.volume_started_at;
            const step: i8 = if (age < 350) 2 else 4;
            return .{ .adjust_volume = if (volume == Button.volume_up.mask()) step else -step };
        }
        if (self.transport_button) |button| {
            if (context == .transport and raw_held & button.mask() != 0 and now >= self.repeat_at) {
                self.seeking = true;
                self.repeat_at = now +| seek_repeat_ms;
                const elapsed = now -| self.started_at;
                const seconds: i32 = if (elapsed < 2000) 2 else if (elapsed < 5000) 5 else 15;
                return .{ .scrub = if (button == .previous) -seconds else seconds };
            }
        }
        if (self.direction == 0 or context == .transport or now < self.repeat_at) return .none;
        const mask = if (self.direction > 0) Button.next.mask() else Button.previous.mask();
        if (raw_held & mask == 0) return .none;
        const elapsed = now -| self.started_at;
        const interval: u64 = if (self.gesture_count <= 8) 130 else if (context == .covers)
            (if (elapsed < 1000) @as(u64, 130) else if (elapsed < 2200) @as(u64, 95) else 70)
        else if (elapsed < 1000) 110 else if (elapsed < 2200) 70 else 45;
        self.repeat_at = now +| interval;
        var step: usize = 1;
        if (self.gesture_count > 100 and elapsed >= travel_start_ms) {
            const ceiling: usize = if (context == .covers) 24 else 256;
            const peak = std.math.clamp((self.gesture_count *| @as(usize, @intCast(interval)) +| (traversal_ms - 1)) / traversal_ms, 2, ceiling);
            const ramp: usize = @intCast(@min(travel_ramp_ms, elapsed - travel_start_ms));
            step += (peak - 1) * ramp / travel_ramp_ms;
        }
        // Count can change progressively; speed uses the gesture's original
        // length, while applying the action clamps against the latest view.
        return .{ .move = self.direction * @as(i32, @intCast(step)) };
    }
};

test "Rapid traverses a large list across cadences with precise release and reversal" {
    for ([_]u64{ 5, 16, 33, 50 }) |cadence| {
        var policy = Policy{};
        var selection = move(0, 4223, policy.edge(.next, true, 0, .list, 4223).move);
        var now: u64 = 0;
        while (now < 6000 and selection < 4222) : (now += cadence) {
            const action = policy.tick(now, .list, 4223, Button.next.mask());
            if (action == .move) selection = move(selection, 4223, action.move);
        }
        try std.testing.expectEqual(4222, selection);
        _ = policy.edge(.next, false, now, .list, 4223);
        try std.testing.expectEqual(.none, std.meta.activeTag(policy.tick(now + 50000, .list, 4223, 0)));
        try std.testing.expectEqual(@as(i32, -1), policy.edge(.previous, true, now + 50001, .list, 4223).move);
    }
}

test "publication changes bounds without changing a held gesture's speed" {
    var left = Policy{};
    var right = Policy{};
    _ = left.edge(.next, true, 0, .list, 1000);
    _ = right.edge(.next, true, 0, .list, 1000);
    for ([_]u64{ 320, 900, 1200, 1700, 3000, 10000 }) |now| {
        try std.testing.expectEqual(left.tick(now, .list, 1000, Button.next.mask()), right.tick(now, .list, 8192, Button.next.mask()));
        try std.testing.expectEqual(.none, std.meta.activeTag(left.tick(now, .list, 1000, Button.next.mask())));
    }
    try std.testing.expectEqual(4, move(100, 5, 256));
    try std.testing.expectEqual(0, move(0, 8192, std.math.minInt(i32)));
}

test "raw release, opposite keys, source switches and cancellation cannot leave repeats" {
    var policy = Policy{};
    _ = policy.edge(.next, true, 0, .list, 4223);
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.tick(320, .list, 4223, 0)));
    _ = policy.edge(.previous, true, 321, .list, 4223);
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.tick(1000, .list, 4223, navigation_mask)));
    _ = policy.edge(.previous, false, 1001, .list, 4223);
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.tick(1320, .list, 4223, Button.next.mask())));
    try std.testing.expectEqual(@as(i32, 1), policy.tick(1321, .list, 4223, Button.next.mask()).move);
    _ = policy.wheel(1, 1322, .list, 4223);
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.tick(2000, .list, 4223, Button.next.mask())));
    policy.cancel(Button.next.mask());
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.edge(.next, true, 2100, .list, 4223)));
    _ = policy.edge(.next, false, 2101, .list, 4223);
    try std.testing.expectEqual(@as(i32, 1), policy.edge(.next, true, 2102, .list, 4223).move);
}

test "wheel accelerates only sustained motion, keeps short menus precise and never coasts" {
    for ([_]Context{ .list, .covers }) |context| {
        var policy = Policy{};
        for (0..3) |i| try std.testing.expectEqual(@as(i32, 1), policy.wheel(1, i * 20, context, 1000).move);
        for (3..12) |i| _ = policy.wheel(1, i * 20, context, 1000);
        try std.testing.expectEqual(if (context == .covers) @as(i32, 3) else 8, policy.wheel(1, 240, context, 1000).move);
        try std.testing.expectEqual(@as(i32, -1), policy.wheel(-1, 241, context, 1000).move);
        try std.testing.expectEqual(@as(i32, 1), policy.wheel(1, 500, context, 1000).move);
        for (0..30) |i| try std.testing.expectEqual(@as(i32, 1), policy.wheel(1, 1000 + i * 5, context, 4).move);
        try std.testing.expectEqual(.none, std.meta.activeTag(policy.tick(10000, context, 1000, 0)));
    }
}

test "transport holds do not repeat skip and Menu hold consumes its short action" {
    var policy = Policy{};
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.edge(.next, true, 0, .transport, 1000)));
    try std.testing.expectEqual(.next, std.meta.activeTag(policy.edge(.next, false, 100, .transport, 1000)));
    policy.cancel(0);
    _ = policy.edge(.menu, true, 6000, .list, 1000);
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.tick(6499, .list, 1000, Button.menu.mask())));
    try std.testing.expectEqual(.home, std.meta.activeTag(policy.tick(6500, .list, 1000, Button.menu.mask())));
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.edge(.menu, false, 6600, .list, 1000)));
    _ = policy.edge(.menu, true, 7000, .list, 1000);
    try std.testing.expectEqual(.menu, std.meta.activeTag(policy.edge(.menu, false, 7100, .list, 1000)));
}

test "transport taps skip only on release and held seeking accelerates without skips" {
    for ([_]Button{ .previous, .next }) |button| {
        var policy = Policy{};
        try std.testing.expectEqual(Action.none, policy.edge(button, true, 0, .transport, 10));
        try std.testing.expectEqual(Action.none, policy.tick(399, .transport, 10, button.mask()));
        const sign: i32 = if (button == .previous) -1 else 1;
        try std.testing.expectEqual(Action{ .scrub = sign * 2 }, policy.tick(400, .transport, 10, button.mask()));
        try std.testing.expectEqual(Action{ .scrub = sign * 5 }, policy.tick(2000, .transport, 10, button.mask()));
        try std.testing.expectEqual(Action{ .scrub = sign * 15 }, policy.tick(5000, .transport, 10, button.mask()));
        try std.testing.expectEqual(Action.none, policy.tick(5200, .transport, 10, 0));
        try std.testing.expectEqual(Action.commit_seek, policy.edge(button, false, 5201, .transport, 10));
        try std.testing.expectEqual(Action.none, policy.tick(10000, .transport, 10, 0));
    }
}

test "volume holds are bounded and release or cancellation withdraws repeats" {
    var policy = Policy{};
    try std.testing.expectEqual(Action{ .adjust_volume = 1 }, policy.edge(.volume_up, true, 0, .list, 3));
    try std.testing.expectEqual(Action.none, policy.tick(199, .list, 3, Button.volume_up.mask()));
    try std.testing.expectEqual(Action{ .adjust_volume = 2 }, policy.tick(200, .list, 3, Button.volume_up.mask()));
    try std.testing.expectEqual(Action{ .adjust_volume = 4 }, policy.tick(10000, .list, 3, Button.volume_up.mask()));
    try std.testing.expectEqual(Action.none, policy.tick(10000, .list, 3, Button.volume_up.mask()));
    try std.testing.expectEqual(Action.none, policy.tick(10100, .list, 3, 0));
    _ = policy.edge(.volume_down, true, 10200, .list, 3);
    try std.testing.expectEqual(Action.none, policy.tick(11000, .list, 3, volume_mask));
    policy.cancel(volume_mask);
    try std.testing.expectEqual(Action.none, policy.tick(20000, .list, 3, volume_mask));
}

test "rapid volume tapping accelerates modestly and pauses or reversals restore fine adjustment" {
    var policy = Policy{};
    for (0..8) |i| {
        const now = i * 100;
        try std.testing.expectEqual(Action{ .adjust_volume = if (i == 0) 1 else if (i == 1) 2 else 4 }, policy.edge(.volume_up, true, now, .list, 3));
        _ = policy.edge(.volume_up, false, now + 30, .list, 3);
    }
    try std.testing.expectEqual(Action{ .adjust_volume = -1 }, policy.edge(.volume_down, true, 800, .list, 3));
    _ = policy.edge(.volume_down, false, 830, .list, 3);
    try std.testing.expectEqual(Action{ .adjust_volume = 1 }, policy.edge(.volume_up, true, 900, .list, 3));
    _ = policy.edge(.volume_up, false, 930, .list, 3);
    try std.testing.expectEqual(Action{ .adjust_volume = 1 }, policy.edge(.volume_up, true, 1300, .list, 3));
    policy.cancel(Button.volume_up.mask());
    try std.testing.expectEqual(Action.none, policy.tick(6000, .list, 3, Button.volume_up.mask()));
}

test "a capped volume hold traverses the full range in a few seconds at different polling cadences" {
    for ([_]u64{ 5, 16, 33, 50 }) |cadence| {
        var policy = Policy{};
        var level: i32 = policy.edge(.volume_up, true, 0, .transport, 0).adjust_volume;
        var now: u64 = cadence;
        while (level < 112 and now <= 2200) : (now += cadence) {
            const action = policy.tick(now, .transport, 0, Button.volume_up.mask());
            if (action == .adjust_volume) {
                try std.testing.expect(action.adjust_volume <= 4);
                level += action.adjust_volume;
            }
        }
        try std.testing.expect(level >= 112);
        _ = policy.edge(.volume_up, false, now, .transport, 0);
        try std.testing.expectEqual(Action.none, policy.tick(now + 10000, .transport, 0, 0));
    }
}

test "list and grid windows stay row aligned while scrolling and changing layout" {
    for ([_]usize{ 1, 2, 3, 4 }) |columns| {
        const capacity = columns * 3;
        var first: usize = 0;
        for (0..100) |selected| {
            first = firstVisible(selected, first, capacity, columns);
            try std.testing.expectEqual(@as(usize, 0), first % columns);
            try std.testing.expect(selected >= first and selected < first + capacity);
        }
        first = firstVisible(7, first, capacity, columns);
        try std.testing.expect(7 >= first and 7 < first + capacity);
        first = firstVisible(0, first, capacity, columns);
        try std.testing.expectEqual(@as(usize, 0), first);
    }
}

test "Play taps select on release and holds open Now Playing once across contexts and cadences" {
    for (std.enums.values(Context)) |context| {
        var tap: Policy = .{};
        try std.testing.expectEqual(Action.none, tap.edge(.play, true, 100, context, 50));
        try std.testing.expectEqual(Action.none, tap.tick(150, context, 50, Button.play.mask()));
        try std.testing.expectEqual(Action.select, tap.edge(.play, false, 160, context, 50));
        try std.testing.expectEqual(Action.none, tap.tick(1000, context, 50, 0));
        for ([_]u64{ 5, 16, 33, 100, 600 }) |cadence| {
            var policy: Policy = .{};
            _ = policy.edge(.play, true, 0, context, 50);
            var count: usize = 0;
            var now = cadence;
            while (now < 2000) : (now += cadence) {
                const action = policy.tick(now, context, 50, Button.play.mask());
                if (action == .now_playing) count += 1 else try std.testing.expectEqual(Action.none, action);
            }
            try std.testing.expectEqual(1, count);
            try std.testing.expectEqual(Action.none, policy.edge(.play, false, 2000, context, 50));
        }
    }
}

test "captured Play releases distinguish long holds even without a timer poll" {
    for ([_]u64{ 1, 499, 500, 1000 }) |duration| {
        var policy: Policy = .{};
        _ = policy.edge(.play, true, 100, .list, 50);
        try std.testing.expectEqual(if (duration < 500) std.meta.Tag(Action).select else .now_playing, std.meta.activeTag(policy.edge(.play, false, 100 + duration, .list, 50)));
        try std.testing.expectEqual(Action.none, policy.edge(.play, false, 2000, .list, 50));
    }
    var policy: Policy = .{};
    _ = policy.edge(.play, true, 0, .covers, 50);
    try std.testing.expectEqual(Action.none, policy.tick(500, .covers, 50, 0));
    policy.cancel(Button.play.mask());
    try std.testing.expectEqual(Action.none, policy.tick(2000, .covers, 50, Button.play.mask()));
    try std.testing.expectEqual(Action.none, policy.edge(.play, false, 2001, .covers, 50));
    _ = policy.edge(.play, true, 2100, .covers, 50);
    try std.testing.expectEqual(Action.select, policy.edge(.play, false, 2160, .covers, 50));
}
