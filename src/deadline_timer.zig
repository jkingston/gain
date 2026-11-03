//! Combine a wrap-safe peripheral deadline with the executive's next wakeup.
const std = @import("std");

pub const LaunchOwner = enum { poll, interrupt };

/// Only a missed interrupt deadline returns preparation work to the UI.
pub fn pollMayHandle(owner: LaunchOwner, missed: bool) bool {
    return owner == .poll or missed;
}

pub fn delay(now: u32, peripheral: ?u32, task_delay: u64, maximum: u32) u32 {
    var result = @max(1, @min(task_delay, maximum));
    if (peripheral) |at| {
        const remaining = @as(i32, @bitCast(at -% now));
        result = @min(result, @as(u64, @intCast(@max(1, remaining))));
    }
    return @intCast(result);
}

test "peripheral wakeup remains precise across timer wrap and never delays audio" {
    for ([_]u32{ 1000, 0xfffffff0 }) |now| {
        try std.testing.expectEqual(300, delay(now, now +% 300, 6000, 0x7fffffff));
        try std.testing.expectEqual(100, delay(now, now +% 300, 100, 0x7fffffff));
        try std.testing.expectEqual(1, delay(now, now -% 1, 6000, 0x7fffffff));
        try std.testing.expectEqual(6000, delay(now, null, 6000, 0x7fffffff));
    }
}

test "deterministic replay reproduces coarse polling misses and precise launches" {
    const phase = @import("display_phase.zig");
    const period = 87480;
    var coarse_misses: u32 = 0;
    for (0..6000) |offset| {
        const deadline: u32 = 0xfffffff0 +% @as(u32, @intCast(offset));
        const polled = deadline +% @as(u32, @intCast((6000 - offset) % 6000));
        if (phase.launchAt(polled, deadline) == .retarget) coarse_misses += 1;
        // A timer rearmed at each actual launch phase produces no drift.
        var next = deadline;
        for (0..8) |_| {
            const before = next -% 6000;
            const wake = before +% delay(before, next, 6000, 0x7fffffff);
            try std.testing.expectEqual(phase.Launch.commit, phase.launchAt(wake, next));
            next +%= period;
        }
        // A delayed IRQ still declines an unsafe launch; UI must re-prepare.
        try std.testing.expectEqual(phase.Launch.retarget, phase.launchAt(deadline +% 121, deadline));
    }
    try std.testing.expectEqual(5879, coarse_misses);
}

test "deterministic interrupt interleavings reproduce double launch and enforce one owner" {
    const presentation = @import("presentation.zig");
    // IRQ before the poll reads state, after the read, at its time test,
    // immediately before its commit, and after the old poll commits.
    for (0..5) |cut| {
        var old: presentation.State = .{};
        try old.prepare();
        const saw_prepared = cut != 0;
        if (cut < 4) try old.commit(1000);
        if (saw_prepared and cut < 4) try std.testing.expectError(error.NotPrepared, old.commit(1001));
        if (cut == 4) try old.commit(1000);

        var fixed: presentation.State = .{};
        try fixed.prepare();
        var launches: u32 = 0;
        for (0..5) |point| {
            if (point == cut) {
                try fixed.commit(1000);
                launches += 1;
            }
            if (fixed.phase == .prepared and pollMayHandle(.interrupt, false)) {
                try fixed.commit(1000);
                launches += 1;
            }
        }
        try std.testing.expectEqual(1, launches);
        try std.testing.expectEqual(presentation.Phase.transferring, fixed.phase);
    }
    try std.testing.expect(pollMayHandle(.poll, false));
    try std.testing.expect(pollMayHandle(.interrupt, true));
    try std.testing.expect(!pollMayHandle(.interrupt, false));
}
