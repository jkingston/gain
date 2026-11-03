//! Select an immutable transfer bank without touching the controller's bank.
const std = @import("std");

pub fn inactive(active: usize, first: usize, second: usize) usize {
    std.debug.assert(first != second);
    return if (active == first) second else first;
}

test "packing every next frame preserves active DMA bytes until drain acknowledgement" {
    const presentation = @import("presentation.zig");
    var canvas: [8 * 4]u16 = undefined;
    var banks: [2][8 * 4]u16 align(4) = undefined;
    var active: usize = 0;
    for (1..100) |generation| {
        const free = inactive(active, @intFromPtr(&banks[0]), @intFromPtr(&banks[1]));
        @memset(&canvas, @intCast(generation));
        const index: usize = if (free == @intFromPtr(&banks[0])) 0 else 1;
        try presentation.pack(&canvas, 8, 4, .{ .x = 0, .y = 0, .width = 8, .height = 4 }, &banks[index]);
        if (active != 0) for (banks[1 - index]) |pixel| try std.testing.expectEqual(generation - 1, pixel);
        // All FIFO-drain/ACK orderings leave the same bank retained.
        var dma: presentation.State = .{};
        try dma.prepare();
        try dma.commit(0xfffffff0);
        _ = try dma.observe(0xfffffff1, 100, .{ .eof = true, .bus_busy = true });
        try std.testing.expectEqual(free, inactive(active, @intFromPtr(&banks[0]), @intFromPtr(&banks[1])));
        _ = try dma.observe(0xfffffff2, 100, .{ .eof = true });
        try std.testing.expect(dma.owned());
        _ = try dma.observe(0xfffffff3, 100, .{ .disable_done = true });
        try std.testing.expect(!dma.owned());
        active = free;
    }
}
