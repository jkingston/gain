//! Register-frame transitions shared by native traps and deterministic tests.
const std = @import("std");
const executive = @import("executive.zig");
pub const Context = @import("task_context.zig").Context;

pub const Task = executive.Task;

pub const Operation = enum(u32) { reschedule, wait, stop, retire };
pub const no_deadline = std.math.maxInt(u64);
const instruction_bytes = 4;

pub const Scheduler = struct {
    policy: executive.Executive = .{},
    contexts: [executive.task_count + 1]Context = @splat(.{}),
    current: Task = .idle,
    running: bool = true,
    entered: bool = false,
    caller: Context = .{},

    pub fn trap(self: *Scheduler, frame: *Context, now: u64) error{InvalidTrap}!void {
        const operation = std.enums.fromInt(Operation, frame.argument(0)) orelse return error.InvalidTrap;
        if (operation != .reschedule and self.current == .idle) return error.InvalidTrap;
        const entering = operation == .reschedule and self.current == .idle and !self.entered;
        switch (operation) {
            .reschedule => {},
            .wait => {
                const ticks = @as(u64, frame.argument(3)) << 32 | frame.argument(2);
                self.policy.wait(self.current, .{ .events = frame.argument(1), .deadline = if (ticks == no_deadline) null else ticks }, now);
            },
            .stop => self.running = false,
            .retire => self.policy.retire(self.current),
        }
        frame.epc +%= instruction_bytes;
        if (entering) {
            self.caller = frame.*;
            self.entered = true;
        }
    }

    /// An unchanged selection returns the live frame, never an older snapshot.
    pub fn select(self: *Scheduler, frame: *Context) *Context {
        if (!self.running) {
            // The most recent idle frame may resume at WAIT after the timer
            // has been disabled. Return to the original call continuation so
            // Runtime.run observes shutdown before it can sleep again.
            self.current = .idle;
            return &self.caller;
        }
        // Startup belongs to the explicit entry trap. An early peripheral
        // interrupt must not dispatch workers before their caller is saved.
        if (!self.entered and self.current == .idle) return frame;
        const selected = self.policy.select();
        const incoming = if (selected == self.current) frame else switched: {
            self.contexts[@backingInt(self.current)] = frame.*;
            self.current = selected;
            break :switched &self.contexts[@backingInt(selected)];
        };
        // Idle inherits the entry continuation, whose IE was deliberately
        // masked. Enable wakeups through ERET before idle can execute WAIT.
        // Shutdown returns the separate caller above with its mask intact.
        if (selected == .idle) incoming.status |= Context.interrupt_enable;
        return incoming;
    }
};

fn request(operation: Operation, events: u32, deadline: ?u64) Context {
    var frame = Context{};
    frame.registers_1_to_25[3] = @backingInt(operation);
    frame.registers_1_to_25[4] = events;
    const ticks = deadline orelse no_deadline;
    frame.registers_1_to_25[5] = @truncate(ticks);
    frame.registers_1_to_25[6] = @truncate(ticks >> 32);
    return frame;
}

test "start wait preempt and stop restore the interrupted caller" {
    var scheduler = Scheduler{};
    scheduler.policy.start(.output);
    scheduler.policy.start(.codec);
    var caller = request(.reschedule, 0, null);
    caller.epc = 0x1000;
    caller.sp = 0x1234;
    caller.floating_control = 3;
    caller.floating_registers[31] = 0x12345678;
    try scheduler.trap(&caller, 0);
    _ = scheduler.select(&caller);
    try std.testing.expectEqual(Task.output, scheduler.current);
    var output = request(.wait, 1, 100);
    output.epc = 0x2000;
    output.floating_registers[0] = 0x3f800000;
    try scheduler.trap(&output, 10);
    _ = scheduler.select(&output);
    try std.testing.expectEqual(Task.codec, scheduler.current);
    scheduler.policy.wakeExpired(100);
    var codec = Context{ .epc = 0x3000, .floating_control = 1 };
    const restored = scheduler.select(&codec);
    try std.testing.expectEqual(Task.output, scheduler.current);
    try std.testing.expectEqual(@as(u32, 0x2004), restored.epc);
    try std.testing.expectEqual(@as(u32, 0x3f800000), restored.floating_registers[0]);
    restored.registers_1_to_25[3] = @backingInt(Operation.stop);
    try scheduler.trap(restored, 110);
    const returned = scheduler.select(restored);
    try std.testing.expectEqual(Task.idle, scheduler.current);
    try std.testing.expectEqual(@as(u32, 0x1004), returned.epc);
    try std.testing.expectEqual(caller.sp, returned.sp);
    try std.testing.expectEqual(caller.floating_control, returned.floating_control);
    try std.testing.expectEqual(caller.floating_registers[31], returned.floating_registers[31]);
}

test "same-task interrupts preserve newly written registers" {
    var scheduler = Scheduler{ .current = .codec };
    scheduler.policy.start(.codec);
    scheduler.contexts[@backingInt(Task.codec)].epc = 0xdead;
    var frame = Context{ .epc = 0x1234 };
    frame.floating_registers[15] = 0x11223344;
    try std.testing.expect(scheduler.select(&frame) == &frame);
    try std.testing.expectEqual(@as(u32, 0x11223344), scheduler.select(&frame).floating_registers[15]);
}

test "64-bit sleep deadlines survive the syscall ABI" {
    var scheduler = Scheduler{ .current = .storage };
    scheduler.policy.start(.storage);
    const deadline: u64 = 0x1122334455667788;
    var frame = request(.wait, 0x80000000, deadline);
    try scheduler.trap(&frame, 100);
    try std.testing.expectEqual(@as(?u64, deadline), scheduler.policy.nextDeadline());
    scheduler.policy.notify(.storage, 0x80000000);
    try std.testing.expectEqual(Task.storage, scheduler.policy.select());
}

test "unknown traps and idle waits leave frames and policy unchanged" {
    var scheduler = Scheduler{};
    var frame = request(.wait, 1, null);
    const original = frame;
    try std.testing.expectError(error.InvalidTrap, scheduler.trap(&frame, 0));
    try std.testing.expectEqualDeep(original, frame);
    frame.registers_1_to_25[3] = 99;
    const before = frame;
    try std.testing.expectError(error.InvalidTrap, scheduler.trap(&frame, 0));
    try std.testing.expectEqualDeep(before, frame);
    try std.testing.expect(scheduler.running);
}

test "shutdown returns to entry continuation even when idle was interrupted at WAIT" {
    var scheduler = Scheduler{};
    scheduler.policy.start(.control);
    var caller = request(.reschedule, 0, null);
    caller.epc = 0x1000;
    caller.sp = 0x12340000;
    caller.ra = 0x9000;
    caller.registers_1_to_25[15] = 0x76543210;
    try scheduler.trap(&caller, 0);
    _ = scheduler.select(&caller);
    var control = request(.wait, 1, 100);
    try scheduler.trap(&control, 0);
    _ = scheduler.select(&control);
    try std.testing.expectEqual(Task.idle, scheduler.current);
    var idle = Context{ .epc = 0x4444, .sp = caller.sp };
    scheduler.policy.wakeExpired(100);
    _ = scheduler.select(&idle);
    try std.testing.expectEqual(Task.control, scheduler.current);
    control = request(.stop, 0, null);
    try scheduler.trap(&control, 100);
    const returned = scheduler.select(&control);
    try std.testing.expectEqual(@as(u32, 0x1004), returned.epc);
    try std.testing.expectEqual(caller.sp, returned.sp);
    try std.testing.expectEqual(caller.ra, returned.ra);
    try std.testing.expectEqual(caller.registers_1_to_25[15], returned.registers_1_to_25[15]);
}

test "a completed worker retires while other workers and the caller remain live" {
    var scheduler = Scheduler{};
    scheduler.policy.start(.codec);
    scheduler.policy.start(.storage);
    var caller = request(.reschedule, 0, null);
    caller.epc = 0x1000;
    try scheduler.trap(&caller, 0);
    _ = scheduler.select(&caller);
    var codec = request(.retire, 0, null);
    try scheduler.trap(&codec, 1);
    _ = scheduler.select(&codec);
    try std.testing.expectEqual(Task.storage, scheduler.current);
    scheduler.policy.notify(.codec, 1);
    try std.testing.expectEqual(Task.storage, scheduler.policy.select());
    try std.testing.expect(scheduler.running);
}

test "an early peripheral interrupt cannot bypass entry continuation capture" {
    var scheduler = Scheduler{};
    scheduler.policy.start(.output);
    var caller = request(.reschedule, 0, null);
    caller.epc = 0x1000;
    try std.testing.expect(scheduler.select(&caller) == &caller);
    try std.testing.expectEqual(Task.idle, scheduler.current);
    try scheduler.trap(&caller, 1);
    _ = scheduler.select(&caller);
    try std.testing.expectEqual(Task.output, scheduler.current);
    try std.testing.expectEqual(@as(u32, 0x1004), scheduler.caller.epc);
}

test "idle interrupt snapshots cannot change the shutdown caller interrupt mask" {
    // The native port enters its first trap with IE clear. Idle can later be
    // interrupted around WAIT, so test both incoming saved IE states.
    const exception_level: u32 = 1 << 1;
    const worker_status: u32 = 0x20000803;
    for ([_]u32{ 0x20000802, worker_status }) |caller_status| {
        for ([_]u32{ 0x20000802, worker_status }) |idle_status| {
            var scheduler = Scheduler{};
            scheduler.policy.start(.control);
            var caller = request(.reschedule, 0, null);
            caller.epc = 0x1000;
            caller.status = caller_status;
            try scheduler.trap(&caller, 0);
            _ = scheduler.select(&caller);

            var control = request(.wait, 1, 10);
            control.status = worker_status;
            try scheduler.trap(&control, 0);
            const idle = scheduler.select(&control);
            try std.testing.expectEqual(caller_status | Context.interrupt_enable, idle.status);

            var interrupted_idle = Context{ .epc = 0x2000, .status = idle_status };
            scheduler.policy.wakeExpired(10);
            _ = scheduler.select(&interrupted_idle);
            control = request(.stop, 0, null);
            control.status = worker_status;
            try scheduler.trap(&control, 10);
            const returned = scheduler.select(&control);
            try std.testing.expectEqual(caller_status, returned.status);
            try std.testing.expectEqual(@as(u32, 0x1004), returned.epc);
            try std.testing.expectEqual(exception_level, returned.status & exception_level);
        }
    }
}

test "idle keeps wakeups enabled when a timer interrupt has no runnable worker" {
    var scheduler = Scheduler{};
    scheduler.policy.start(.control);
    var caller = request(.reschedule, 0, null);
    caller.status = 0x20000802;
    try scheduler.trap(&caller, 0);
    _ = scheduler.select(&caller);
    var control = request(.wait, 1, 100);
    try scheduler.trap(&control, 0);
    _ = scheduler.select(&control);
    var idle = Context{ .status = 0x20000802, .epc = 0x1234 };
    scheduler.policy.wakeExpired(99);
    const resumed = scheduler.select(&idle);
    try std.testing.expect(resumed == &idle);
    try std.testing.expectEqual(@as(u32, 0x20000803), resumed.status);
    try std.testing.expectEqual(@as(u32, 0x1234), resumed.epc);
    try std.testing.expectEqual(@as(u32, 0x20000802), scheduler.caller.status);
}
