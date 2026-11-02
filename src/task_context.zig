//! X1000 O32 interrupt context, shared by the assembly port and qualification.
const std = @import("std");

pub const Context = extern struct {
    pub const interrupt_enable: u32 = 1;
    registers_1_to_25: [25]u32 = @splat(0),
    gp: u32 = 0,
    sp: u32 = 0,
    fp: u32 = 0,
    ra: u32 = 0,
    lo: u32 = 0,
    hi: u32 = 0,
    status: u32 = 0,
    epc: u32 = 0,
    floating_registers: [32]u32 = @splat(0),
    floating_control: u32 = 0,
    padding: [2]u32 = @splat(0),

    pub fn argument(self: *const Context, index: u2) u32 {
        // O32 arguments a0..a3 are architectural registers 4..7.
        return self.registers_1_to_25[@as(usize, index) + 3];
    }
};

comptime {
    if (@offsetOf(Context, "registers_1_to_25") != 0 or @offsetOf(Context, "gp") != 0x64 or
        @offsetOf(Context, "sp") != 0x68 or @offsetOf(Context, "fp") != 0x6c or
        @offsetOf(Context, "ra") != 0x70 or @offsetOf(Context, "lo") != 0x74 or
        @offsetOf(Context, "hi") != 0x78 or @offsetOf(Context, "status") != 0x7c or
        @offsetOf(Context, "epc") != 0x80 or @offsetOf(Context, "floating_registers") != 0x84 or
        @offsetOf(Context, "floating_control") != 0x104 or @offsetOf(Context, "padding") != 0x108 or
        @sizeOf(Context) != 0x110)
        @compileError("X1000 interrupt assembly context layout changed");
}

test "trap arguments read architectural O32 a0 through a3" {
    var context = Context{};
    for (&context.registers_1_to_25, 1..) |*register, number| register.* = @intCast(number);
    try std.testing.expectEqual(@as(u32, 4), context.argument(0));
    try std.testing.expectEqual(@as(u32, 5), context.argument(1));
    try std.testing.expectEqual(@as(u32, 6), context.argument(2));
    try std.testing.expectEqual(@as(u32, 7), context.argument(3));
}
