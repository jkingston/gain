//! Small libc surface for the SD text component. These functions allocate no
//! memory and do not consult an OS. Host tests call them by their Zig names.
const std = @import("std");

comptime {
    if (@import("builtin").os.tag == .freestanding) {
        for (.{ "strcmp", "strncmp", "strchr", "strrchr", "strstr", "strcpy", "strncpy", "strcat", "memchr", "wcslen", "strtol" }) |name| @export(&@field(@This(), name), .{ .name = name });
        _ = @import("../codec_runtime.zig");
    }
}

pub fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    return strncmp(a, b, std.math.maxInt(usize));
}

pub fn strncmp(a: [*]const u8, b: [*]const u8, n: usize) callconv(.c) c_int {
    for (0..n) |i| {
        if (a[i] != b[i]) return @as(c_int, a[i]) - b[i];
        if (a[i] == 0) return 0;
    }
    return 0;
}

pub fn strchr(value: [*:0]const u8, character: c_int) callconv(.c) ?[*]const u8 {
    const byte: u8 = @truncate(@as(c_uint, @bitCast(character)));
    var i: usize = 0;
    while (true) : (i += 1) {
        if (value[i] == byte) return value + i;
        if (value[i] == 0) return null;
    }
}

pub fn strrchr(value: [*:0]const u8, character: c_int) callconv(.c) ?[*]const u8 {
    const byte: u8 = @truncate(@as(c_uint, @bitCast(character)));
    var found: ?[*]const u8 = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (value[i] == byte) found = value + i;
        if (value[i] == 0) return found;
    }
}

pub fn strstr(value: [*:0]const u8, needle: [*:0]const u8) callconv(.c) ?[*]const u8 {
    const index = std.mem.indexOf(u8, std.mem.span(value), std.mem.span(needle)) orelse return null;
    return value + index;
}

pub fn strcpy(output: [*]u8, value: [*:0]const u8) callconv(.c) [*]u8 {
    const n = std.mem.len(value) + 1;
    @memcpy(output[0..n], value[0..n]);
    return output;
}

pub fn strncpy(output: [*]u8, value: [*]const u8, n: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < n and value[i] != 0) : (i += 1) output[i] = value[i];
    @memset(output[i..n], 0);
    return output;
}

pub fn strcat(output: [*:0]u8, value: [*:0]const u8) callconv(.c) [*]u8 {
    _ = strcpy(output + std.mem.len(output), value);
    return output;
}

pub fn memchr(value: [*]const u8, character: c_int, length: usize) callconv(.c) ?[*]const u8 {
    const byte: u8 = @truncate(@as(c_uint, @bitCast(character)));
    const index = std.mem.indexOfScalar(u8, value[0..length], byte) orelse return null;
    return value + index;
}

pub fn wcslen(value: [*:0]const u32) callconv(.c) usize {
    return std.mem.len(value);
}

pub var errno: c_int = 0;

pub fn strtol(value: [*:0]const u8, end: ?*[*]const u8, requested_base: c_int) callconv(.c) c_long {
    if (end) |p| p.* = value;
    if (requested_base != 0 and (requested_base < 2 or requested_base > 36)) {
        errno = 22;
        return 0;
    }
    var i: usize = 0;
    while (std.ascii.isWhitespace(value[i])) i += 1;
    const negative = value[i] == '-';
    if (negative or value[i] == '+') i += 1;
    var base: u8 = @intCast(requested_base);
    if ((base == 0 or base == 16) and value[i] == '0' and (value[i + 1] == 'x' or value[i + 1] == 'X') and std.ascii.isHex(value[i + 2])) {
        base = 16;
        i += 2;
    } else if (base == 0) base = if (value[i] == '0') 8 else 10;
    const start = i;
    const limit: u64 = @as(u64, @intCast(std.math.maxInt(c_long))) + @intFromBool(negative);
    var result: u64 = 0;
    var overflow = false;
    while (true) : (i += 1) {
        const digit: u8 = if (value[i] >= '0' and value[i] <= '9') value[i] - '0' else if (std.ascii.isAlphabetic(value[i])) std.ascii.toLower(value[i]) - 'a' + 10 else break;
        if (digit >= base) break;
        if (result > (limit -| digit) / base) overflow = true else if (!overflow) result = result * base + digit;
    }
    if (i == start) return 0;
    if (end) |p| p.* = value + i;
    if (overflow) {
        errno = 34;
        return if (negative) std.math.minInt(c_long) else std.math.maxInt(c_long);
    }
    if (negative and result == limit) return std.math.minInt(c_long);
    return if (negative) -@as(c_long, @intCast(result)) else @intCast(result);
}

test "C string helpers preserve terminators, padding, unsigned comparisons and bounded reads" {
    try std.testing.expect(strcmp("abc", "abd") < 0);
    try std.testing.expect(strcmp("\xff", "z") > 0);
    try std.testing.expectEqual(@as(c_int, 0), strncmp("abc", "abd", 2));
    try std.testing.expectEqualStrings("bc", std.mem.span(@as([*:0]const u8, @ptrCast(strchr("abc", 'b').?))));
    try std.testing.expectEqual(@as(u8, 0), strrchr("abc", 0).?[0]);
    try std.testing.expect(strstr("abc", "longer") == null);
    try std.testing.expect(strstr("abc", "") != null);
    var out: [12:0]u8 = @splat(0x7f);
    _ = strncpy(&out, "ab", 5);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 0, 0, 0, 0x7f }, out[0..6]);
    _ = strcat(&out, "cd");
    try std.testing.expectEqualStrings("abcd", std.mem.span(@as([*:0]u8, &out)));
    try std.testing.expect(memchr("abc", 'c', 2) == null);
    try std.testing.expectEqual(@as(usize, 2), wcslen(&.{ 0x1f3b5, 0x4e00, 0 }));
}

test "C integer parsing handles prefixes, signs, end pointers and overflow" {
    var end: [*]const u8 = undefined;
    try std.testing.expectEqual(@as(c_long, -42), strtol(" \t-42tail", &end, 0));
    try std.testing.expectEqualStrings("tail", std.mem.span(@as([*:0]const u8, @ptrCast(end))));
    try std.testing.expectEqual(@as(c_long, 255), strtol("0xff", null, 0));
    try std.testing.expectEqual(@as(c_long, 63), strtol("077", null, 0));
    try std.testing.expectEqual(@as(c_long, 35), strtol("Z", null, 36));
    try std.testing.expectEqual(@as(c_long, 0), strtol("+tail", &end, 10));
    try std.testing.expectEqual(@as(u8, '+'), end[0]);
    try std.testing.expectEqual(std.math.maxInt(c_long), strtol("9999999999999999999999999!", &end, 10));
    try std.testing.expectEqual(@as(u8, '!'), end[0]);
    try std.testing.expectEqual(std.math.minInt(c_long), strtol("-9999999999999999999999999", null, 10));
}
