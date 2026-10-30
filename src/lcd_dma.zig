const std = @import("std");

pub const command_descriptor = @as(u32, 1) << 29;
pub const end_of_frame_interrupt = @as(u32, 1) << 30;
pub const frame_enable = @as(u32, 1) << 26;
pub const pixels_16_bit = @as(u32, 4) << 27;

pub const Descriptor = extern struct {
    next: u32,
    source: u32,
    frame_id: u32,
    command: u32,
    offset_size: u32,
    page_width: u32,
    count: u32,
    frame_size: u32,
};

pub const Chain = struct {
    command: Descriptor,
    frame: Descriptor,
};

pub const TransferPlan = struct {
    descriptors: Chain,
    horizontal_area: u16,
    vertical_area: u16,
};

pub const OutputState = struct {
    backlight_enabled: bool = false,

    pub fn completedTransfer(self: *OutputState) bool {
        if (self.backlight_enabled) return false;
        self.backlight_enabled = true;
        return true;
    }
};

pub fn physicalAddress(address: usize) u32 {
    return @truncate(address & 0x1fff_ffff);
}

pub fn buildChain(
    descriptor_address: usize,
    command_address: usize,
    pixel_address: usize,
    width: u16,
    height: u16,
) Chain {
    const command_address_physical = physicalAddress(descriptor_address);
    const frame_address_physical = command_address_physical + @sizeOf(Descriptor);
    const pixel_bytes = @as(u32, width) * height * @sizeOf(u16);
    return .{
        .command = .{
            .next = frame_address_physical,
            .source = physicalAddress(command_address),
            .frame_id = 0xc0,
            .command = command_descriptor | 1,
            .offset_size = 0,
            .page_width = 0,
            .count = 4,
            .frame_size = 0,
        },
        .frame = .{
            .next = command_address_physical,
            .source = physicalAddress(pixel_address),
            .frame_id = 0xf0,
            .command = end_of_frame_interrupt | frame_enable | ((pixel_bytes + 3) / 4),
            .offset_size = 0,
            .page_width = 0,
            .count = pixels_16_bit,
            .frame_size = @as(u32, width - 1) | (@as(u32, height - 1) << 12),
        },
    };
}

pub fn buildTransferPlan(
    descriptor_address: usize,
    command_address: usize,
    pixel_address: usize,
    width: u16,
    height: u16,
) TransferPlan {
    return .{
        .descriptors = buildChain(
            descriptor_address,
            command_address,
            pixel_address,
            width,
            height,
        ),
        // LCDDAH/LCDDAV describe the DMA transfer canvas. Keeping the panel's
        // full dimensions here makes the controller compose a partial OSD
        // frame instead of emitting only this panel window.
        .horizontal_area = width,
        .vertical_area = height,
    };
}

comptime {
    if (@sizeOf(Descriptor) != 32) @compileError("LCD DMA descriptors must be eight words");
    if (@alignOf(Descriptor) != 4) @compileError("descriptor storage supplies the required 32-byte alignment");
}

test "builds the X1000 command and RGB565 frame chain" {
    const chain = buildChain(0xa007_e000, 0xa007_e100, 0xa004_0000, 320, 240);
    try std.testing.expectEqual(@as(u32, 0x0007_e020), chain.command.next);
    try std.testing.expectEqual(@as(u32, 0x0007_e100), chain.command.source);
    try std.testing.expectEqual(@as(u32, 0x2000_0001), chain.command.command);
    try std.testing.expectEqual(@as(u32, 4), chain.command.count);
    try std.testing.expectEqual(@as(u32, 0x0007_e000), chain.frame.next);
    try std.testing.expectEqual(@as(u32, 0x0004_0000), chain.frame.source);
    try std.testing.expectEqual(@as(u32, 0x4400_9600), chain.frame.command);
    try std.testing.expectEqual(@as(u32, 0x2000_0000), chain.frame.count);
    try std.testing.expectEqual(@as(u32, 319 | (239 << 12)), chain.frame.frame_size);
}

test "small regions use their packed buffer and exact geometry" {
    const plan = buildTransferPlan(0xa007_e000, 0xa007_e100, 0xa00c_0000, 18, 7);
    const chain = plan.descriptors;
    try std.testing.expectEqual(@as(u32, 0x000c_0000), chain.frame.source);
    try std.testing.expectEqual(@as(u32, 0x4400_003f), chain.frame.command);
    try std.testing.expectEqual(@as(u32, 17 | (6 << 12)), chain.frame.frame_size);
    try std.testing.expectEqual(@as(u16, 18), plan.horizontal_area);
    try std.testing.expectEqual(@as(u16, 7), plan.vertical_area);
}

test "first DMA completion enables the panel backlight once" {
    var output = OutputState{};
    try std.testing.expect(output.completedTransfer());
    try std.testing.expect(!output.completedTransfer());
    try std.testing.expect(output.backlight_enabled);
}
