//! Retargetable UI animation. Audio volume changes immediately in the backend.
const std = @import("std");

pub const Transition = struct {
    pub const fade_ms = 140;
    pub const value_ms = 90;
    pub const hold_ms = 1400;
    from_mix: f32 = 0,
    to_mix: f32 = 0,
    mix_at: u64 = 0,
    from_value: f32 = 50,
    to_value: f32 = 50,
    value_at: u64 = 0,
    until: u64 = 0,
    reduced_motion: bool = false,
    last_mix: f32 = -1,
    last_value: f32 = -1,

    fn ease(age: u64, duration: u64) f32 {
        const t: f32 = @as(f32, @floatFromInt(@min(age, duration))) / @as(f32, @floatFromInt(duration));
        return 1 - (1 - t) * (1 - t) * (1 - t);
    }

    pub fn mix(self: Transition, now: u64) f32 {
        return if (self.reduced_motion) self.to_mix else self.from_mix + (self.to_mix - self.from_mix) * ease(now -| self.mix_at, fade_ms);
    }

    pub fn value(self: Transition, now: u64) f32 {
        return if (self.reduced_motion) self.to_value else self.from_value + (self.to_value - self.from_value) * ease(now -| self.value_at, value_ms);
    }

    pub fn isAnimating(self: Transition, now: u64) bool {
        if (self.reduced_motion) return false;
        if (self.from_mix != self.to_mix and now -| self.mix_at < fade_ms) return true;
        if (self.to_mix == 1 and now >= self.until and now - self.until < fade_ms) return true;
        return self.mix(now) > 0 and self.from_value != self.to_value and now -| self.value_at < value_ms;
    }

    pub fn request(self: *Transition, now: u64, value_percent: f32) void {
        self.from_mix = self.mix(now);
        self.to_mix = 1;
        self.mix_at = now;
        self.from_value = self.value(now);
        self.to_value = std.math.clamp(value_percent, 0, 100);
        self.value_at = now;
        self.until = now + hold_ms;
    }

    pub fn tick(self: *Transition, now: u64) bool {
        if (self.to_mix == 1 and now >= self.until) {
            self.from_mix = self.mix(self.until);
            self.to_mix = 0;
            self.mix_at = self.until;
        }
        const m = self.mix(now);
        const v = self.value(now);
        const dirty = m != self.last_mix or (m > 0 and v != self.last_value);
        self.last_mix = m;
        self.last_value = v;
        return dirty;
    }
};

test "fade, hold and return have exact endpoints and no idle animation" {
    var t: Transition = .{};
    t.request(100, 60);
    try std.testing.expectEqual(@as(f32, 0), t.mix(100));
    try std.testing.expect(t.mix(116) > 0 and t.mix(116) < 1);
    try std.testing.expectEqual(@as(f32, 1), t.mix(240));
    try std.testing.expectEqual(@as(f32, 60), t.value(190));
    _ = t.tick(1500);
    try std.testing.expectEqual(@as(f32, 1), t.mix(1500));
    _ = t.tick(1640);
    try std.testing.expectEqual(@as(f32, 0), t.mix(1640));
    try std.testing.expect(!t.tick(2000));
}

test "repeated presses and reversal begin at current presentation, without jumps" {
    var t: Transition = .{};
    t.request(100, 60);
    const m = t.mix(150);
    const v = t.value(150);
    t.request(150, 70);
    try std.testing.expectEqual(m, t.mix(150));
    try std.testing.expectEqual(v, t.value(150));
    _ = t.tick(t.until + 50);
    const returning = t.mix(t.until + 50);
    t.request(t.until + 50, 75);
    try std.testing.expectEqual(returning, t.mix(t.mix_at));
    t.reduced_motion = true;
    t.request(5000, 100);
    try std.testing.expectEqual(@as(f32, 1), t.mix(5000));
    try std.testing.expectEqual(@as(f32, 100), t.value(5000));
}

test "animation activity excludes a stable hold and includes its scheduled fade out" {
    var transition: Transition = .{};
    transition.request(100, 75);
    try std.testing.expect(transition.isAnimating(100));
    try std.testing.expect(transition.isAnimating(239));
    try std.testing.expect(!transition.isAnimating(240));
    try std.testing.expect(!transition.isAnimating(1499));
    try std.testing.expect(transition.isAnimating(1500));
    _ = transition.tick(1500);
    try std.testing.expect(transition.isAnimating(1639));
    try std.testing.expect(!transition.isAnimating(1640));
}
