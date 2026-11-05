//! Bounded cover-load priorities from current motion and semantic input intent.
//! No allocation, I/O or rendering; speculative requests never displace visibility.
const std = @import("std");
const navigation = @import("navigation.zig");

pub const Intent = struct { rank: usize, at_ms: u64 };

pub const PlanInput = struct {
    now_ms: u64,
    position: f32,
    selected: usize,
    count: usize,
    latency_ms: u32 = 30,
    next: ?Intent = null,
};

pub const Plan = struct {
    ranks: [10]usize = undefined,
    count: usize = 0,
    eligible: u10 = 0,

    fn add(self: *Plan, rank: usize, anchor: usize, speculative: *u3) void {
        for (self.ranks[0..self.count]) |old| if (old == rank) return;
        const outside = rank < anchor -| 3 or rank > anchor +| 3;
        if (outside and speculative.* == 3) return;
        if (self.count == self.ranks.len) return;
        if (outside) speculative.* += 1;
        self.ranks[self.count] = rank;
        const bit = @as(u10, 1) << @intCast(self.count);
        self.eligible |= bit;
        self.count += 1;
    }
};

/// Predict the next semantic action from a copy of the real input policy.
/// A raw release suppresses prediction before debounce; no physical input is
/// consumed and no large-jump interpolation velocity is extrapolated.
pub fn repeatIntent(policy: navigation.Policy, selected: usize, count: usize, raw_held: u8, now_ms: u64) ?Intent {
    if (policy.direction == 0 or count == 0) return null;
    var copy = policy;
    const at = @max(now_ms, copy.repeat_at);
    const action = copy.tick(at, .covers, count, raw_held);
    if (action != .move) return null;
    const target = navigation.move(selected, count, action.move);
    return if (target == selected) null else .{ .rank = target, .at_ms = at };
}

fn inside(rank: usize, anchor: usize, count: usize) bool {
    return rank >= anchor -| 3 and rank <= @min(count - 1, anchor +| 3);
}

pub fn plan(input: PlanInput) Plan {
    var result = Plan{};
    if (input.count == 0) return result;
    const selected = @min(input.selected, input.count - 1);
    const anchor = if (std.math.isFinite(input.position)) @as(usize, @intFromFloat(std.math.clamp(@round(input.position), 0, @as(f32, @floatFromInt(input.count - 1))))) else selected;
    const latency = std.math.clamp(input.latency_ms, 4, 100);
    const horizon = @min(160, @max(40, latency * 2 + 16));
    const next: ?Intent = if (input.next) |intent| if (intent.rank < input.count and intent.rank != selected and intent.at_ms -| input.now_ms <= horizon and input.now_ms -| intent.at_ms <= 16) intent else null else null;
    const direction: i32 = if (next) |intent| if (intent.rank > selected) 1 else -1 else if (selected >= anchor) 1 else -1;
    var speculative: u3 = 0;
    result.add(selected, anchor, &speculative);
    if (next) |intent| {
        // Rapid jumps can consume almost the entire two-load budget between
        // repeats. The next centre outranks an already-departing side cover.
        result.add(intent.rank, anchor, &speculative);
        // A Rapid jump starts one album before its destination. Prepare that
        // arrival side before spending the remaining budget on departing sides.
        const arrival = @as(i64, @intCast(intent.rank)) - direction;
        if (arrival >= 0 and arrival < input.count) result.add(@intCast(arrival), anchor, &speculative);
    }
    result.add(anchor, anchor, &speculative);
    for ([_]i32{ 1, -1, 2, -2, 3, -3 }) |offset| {
        const rank = @as(i64, @intCast(anchor)) + offset * direction;
        if (rank >= 0 and rank < input.count) result.add(@intCast(rank), anchor, &speculative);
    }
    const destination = if (next) |intent| intent.rank else selected;
    for ([_]i32{ 1, -1 }) |offset| {
        const rank = @as(i64, @intCast(destination)) + offset * direction;
        if (rank >= 0 and rank < input.count) result.add(@intCast(rank), anchor, &speculative);
    }
    if (next) |intent| {
        if (intent.at_ms -| input.now_ms < latency) {
            // Keep every visible cover pinned, but do not start work that cannot
            // finish before that cover leaves the next requested window.
            for (result.ranks[0..result.count], 0..) |rank, i| if (!inside(rank, intent.rank, input.count)) {
                result.eligible &= ~(@as(u10, 1) << @intCast(i));
            };
        }
    }
    return result;
}

test "Rapid intent is the real next action through acceleration and release" {
    var policy = navigation.Policy{};
    const mask = navigation.Button.next.mask();
    var selected = navigation.move(0, 8192, policy.edge(.next, true, 0, .covers, 8192).move);
    var predicted = repeatIntent(policy, selected, 8192, mask, 0).?;
    var actual_moves: usize = 0;
    var largest_move: i32 = 0;
    for (0..4000) |now| {
        const action = policy.tick(now, .covers, 8192, mask);
        if (action == .move) {
            const actual_selected = navigation.move(selected, 8192, action.move);
            try std.testing.expectEqual(now, predicted.at_ms);
            try std.testing.expectEqual(actual_selected, predicted.rank);
            largest_move = @max(largest_move, action.move);
            selected = actual_selected;
            actual_moves += 1;
        }
        predicted = repeatIntent(policy, selected, 8192, mask, now).?;
        try std.testing.expect(repeatIntent(policy, selected, 8192, 0, now) == null);
    }
    try std.testing.expect(actual_moves > 20);
    try std.testing.expectEqual(24, largest_move);
    _ = policy.edge(.next, false, 4000, .covers, 8192);
    try std.testing.expect(repeatIntent(policy, selected, 8192, mask, 4000) == null);
    _ = policy.edge(.previous, true, 4010, .covers, 8192);
    try std.testing.expect(repeatIntent(policy, selected, 8192, navigation.Button.previous.mask(), 4010).?.rank < selected);
}

test "request plan protects all visible covers with at most three speculative slots" {
    for ([_]usize{ 0, 1, 4, 12, 257, 1024 }) |count| for (0..count) |selected| {
        const next = @min(count - 1, selected +| 24);
        const current = plan(.{ .now_ms = 100, .position = @as(f32, @floatFromInt(selected)) - 0.75, .selected = selected, .count = count, .next = .{ .rank = next, .at_ms = 170 } });
        try std.testing.expect(current.count <= 10);
        const anchor = selected -| 1;
        var visible_count: usize = 0;
        for (anchor -| 3..@min(count, anchor +| 4)) |visible| {
            var found = false;
            for (current.ranks[0..current.count]) |rank| if (rank == visible) {
                found = true;
            };
            try std.testing.expect(found);
            visible_count += 1;
        }
        try std.testing.expect(current.count - visible_count <= 3);
        for (current.ranks[0..current.count], 0..) |rank, i| {
            try std.testing.expect(rank < count);
            for (current.ranks[0..i]) |earlier| try std.testing.expect(rank != earlier);
        }
    };
    try std.testing.expectEqual(0, plan(.{ .now_ms = 0, .position = 0, .selected = 0, .count = 0 }).count);
}

test "selected and next centres outrank sides while expiry never unpins a visible cover" {
    const input = PlanInput{ .now_ms = 100, .position = 23.2, .selected = 24, .count = 512, .next = .{ .rank = 48, .at_ms = 170 } };
    const early = plan(input);
    try std.testing.expectEqual(24, early.ranks[0]);
    try std.testing.expectEqual(48, early.ranks[1]);
    try std.testing.expectEqual(47, early.ranks[2]);
    var late_input = input;
    late_input.now_ms = 150;
    const late = plan(late_input);
    try std.testing.expectEqualSlices(usize, early.ranks[0..early.count], late.ranks[0..late.count]);
    for (late.ranks[0..late.count], 0..) |rank, i| {
        try std.testing.expectEqual(inside(rank, 48, 512), late.eligible & (@as(u10, 1) << @intCast(i)) != 0);
    }
    late_input.next = null;
    const released = plan(late_input);
    try std.testing.expectEqual(7, released.count);
    late_input.next = .{ .rank = 0, .at_ms = 190 };
    try std.testing.expectEqual(0, plan(late_input).ranks[1]);
    try std.testing.expectEqual(1, plan(late_input).ranks[2]);
}

test "distant retargets at library edges cannot spend visible-cover capacity on speculation" {
    for ([_]usize{ 8, 64, 512 }) |count| for ([_]usize{ 0, count / 2, count - 1 }) |anchor| {
        for ([_]usize{ 0, count / 2, count - 1 }) |selected| {
            const current = plan(.{ .now_ms = 100, .position = @floatFromInt(anchor), .selected = selected, .count = count, .next = .{ .rank = count - 1 - selected, .at_ms = 150 } });
            var speculative: usize = 0;
            for (current.ranks[0..current.count]) |rank| if (!inside(rank, anchor, count)) {
                speculative += 1;
            };
            try std.testing.expect(speculative <= 3);
            for (anchor -| 3..@min(count, anchor +| 4)) |visible| try std.testing.expect(std.mem.indexOfScalar(usize, current.ranks[0..current.count], visible) != null);
        }
    };
}
