//! Coarse battery presentation. Voltage is an estimate, not a calibrated gauge.
const std = @import("std");

pub const Badge = enum { none, charging, plugged };

pub const Kind = enum { unknown, empty, low, normal, full };

pub const Status = struct {
    kind: Kind = .unknown,
    level: u3 = 0,
    charging: bool = false,
    external_power: bool = false,

    pub fn fromPower(millivolts: u32, charging: bool, external_power: bool) Status {
        var value = fromVoltage(millivolts, charging);
        value.external_power = external_power;
        return value;
    }

    pub fn badge(self: Status) Badge {
        if (self.charging) return .charging;
        return if (self.external_power) .plugged else .none;
    }

    pub fn fromVoltage(millivolts: u32, charging: bool) Status {
        if (millivolts == 0) return .{ .charging = charging };
        // Four visual levels avoid implying precise state of charge. Round
        // the voltage estimate so a near-full resting cell fills the icon.
        const empty_mv = 3400;
        const full_mv = 4200;
        const span = full_mv - empty_mv;
        const voltage = @min(full_mv, @max(empty_mv, millivolts)) - empty_mv;
        const level: u3 = @intCast((voltage * 4 + span / 2) / span);
        return .{ .kind = switch (level) {
            0 => .empty,
            1 => .low,
            4 => .full,
            else => .normal,
        }, .level = level, .charging = charging };
    }
};

/// Preserve a coarse level across load/USB voltage changes. Rising thresholds
/// are unchanged; falling needs 50 mV of margin. This is display hysteresis,
/// not a calibrated fuel gauge or a change to PMIC charging policy.
pub const Gauge = struct {
    value: Status = .{},
    const falling_margin_mv = 50;
    const thresholds_mv = [_]u32{ 3500, 3700, 3900, 4100 };

    pub fn update(self: *Gauge, millivolts: u32, charging: bool, external_power: bool) Status {
        if (millivolts == 0) return self.value;
        var next = Status.fromPower(millivolts, charging, external_power);
        if (self.value.kind != .unknown and next.level < self.value.level) {
            var level = self.value.level;
            while (level > next.level and millivolts +| falling_margin_mv < thresholds_mv[level - 1]) level -= 1;
            next.level = level;
            next.kind = switch (level) {
                0 => .empty,
                1 => .low,
                4 => .full,
                else => .normal,
            };
        }
        self.value = next;
        return next;
    }
};

test "unplugging and voltage noise do not immediately lower a full icon" {
    var gauge: Gauge = .{};
    try std.testing.expectEqual(@as(u3, 4), gauge.update(4150, false, true).level);
    const unplugged = gauge.update(4075, false, false);
    try std.testing.expectEqual(@as(u3, 4), unplugged.level);
    try std.testing.expectEqual(Badge.none, unplugged.badge());
    for ([_]u32{ 4090, 4060, 4105, 4070 }) |mv| try std.testing.expectEqual(@as(u3, 4), gauge.update(mv, false, false).level);
    try std.testing.expectEqual(@as(u3, 3), gauge.update(4040, false, false).level);
    try std.testing.expectEqual(@as(u3, 3), gauge.update(4080, false, false).level);
    try std.testing.expectEqual(@as(u3, 4), gauge.update(4120, false, false).level);
    // Cold estimates remain honest; plugged in alone does not imply full.
    gauge = .{};
    try std.testing.expectEqual(@as(u3, 3), gauge.update(4080, false, true).level);
    try std.testing.expectEqual(@as(u3, 1), gauge.update(3600, false, false).level);
    try std.testing.expectEqual(gauge.value, gauge.update(0, false, false));
}

pub const Sampling = struct {
    last_ms: ?u64 = null,

    pub fn due(self: *Sampling, now_ms: u64, has_voltage: bool) bool {
        const interval_ms: u64 = if (has_voltage) 10_000 else 250;
        if (self.last_ms) |last| if (now_ms -| last < interval_ms) return false;
        self.last_ms = now_ms;
        return true;
    }
};

test "unknown is distinct from empty and full has all four levels" {
    try std.testing.expectEqual(Kind.unknown, Status.fromVoltage(0, false).kind);
    try std.testing.expectEqual(Kind.empty, Status.fromVoltage(3300, false).kind);
    try std.testing.expectEqual(Kind.low, Status.fromVoltage(3600, false).kind);
    for ([_]u32{ 4140, 4200, 5000 }) |mv| {
        const value = Status.fromVoltage(mv, false);
        try std.testing.expectEqual(Kind.full, value.kind);
        try std.testing.expectEqual(4, value.level);
    }
    try std.testing.expect(Status.fromVoltage(3800, true).charging);
    var previous: u3 = 0;
    for (1..5000) |mv| {
        const value = Status.fromVoltage(@intCast(mv), false);
        try std.testing.expect(value.level >= previous and value.level <= 4);
        previous = value.level;
    }
}

test "first sample is immediate with bounded ADC warmup retries and steady sampling" {
    var sampling = Sampling{};
    try std.testing.expect(sampling.due(0, false));
    try std.testing.expect(!sampling.due(249, false));
    try std.testing.expect(sampling.due(250, false));
    try std.testing.expect(sampling.due(500, false));
    try std.testing.expect(!sampling.due(501, true));
    try std.testing.expect(sampling.due(10_500, true));
    try std.testing.expect(!sampling.due(10_501, true));
    try std.testing.expect(sampling.due(10_750, false));
}

test "external power and active charging remain distinct from voltage level" {
    try std.testing.expectEqual(Badge.none, Status.fromPower(4200, false, false).badge());
    try std.testing.expectEqual(Badge.plugged, Status.fromPower(4200, false, true).badge());
    try std.testing.expectEqual(Badge.charging, Status.fromPower(3800, true, true).badge());
    // A plug means external power without active charging, not proof of 100%.
    try std.testing.expectEqual(Badge.plugged, Status.fromPower(3800, false, true).badge());
    try std.testing.expectEqual(Kind.unknown, Status.fromPower(0, false, true).kind);
}
