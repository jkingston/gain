const std = @import("std");
const presentation = @import("gain_ui").presentation;

test "fuzz expanded regions packed pixels and destination canaries" {
    try std.testing.fuzz({}, fuzzRegion, .{ .corpus = &.{ &.{ 0, 0, 1, 1 }, &.{ 17, 11, 1, 1 }, &.{ 1, 1, 17, 11 }, &.{ 255, 255, 255, 255 } } });
}

fn fuzzRegion(_: void, smith: *std.testing.Smith) !void {
    var bytes: [4]u8 = @splat(0);
    _ = smith.slice(&bytes);
    const region = presentation.Region{ .x = bytes[0] % 22, .y = bytes[1] % 16, .width = bytes[2] % 22, .height = bytes[3] % 16 };
    var source: [18 * 12]u16 = undefined;
    for (&source, 0..) |*pixel, index| pixel.* = @intCast(index);
    var memory: [18 * 12 + 4]u16 align(4) = @splat(0xa55a);
    const expanded = presentation.alignedRegion(region, 18, 12) catch {
        try std.testing.expect(region.width == 0 or region.height == 0 or @as(u32, region.x) + region.width > 18 or @as(u32, region.y) + region.height > 12);
        return;
    };
    try std.testing.expect(expanded.x <= region.x and expanded.x + expanded.width >= region.x + region.width and expanded.width & 1 == 0);
    const count = expanded.pixels();
    // Test both word aligned fast stores and halfword aligned fallback.
    const offset: usize = if (bytes[0] & 1 == 0) 1 else 2;
    try presentation.pack(&source, 18, 12, expanded, memory[offset..][0..count]);
    for (0..count) |index| try std.testing.expectEqual(source[(@as(usize, expanded.y) + index / expanded.width) * 18 + expanded.x + index % expanded.width], memory[offset + index]);
    for (memory[0..offset]) |value| try std.testing.expectEqual(@as(u16, 0xa55a), value);
    for (memory[offset + count ..]) |value| try std.testing.expectEqual(@as(u16, 0xa55a), value);
}
