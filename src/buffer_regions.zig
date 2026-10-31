//! Validate caller-owned scratch once at session admission, outside hot loops.
const std = @import("std");
pub fn disjoint(regions: []const []const u8) bool {
    for (regions, 0..) |region, i| {
        if (region.len == 0) continue;
        const start = @intFromPtr(region.ptr);
        const end = std.math.add(usize, start, region.len) catch return false;
        for (regions[0..i]) |previous| {
            if (previous.len == 0) continue;
            const before = @intFromPtr(previous.ptr);
            const after = std.math.add(usize, before, previous.len) catch return false;
            if (start < after and before < end) return false;
        }
    }
    return true;
}
test "scratch admission accepts touching regions and rejects partial or complete aliases" {
    var bytes: [64]u8 = undefined;
    try std.testing.expect(disjoint(&.{ bytes[0..32], bytes[32..64], bytes[12..12] }));
    try std.testing.expect(!disjoint(&.{ bytes[0..33], bytes[32..64] }));
    try std.testing.expect(!disjoint(&.{ bytes[0..64], bytes[1..63] }));
    try std.testing.expect(!disjoint(&.{ &bytes, &bytes }));
}
