//! Minimal libc services required by upstream decoders in freestanding builds.
//! Logging has no destination; qsort uses bounded stack and no allocation.
const std = @import("std");
comptime {
    // Host tests must use the host libc's exit/stdio and test this implementation
    // by its Zig name. Only firmware supplies these C symbols.
    if (@import("builtin").os.tag == .freestanding) {
        @export(&stderr, .{ .name = "stderr" });
        @export(&fprintf, .{ .name = "fprintf" });
        @export(&exit, .{ .name = "exit" });
        @export(&qsort, .{ .name = "qsort" });
    }
}
var stderr: ?*anyopaque = null;
// No variadic arguments are inspected. The fixed prefix has the same C ABI.
fn fprintf(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) c_int {
    return -1;
}
fn exit(_: c_int) callconv(.c) noreturn {
    @trap();
}
const Compare = *const fn (*const anyopaque, *const anyopaque) callconv(.c) c_int;
fn swap(bytes: []u8, a: usize, b: usize, width: usize) void {
    for (0..width) |offset| std.mem.swap(u8, &bytes[a * width + offset], &bytes[b * width + offset]);
}
fn down(bytes: []u8, initial: usize, count: usize, width: usize, compare: Compare) void {
    var root = initial;
    // (count-2)/2 is the last parent, including a parent's lone left child.
    while (count >= 2 and root <= (count - 2) / 2) {
        var child = root * 2 + 1;
        if (child + 1 < count and compare(&bytes[child * width], &bytes[(child + 1) * width]) < 0) child += 1;
        if (compare(&bytes[root * width], &bytes[child * width]) >= 0) return;
        swap(bytes, root, child, width);
        root = child;
    }
}
pub fn qsort(pointer: ?*anyopaque, count: usize, width: usize, compare: Compare) callconv(.c) void {
    if (count < 2 or width == 0) return;
    const length = std.math.mul(usize, count, width) catch @trap();
    const bytes = @as([*]u8, @ptrCast(pointer.?))[0..length];
    var parent = count / 2;
    while (parent != 0) {
        parent -= 1;
        down(bytes, parent, count, width, compare);
    }
    var end = count;
    while (end > 1) {
        end -= 1;
        swap(bytes, 0, end, width);
        down(bytes, 0, end, width, compare);
    }
}

test "freestanding qsort matches Zig sort for odd and even heaps with duplicates" {
    const Comparator = struct {
        fn compare(a: *const anyopaque, b: *const anyopaque) callconv(.c) c_int {
            const left: *const i32 = @ptrCast(@alignCast(a));
            const right: *const i32 = @ptrCast(@alignCast(b));
            return if (left.* < right.*) -1 else if (left.* > right.*) 1 else 0;
        }
    };
    var random = std.Random.DefaultPrng.init(0x51534f5254);
    var actual: [257]i32 = undefined;
    var expected: [257]i32 = undefined;
    for (0..actual.len + 1) |length| {
        for (actual[0..length]) |*item| item.* = random.random().intRangeAtMost(i32, -32, 32);
        @memcpy(expected[0..length], actual[0..length]);
        std.mem.sort(i32, expected[0..length], {}, std.sort.asc(i32));
        qsort(&actual, length, @sizeOf(i32), Comparator.compare);
        try std.testing.expectEqualSlices(i32, expected[0..length], actual[0..length]);
    }
    qsort(null, 0, 4, Comparator.compare);
    qsort(null, 4, 0, Comparator.compare);
}
