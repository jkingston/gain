//! Player navigation policy. Physical edges and monotonic milliseconds enter;
//! bounded semantic actions leave. No rendering, allocation or host OS repeats.
const std = @import("std");
const capture = @import("input_capture.zig");
pub const Button = capture.Button;
pub const Context = enum { list, covers, transport };
pub const Action = union(enum) { none, move: i32, select, back, home, jump, previous, next, volume_up, volume_down };

const first_repeat_ms = 320;
const travel_start_ms = 900;
const travel_ramp_ms = 700;
const traversal_ms = 2000;
const wheel_reset_ms = 180;
const menu_hold_ms = 500;
const navigation_mask = Button.previous.mask() | Button.next.mask();

pub fn move(selection: usize, count: usize, delta: i32) usize {
    if (count == 0) return 0;
    const current = @min(selection, count - 1);
    return if (delta < 0) current -| @as(usize, @intCast(-@as(i64, delta))) else @min(count - 1, current +| @as(usize, @intCast(delta)));
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
            const active = self.held & ~self.suppressed & navigation_mask;
            self.direction = if (active == Button.next.mask()) 1 else if (active == Button.previous.mask()) -1 else 0;
            self.started_at = now;
            self.repeat_at = now +| first_repeat_ms;
            self.gesture_count = count;
            self.gesture_context = context;
            if (!pressed or self.direction == 0) return .none;
            if (context == .transport) return if (self.direction < 0) .previous else .next;
            return .{ .move = self.direction };
        }
        if (button == .menu) {
            if (pressed) {
                self.menu_at = now;
                self.menu_consumed = false;
                return .none;
            }
            defer self.menu_at = null;
            return if (self.menu_at != null and !self.menu_consumed) .home else .none;
        }
        if (!pressed) return .none;
        return switch (button) {
            .play => .select,
            .back => .back,
            .volume_up => .volume_up,
            .volume_down => .volume_down,
            .power, .menu, .previous, .next => .none,
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
    pub fn tick(self: *Policy, now: u64, context: Context, count: usize, raw_held: u8) Action {
        if (self.menu_at) |at| {
            if (!self.menu_consumed and raw_held & Button.menu.mask() != 0 and context != .transport and count > 8 and now -| at >= menu_hold_ms) {
                self.menu_consumed = true;
                self.direction = 0;
                self.suppressed |= self.held & navigation_mask;
                return .jump;
            }
        }
        if (context != self.gesture_context) {
            self.direction = 0;
            self.suppressed |= self.held & navigation_mask;
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
    try std.testing.expectEqual(.next, std.meta.activeTag(policy.edge(.next, true, 0, .transport, 1000)));
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.tick(5000, .transport, 1000, Button.next.mask())));
    policy.cancel(0);
    _ = policy.edge(.menu, true, 6000, .list, 1000);
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.tick(6499, .list, 1000, Button.menu.mask())));
    try std.testing.expectEqual(.jump, std.meta.activeTag(policy.tick(6500, .list, 1000, Button.menu.mask())));
    try std.testing.expectEqual(.none, std.meta.activeTag(policy.edge(.menu, false, 6600, .list, 1000)));
    _ = policy.edge(.menu, true, 7000, .list, 1000);
    try std.testing.expectEqual(.home, std.meta.activeTag(policy.edge(.menu, false, 7100, .list, 1000)));
}
