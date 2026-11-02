//! Fixed-priority task policy. The platform serializes calls with interrupts
//! masked; task execution and device operations happen outside this module.
const std = @import("std");

/// Declaration order is scheduling priority. Idle has no pending work.
pub const Task = enum(u3) { output, ui, control, codec, storage, idle };
pub const task_count = @backingInt(Task.idle);
pub const Events = u32;

pub const Wait = struct { events: Events, deadline: ?u64 = null };

const State = struct {
    pending: Events = 0,
    waiting: Events = 0,
    deadline: ?u64 = null,
    ready: bool = false,
    retired: bool = false,
};

pub const Executive = struct {
    tasks: [task_count]State = @splat(.{}),

    /// Notifications latch while a task is running or sleeping. A task waiting
    /// on other events stays blocked, preserving the notification for later.
    pub fn notify(self: *Executive, task: Task, events: Events) void {
        std.debug.assert(task != .idle and events != 0);
        const state = &self.tasks[@backingInt(task)];
        if (state.retired) return;
        state.pending |= events;
        if (state.waiting & events != 0) {
            state.ready = true;
            state.waiting = 0;
            state.deadline = null;
        }
    }

    pub fn start(self: *Executive, task: Task) void {
        std.debug.assert(task != .idle);
        const state = &self.tasks[@backingInt(task)];
        if (state.retired) state.* = .{};
        state.ready = true;
    }

    /// A completed worker owns no outstanding work. Late notifications cannot
    /// resurrect it or turn a quiescent task into a busy wait loop.
    pub fn retire(self: *Executive, task: Task) void {
        std.debug.assert(task != .idle);
        self.tasks[@backingInt(task)] = .{ .retired = true };
    }

    /// Used under the same interrupt mask as the work predicate and context
    /// switch. An already-latched event must never be followed by sleep.
    pub fn wait(self: *Executive, task: Task, condition: Wait, now: u64) void {
        std.debug.assert(task != .idle);
        const state = &self.tasks[@backingInt(task)];
        std.debug.assert(!state.retired);
        state.waiting = condition.events;
        state.deadline = condition.deadline;
        state.ready = state.pending & condition.events != 0 or
            (condition.deadline != null and condition.deadline.? <= now);
        if (state.ready) {
            state.waiting = 0;
            state.deadline = null;
        }
    }

    pub fn take(self: *Executive, task: Task, mask: Events) Events {
        std.debug.assert(task != .idle);
        const state = &self.tasks[@backingInt(task)];
        const result = state.pending & mask;
        state.pending &= ~mask;
        return result;
    }

    pub fn wakeExpired(self: *Executive, now: u64) void {
        for (&self.tasks) |*state| {
            if (state.deadline) |deadline| if (deadline <= now) {
                state.ready = true;
                state.waiting = 0;
                state.deadline = null;
            };
        }
    }

    pub fn select(self: *const Executive) Task {
        for (self.tasks, 0..) |state, i| if (state.ready) return @fromBackingInt(@intCast(i));
        return .idle;
    }

    pub fn nextDeadline(self: *const Executive) ?u64 {
        var next: ?u64 = null;
        for (self.tasks) |state| if (state.deadline) |deadline| {
            if (next == null or deadline < next.?) next = deadline;
        };
        return next;
    }
};

/// Extend a wrapping hardware counter. The platform must sample at least once
/// per counter revolution, including while idle; deadlines enforce that wake.
pub const Clock = struct {
    previous: u32,
    ticks: u64 = 0,

    pub fn sample(self: *Clock, counter: u32) u64 {
        self.ticks += counter -% self.previous;
        self.previous = counter;
        return self.ticks;
    }
};

test "pending notifications prevent sleep in either arrival ordering" {
    for ([_]bool{ false, true }) |before| {
        var executive = Executive{};
        executive.start(.codec);
        if (before) executive.notify(.codec, 1);
        executive.wait(.codec, .{ .events = 1 }, 0);
        if (!before) executive.notify(.codec, 1);
        try std.testing.expectEqual(Task.codec, executive.select());
        try std.testing.expectEqual(@as(Events, 1), executive.take(.codec, 1));
        executive.wait(.codec, .{ .events = 1 }, 1);
        try std.testing.expectEqual(Task.idle, executive.select());
    }
}

test "higher priority work preempts without dropping lower priority readiness" {
    var executive = Executive{};
    executive.start(.storage);
    executive.start(.codec);
    executive.start(.ui);
    try std.testing.expectEqual(Task.ui, executive.select());
    executive.notify(.output, 1);
    executive.wait(.output, .{ .events = 1 }, 0);
    try std.testing.expectEqual(Task.output, executive.select());
    _ = executive.take(.output, 1);
    executive.wait(.output, .{ .events = 1 }, 0);
    try std.testing.expectEqual(Task.ui, executive.select());
    executive.wait(.ui, .{ .events = 1 }, 0);
    try std.testing.expectEqual(Task.codec, executive.select());
}

test "unrelated events latch without waking a blocked task" {
    var executive = Executive{};
    executive.wait(.storage, .{ .events = 2 }, 0);
    executive.notify(.storage, 1);
    try std.testing.expectEqual(Task.idle, executive.select());
    executive.notify(.storage, 2);
    try std.testing.expectEqual(Task.storage, executive.select());
    try std.testing.expectEqual(@as(Events, 2), executive.take(.storage, 2));
    try std.testing.expectEqual(@as(Events, 1), executive.take(.storage, 1));
}

test "deadlines wake exactly once including coincident notifications" {
    var executive = Executive{};
    executive.wait(.ui, .{ .events = 1, .deadline = 30 }, 0);
    executive.wait(.output, .{ .events = 2, .deadline = 20 }, 0);
    try std.testing.expectEqual(@as(?u64, 20), executive.nextDeadline());
    executive.wakeExpired(19);
    try std.testing.expectEqual(Task.idle, executive.select());
    executive.wakeExpired(20);
    executive.notify(.output, 2);
    try std.testing.expectEqual(Task.output, executive.select());
    _ = executive.take(.output, 2);
    executive.wait(.output, .{ .events = 2 }, 20);
    try std.testing.expectEqual(@as(?u64, 30), executive.nextDeadline());
    executive.wakeExpired(30);
    try std.testing.expectEqual(Task.ui, executive.select());
    try std.testing.expectEqual(@as(?u64, null), executive.nextDeadline());
}

test "hardware wrap preserves monotonic deadlines" {
    var clock = Clock{ .previous = 0xfffffff0 };
    try std.testing.expectEqual(@as(u64, 15), clock.sample(0xffffffff));
    try std.testing.expectEqual(@as(u64, 17), clock.sample(1));
    var executive = Executive{};
    executive.wait(.output, .{ .events = 1, .deadline = 30 }, clock.ticks);
    executive.wakeExpired(clock.sample(13));
    try std.testing.expectEqual(Task.idle, executive.select());
    executive.wakeExpired(clock.sample(14));
    try std.testing.expectEqual(Task.output, executive.select());
}

test "retired workers discard latched events deadlines and late completions" {
    var executive = Executive{};
    executive.start(.codec);
    executive.notify(.codec, 7);
    executive.wait(.codec, .{ .events = 8, .deadline = 20 }, 0);
    executive.retire(.codec);
    executive.notify(.codec, 0xffffffff);
    executive.wakeExpired(100);
    try std.testing.expectEqual(Task.idle, executive.select());
    try std.testing.expectEqual(@as(?u64, null), executive.nextDeadline());
    try std.testing.expectEqual(@as(Events, 0), executive.take(.codec, 0xffffffff));
    executive.start(.codec);
    try std.testing.expectEqual(Task.codec, executive.select());
}
