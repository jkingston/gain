//! Scanline projection and conservative F20 region scheduling; no MMIO.
const std = @import("std");

const clock = struct {
    const tick_period = 6_000;

    fn before(a: u32, b: u32) bool {
        return @as(i32, @bitCast(a -% b)) < 0;
    }
};

pub const Sample = struct { began: u32, ended: u32, line: u32 };
pub const maximum_read_ticks = 300; // 50 us; retry a sample preempted by audio.
pub const prepare_lead = 18_000; // 3 ms covers audio preemption plus wrap rendering.
pub const target_line = 160; // Beyond the central 108..131 animation lane.

pub const Config = struct {
    period: u32,
    lines: u32,

    pub fn validate(self: Config) !void {
        if (self.lines != 244 or self.period < 80_000 or self.period > 100_000) return error.PanelCalibration;
    }

    pub fn nextTarget(self: Config, sample: Sample, now: u32, minimum_lead: u32) !u32 {
        return self.nextTargetLine(sample, now, minimum_lead, target_line);
    }

    pub fn nextTargetLine(self: Config, sample: Sample, now: u32, minimum_lead: u32, target: u32) !u32 {
        try self.validate();
        if (target >= self.lines or minimum_lead > self.period) return error.PanelPhase;
        if (sample.line >= self.lines or sample.ended -% sample.began > maximum_read_ticks) return error.PanelSample;
        const at = sample.began +% ((sample.ended -% sample.began) / 2);
        if (now -% at > clock.tick_period * 2) return error.PanelSampleStale;
        // A scanline reports a bucket, not an edge. Use its centre and retain
        // about half a line of phase uncertainty instead of inventing precision.
        const line_delta = @as(i32, @intCast(target)) - @as(i32, @intCast(sample.line));
        const offset = @divTrunc(@as(i64, line_delta) * self.period - self.period / 2, self.lines);
        var deadline = at +% @as(u32, @bitCast(@as(i32, @intCast(offset))));
        // A retarget may be just behind the current scanline. Reaching that
        // phase in the next cycle can still leave too little preparation time.
        // At most two wraps are needed for this bounded lead and fresh sample.
        for (0..2) |_| {
            if (clock.before(deadline, now +% minimum_lead)) deadline +%= self.period;
        }
        if (clock.before(deadline, now +% minimum_lead) or deadline -% now > self.period + minimum_lead) return error.PanelPhase;
        return deadline;
    }
};

test "line target survives timer wrap and noisy bucket observations" {
    const config = Config{ .period = 87_480, .lines = 244 };
    for ([_]u32{ 0, 0xffff_f000 }) |origin| {
        for (0..244) |line| {
            const at = origin +% @as(u32, @intCast(line * config.period / config.lines));
            const sample = Sample{ .began = at -% 57, .ended = at +% 57, .line = @intCast(line) };
            const target = try config.nextTarget(sample, sample.ended, prepare_lead + 6_000);
            try std.testing.expect(target -% sample.ended >= prepare_lead + 6_000);
            const expected = origin +% (target_line * config.period / config.lines);
            const error_ticks = @min(target -% expected, expected -% target);
            const folded = @min(error_ticks % config.period, config.period - error_ticks % config.period);
            try std.testing.expect(folded <= config.period / config.lines);
        }
    }
}

test "unknown counters slow samples and stale phase fail explicitly" {
    const config = Config{ .period = 87_480, .lines = 244 };
    try std.testing.expectError(error.PanelCalibration, (Config{ .period = 87_480, .lines = 264 }).validate());
    try std.testing.expectError(error.PanelSample, config.nextTarget(.{ .began = 0, .ended = 301, .line = 100 }, 301, 1));
    try std.testing.expectError(error.PanelSample, config.nextTarget(.{ .began = 0, .ended = 114, .line = 244 }, 114, 1));
    try std.testing.expectError(error.PanelSampleStale, config.nextTarget(.{ .began = 0, .ended = 114, .line = 100 }, 13_000, 1));
}

test "geometry retarget just behind the beam reserves another complete cycle" {
    const config = Config{ .period = 87_480, .lines = 244 };
    const scan = Sample{ .began = 1_000_000, .ended = 1_000_114, .line = 240 };
    const deadline = try config.nextTargetLine(scan, scan.ended, 24_000, 10);
    try std.testing.expect(deadline -% scan.ended >= 24_000);
    try std.testing.expect(deadline -% scan.ended <= 24_000 + config.period);
}

fn blockedRows(rect: @import("presentation.zig").Region) [244]bool {
    var blocked: [244]bool = @splat(false);
    if (rect.width == 0 or rect.height == 0 or @as(u32, rect.x) + rect.width > 320 or @as(u32, rect.y) + rect.height > 240) return @splat(true);
    // Until scan direction is separately proven, exclude both possible row
    // mappings, with four lines of uncertainty at each boundary.
    for (rect.y..rect.y + rect.height) |row| {
        for ([_]usize{ row, 239 - row }) |physical| {
            for (0..9) |offset| blocked[(physical + 244 + offset - 4) % 244] = true;
        }
    }
    return blocked;
}

pub fn safeLines(rect: @import("presentation.zig").Region, target: u32) u32 {
    if (target >= 244) return 0;
    const blocked = blockedRows(rect);
    var distance: u32 = 0;
    while (distance < 244 and !blocked[(target + distance) % 244]) distance += 1;
    return distance;
}

pub fn regionTarget(rect: @import("presentation.zig").Region, period: u32, previous: u32) !u32 {
    try (Config{ .period = period, .lines = 244 }).validate();
    if (previous >= 244) return error.PanelPhase;
    _ = try @import("presentation.zig").alignedRegion(rect, 320, 240);
    const blocked = blockedRows(rect);
    // Include one 1 kHz polling interval: observed BUSY-clear must fit the
    // reserved window too, not just an optimistic on-wire byte estimate.
    const required = @as(u32, rect.width) * rect.height * 2 + 6_600;
    const needed = (required * 244 + period - 1) / period + 2;
    var remaining: u32 = 0;
    while (remaining < needed and !blocked[(previous + remaining) % 244]) remaining += 1;
    if (remaining >= needed) return previous;
    // Two bounded passes expose the run that crosses counter zero. Unlike
    // scanning forward from every candidate this is linear in panel height.
    var best: u32 = 0;
    var longest: u32 = 0;
    var run: u32 = 0;
    for (0..488) |index| {
        if (blocked[index % 244]) {
            run = 0;
        } else {
            run += 1;
            if (run > longest) {
                longest = run;
                best = @intCast((index + 1 - run) % 244);
            }
        }
    }
    if (longest < needed) return error.NoSafeRegionPhase;
    return best;
}

pub const Launch = enum { wait, commit, retarget };

/// Cooperative callers must re-sample a missed deadline, never issue a late
/// transfer into a region which scanout may already have reached.
pub fn launchAt(now: u32, deadline: u32) Launch {
    if (clock.before(now, deadline)) return .wait;
    return if (now -% deadline <= 120) .commit else .retarget;
}

test "late decode cannot launch a prepared surface into the scan beam" {
    for ([_]u32{ 1000, 0xfffffff0 }) |deadline| {
        try std.testing.expectEqual(Launch.wait, launchAt(deadline -% 1, deadline));
        try std.testing.expectEqual(Launch.commit, launchAt(deadline, deadline));
        try std.testing.expectEqual(Launch.commit, launchAt(deadline +% 120, deadline));
        try std.testing.expectEqual(Launch.retarget, launchAt(deadline +% 121, deadline));
        try std.testing.expectEqual(Launch.retarget, launchAt(deadline +% (49 * 6000), deadline));
    }
}

test "every player damage region reserves bus drain and a scanline guard" {
    const Region = @import("presentation.zig").Region;
    for ([_]Region{ .{
        .x = 275,
        .y = 7,
        .width = 18,
        .height = 7,
    }, .{ .x = 0, .y = 180, .width = 320, .height = 42 }, .{ .x = 7, .y = 59, .width = 306, .height = 23 } }) |region| {
        for (0..244) |previous| {
            const target = try regionTarget(region, 87480, @intCast(previous));
            const required = region.pixels() * 2 + 6600;
            try std.testing.expect(safeLines(region, target) * 87480 / 244 > required);
        }
    }
    try std.testing.expectError(error.NoSafeRegionPhase, regionTarget(.{ .x = 0, .y = 0, .width = 320, .height = 240 }, 87480, 160));
}

test "invalid safe window geometry and counters fail before arithmetic" {
    try std.testing.expectError(error.PanelCalibration, regionTarget(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, 0, 160));
    try std.testing.expectError(error.PanelPhase, regionTarget(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, 87480, 0xffffffff));
    try std.testing.expectError(error.InvalidRegion, regionTarget(.{ .x = 0, .y = 240, .width = 2, .height = 2 }, 87480, 160));
    try std.testing.expectEqual(@as(u32, 0), safeLines(.{ .x = 0, .y = 0, .width = 65535, .height = 65535 }, 160));
}
