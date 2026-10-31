//! Single-core X1000 port for the portable executive. Interrupts never nest.
//! Task code uses traps for atomic wait/dispatch; the idle context uses WAIT.
const std = @import("std");
const x = @import("x1000.zig");
const executive = @import("executive.zig");
const dispatch_state = @import("task_dispatch.zig");
pub const Context = dispatch_state.Context;
pub const Task = executive.Task;
pub const Entry = *const fn () callconv(.c) noreturn;
pub const Specification = struct { entry: Entry, stack_top: u32, stack_bottom: u32 = 0 };
const interrupt_enable = Context.interrupt_enable;
const exception_level: u32 = 1 << 1;
const floating_point_enable: u32 = 1 << 29;
const external_interrupt: u32 = 1 << 10;
const timer_interrupt: u32 = 1 << 11;
const alternate_vector: u32 = 1 << 23;
const no_deadline = dispatch_state.no_deadline;
const maintenance_ticks = std.math.maxInt(i32);
const Operation = dispatch_state.Operation;
extern fn gain_task_trap(u32, u32, u32, u32) callconv(.c) void;
extern var _gp: u8;
var active: ?*Runtime = null;

pub const Metrics = struct { interrupts: u32 = 0, switches: u32 = 0, idle_dispatches: u32 = 0, maximum_handler_ticks: u32 = 0 };

pub const Runtime = struct {
    scheduler: dispatch_state.Scheduler = .{},
    clock: executive.Clock = .{ .previous = 0 },
    metrics: Metrics = .{},
    stacks: [executive.task_count]@import("task_stack.zig").Bounds = @splat(.{}),
    /// Called with interrupts masked; the board acknowledges its sources and
    /// notifies tasks without I2C, rendering, allocation or media decoding.
    hardware_interrupt: ?*const fn (*Runtime) void = null,

    pub fn run(self: *Runtime, specifications: [executive.task_count]Specification) void {
        std.debug.assert(active == null);
        const original = maskInterrupts();
        self.scheduler = .{};
        self.clock = .{ .previous = x.Timer.now() };
        const interrupt_mask = timer_interrupt | if (self.hardware_interrupt != null) external_interrupt else @as(u32, 0);
        for (specifications, 0..) |specification, index| {
            self.stacks[index] = .{ .bottom = specification.stack_bottom, .top = specification.stack_top };
            self.scheduler.contexts[index] = .{};
            self.scheduler.contexts[index].gp = @intCast(@intFromPtr(&_gp));
            std.debug.assert(specification.stack_top & 15 == 0);
            // Reserve the caller's O32 argument home area for a fresh entry.
            self.scheduler.contexts[index].sp = specification.stack_top - 16;
            self.scheduler.contexts[index].epc = @intCast(@intFromPtr(specification.entry));
            self.scheduler.contexts[index].status = floating_point_enable | interrupt_mask | interrupt_enable | exception_level;
            self.scheduler.policy.start(@fromBackingInt(@intCast(index)));
        }
        self.metrics = .{};
        self.scheduler.running = true;
        active = self;
        Timer.initialize();
        const cause = asm volatile ("mfc0 %[value],$13"
            : [value] "=r" (-> u32),
        );
        asm volatile ("mtc0 %[value],$13;ehb"
            :
            : [value] "r" (cause & ~alternate_vector),
            : .{ .memory = true });
        // Enter the first trap with IRQs masked. Fresh worker contexts enable
        // them on ERET after the entry continuation has been captured.
        const status = floating_point_enable | interrupt_mask;
        asm volatile ("mtc0 %[value],$12;ehb"
            :
            : [value] "r" (status),
            : .{ .memory = true });
        gain_task_trap(@backingInt(Operation.reschedule), 0, 0, 0);
        while (self.scheduler.running) {
            asm volatile ("wait" ::: .{ .memory = true });
        }
        _ = maskInterrupts();
        Timer.shutdown();
        active = null;
        asm volatile ("mtc0 %[value],$12;ehb"
            :
            : [value] "r" (original),
            : .{ .memory = true });
    }

    pub fn wait(self: *Runtime, events: u32, deadline: ?u64) void {
        std.debug.assert(self.scheduler.current != .idle);
        const ticks = deadline orelse no_deadline;
        gain_task_trap(@backingInt(Operation.wait), events, @truncate(ticks), @truncate(ticks >> 32));
    }
    pub fn stop(self: *Runtime) noreturn {
        std.debug.assert(self.scheduler.current != .idle);
        gain_task_trap(@backingInt(Operation.stop), 0, 0, 0);
        unreachable;
    }
    /// Call only after local resources and decoder defers have unwound.
    pub fn retire(self: *Runtime) noreturn {
        std.debug.assert(self.scheduler.current != .idle);
        gain_task_trap(@backingInt(Operation.retire), 0, 0, 0);
        unreachable;
    }
    pub fn now(self: *Runtime) u64 {
        const status = maskInterrupts();
        defer restoreInterrupts(status);
        return self.clock.sample(x.Timer.now());
    }
    pub fn take(self: *Runtime, events: u32) u32 {
        const status = maskInterrupts();
        defer restoreInterrupts(status);
        return self.scheduler.policy.take(self.scheduler.current, events);
    }
    pub fn notify(self: *Runtime, task: Task, events: u32) void {
        const status = maskInterrupts();
        defer restoreInterrupts(status);
        self.notifyFromInterrupt(task, events);
        gain_task_trap(@backingInt(Operation.reschedule), 0, 0, 0);
    }
    pub fn notifyFromInterrupt(self: *Runtime, task: Task, events: u32) void {
        self.scheduler.policy.notify(task, events);
    }

    fn interrupt(self: *Runtime, frame: *Context, entry: u32, cause: u32) *Context {
        const started = x.Timer.now();
        const now_ticks = self.clock.sample(entry);
        const code = (cause >> 2) & 31;
        if (code == 0) {
            self.metrics.interrupts +%= 1;
            if (cause & timer_interrupt != 0) {
                Timer.shutdown();
                self.scheduler.policy.wakeExpired(now_ticks);
            }
            if (cause & external_interrupt != 0) if (self.hardware_interrupt) |handle| handle(self);
        } else if (code == 8 and cause & (1 << 31) == 0) {
            self.scheduler.trap(frame, now_ticks) catch fatal(cause, frame.epc, frame.status);
        } else fatal(cause, frame.epc, frame.status);
        if (self.scheduler.current != .idle and !self.stacks[@backingInt(self.scheduler.current)].contains(frame.sp)) fatal(0x5354414b, frame.epc, frame.sp);
        const previous = self.scheduler.current;
        const selected_frame = self.scheduler.select(frame);
        if (previous != self.scheduler.current) {
            self.metrics.switches +%= 1;
            if (self.scheduler.current == .idle) self.metrics.idle_dispatches +%= 1;
        }
        if (self.scheduler.running) {
            const current_ticks = self.clock.sample(x.Timer.now());
            const deadline = self.scheduler.policy.nextDeadline() orelse current_ticks + maintenance_ticks;
            Timer.arm(@intCast(@max(1, @min(deadline - @min(current_ticks, deadline), maintenance_ticks))));
        } else Timer.shutdown();
        self.metrics.maximum_handler_ticks = @max(self.metrics.maximum_handler_ticks, x.Timer.elapsed(started));
        return selected_frame;
    }
};
extern fn exception_panic(u32, u32, u32) callconv(.c) noreturn;
fn fatal(cause: u32, epc: u32, status: u32) noreturn {
    exception_panic(cause, epc, status);
}
pub fn dispatch(frame: *Context, entry: u32, cause: u32) *Context {
    return if (active) |runtime| runtime.interrupt(frame, entry, cause) else fatal(cause, frame.epc, frame.status);
}
fn maskInterrupts() u32 {
    return asm volatile ("di %[old];ehb"
        : [old] "=r" (-> u32),
        :
        : .{ .memory = true });
}
fn restoreInterrupts(status: u32) void {
    if (status & interrupt_enable != 0) asm volatile ("ei;ehb" ::: .{ .memory = true });
}
const Timer = struct {
    const base = 0xb2000000;
    const channel: u32 = 1;
    fn initialize() void {
        shutdown();
        x.write32(base, (x.read32(base) & ~@as(u32, 3)) | 1);
    }
    fn shutdown() void {
        x.write32(base + 0x38, channel);
        x.write32(base + 0x10, channel);
        x.write32(base + 0x0c, ~channel);
    }
    fn arm(ticks: u32) void {
        shutdown();
        x.write32(base + 0x14, ticks);
        x.write32(base + 0x08, channel);
        x.write32(base + 0x34, channel);
        x.write32(base + 0x10, ~channel);
    }
};
