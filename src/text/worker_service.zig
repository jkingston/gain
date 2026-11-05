//! Sole-storage-owner work at font-source polling boundaries. This pump is
//! deliberately separate from generic controller keep-alive callbacks, which
//! may run while an SD transaction is still active.
const std = @import("std");

pub const Yield = struct {
    context: *anyopaque,
    poll: *const fn (*anyopaque) bool,
};

pub const Work = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) void,
};

pub const StoragePump = struct {
    hook: ?Work = null,
    busy: bool = false,

    fn service(self: *StoragePump) void {
        if (self.busy) return;
        const hook = self.hook orelse return;
        self.busy = true;
        defer self.busy = false;
        hook.run(hook.context);
    }
};

pub fn poll(cancellation: ?Yield, storage: *StoragePump) bool {
    // USB/player cancellation takes precedence over starting another SD job.
    if (cancellation) |hook| if (hook.poll(hook.context)) return true;
    storage.service();
    return false;
}

pub fn withYield(owner: anytype, hook: Yield, comptime operation: anytype) void {
    // A nested busy service must not replace or clear an outer job's callback.
    if (owner.busy) return;
    const previous = owner.yield;
    owner.yield = hook;
    defer owner.yield = previous;
    operation(owner);
}

test "source polling cancels before storage work and bounds recursive pumping" {
    const Owner = struct {
        pump: StoragePump = .{},
        cancelled: bool = true,
        polls: usize = 0,
        work: usize = 0,

        fn cancel(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.polls += 1;
            return self.cancelled;
        }

        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.work += 1;
            // A callback may service control again. It must not recursively
            // start a second card operation or lose the outer busy guard.
            std.debug.assert(!poll(.{ .context = self, .poll = cancel }, &self.pump));
            std.debug.assert(self.pump.busy);
        }
    };
    var owner: Owner = .{};
    owner.pump.hook = .{ .context = &owner, .run = Owner.run };
    try std.testing.expect(poll(.{ .context = &owner, .poll = Owner.cancel }, &owner.pump));
    try std.testing.expectEqual(1, owner.polls);
    try std.testing.expectEqual(0, owner.work);
    owner.cancelled = false;
    try std.testing.expect(!poll(.{ .context = &owner, .poll = Owner.cancel }, &owner.pump));
    try std.testing.expectEqual(3, owner.polls);
    try std.testing.expectEqual(1, owner.work);
    try std.testing.expect(!owner.pump.busy);
    owner.pump.hook = null;
    try std.testing.expect(!poll(null, &owner.pump));
    try std.testing.expectEqual(1, owner.work);
}

test "nested busy service preserves and restores the outer yield binding" {
    const Owner = struct {
        busy: bool = false,
        yield: ?Yield = null,
        calls: usize = 0,
        nested_context: u32 = 0,

        fn cancel(_: *anyopaque) bool {
            return false;
        }

        fn service(self: *@This()) void {
            self.busy = true;
            defer self.busy = false;
            self.calls += 1;
            const before = self.yield.?;
            withYield(self, .{ .context = &self.nested_context, .poll = cancel }, service);
            std.debug.assert(self.yield.?.context == before.context);
            std.debug.assert(self.yield.?.poll == before.poll);
        }
    };
    var owner: Owner = .{};
    var original: u32 = 1;
    var outer: u32 = 2;
    owner.yield = .{ .context = &original, .poll = Owner.cancel };
    withYield(&owner, .{ .context = &outer, .poll = Owner.cancel }, Owner.service);
    try std.testing.expectEqual(1, owner.calls);
    try std.testing.expect(!owner.busy);
    try std.testing.expect(owner.yield.?.context == @as(*anyopaque, &original));
    try std.testing.expect(owner.yield.?.poll == Owner.cancel);
}
