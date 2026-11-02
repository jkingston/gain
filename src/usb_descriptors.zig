//! USB 2.0 high/full speed MSC. No network interfaces or development commands.
const std = @import("std");

pub const vendor_id = 0xa108;
pub const product_id = 0x1002; // Development identity; obtain a product VID/PID before distributing hardware.
pub const device = [_]u8{ 18, 1, 0, 2, 0, 0, 0, 64, 0x08, 0xa1, 0x02, 0x10, 0, 1, 1, 2, 3, 1 };
pub const qualifier = [_]u8{ 10, 6, 0, 2, 0, 0, 0, 64, 1, 0 };

fn configuration(comptime speed: enum { high, full }, comptime other: bool) [32]u8 {
    const size: u16 = if (speed == .high) 512 else 64;
    // Interval 1 is valid for bulk (ignored on bulk IN). It also avoids the
    // current upstream DWC2 port's unconditional shift by bInterval-1.
    return .{
        9,
        if (other) 7 else 2,
        32,
        0,
        1,
        1,
        0,
        0x80,
        250,
        9,
        4,
        0,
        0,
        2,
        8,
        6,
        0x50,
        0,
        7,
        5,
        1,
        2,
        @truncate(size),
        @truncate(size >> 8),
        1,
        7,
        5,
        0x81,
        2,
        @truncate(size),
        @truncate(size >> 8),
        1,
    };
}
pub const high = configuration(.high, false);
pub const full = configuration(.full, false);
pub const other_high = configuration(.high, true);
pub const other_full = configuration(.full, true);

test "both speeds and other-speed descriptors agree with real endpoint geometry" {
    for ([_][32]u8{ high, full, other_high, other_full }, 0..) |bytes, i| {
        try std.testing.expectEqual(32, std.mem.readInt(u16, bytes[2..4], .little));
        try std.testing.expectEqual(if (i >= 2) @as(u8, 7) else @as(u8, 2), bytes[1]);
        for ([_]usize{ 18, 25 }) |offset| {
            try std.testing.expectEqual(if (i % 2 == 0) @as(u16, 512) else @as(u16, 64), std.mem.readInt(u16, bytes[offset + 4 ..][0..2], .little));
            try std.testing.expectEqual(1, bytes[offset + 6]);
        }
    }
}
