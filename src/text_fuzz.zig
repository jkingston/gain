const std = @import("std");
const pack = @import("text/pack.zig");
const component = @import("text/component.zig");
const abi = @import("text/contract.zig");

const pack_seed = fontPackSeed();
const component_seed = componentSeed();
fn seed(comptime bytes: []const u8) []const u8 {
    return "\xff\xff\xff\xff" ++ bytes;
}

fn fontPackSeed() [160]u8 {
    var bytes: [160]u8 = @splat(0);
    @memcpy(bytes[0..8], "GAINFT01");
    for ([_]u32{ 1, 2, 1, 64, 112, 124, 160 }, 0..) |value, i| std.mem.writeInt(u32, bytes[8 + i * 4 ..][0..4], value, .little);
    for (0..6) |i| {
        std.mem.writeInt(u32, bytes[64 + i * 8 ..][0..4], 124, .little);
        std.mem.writeInt(u32, bytes[68 + i * 8 ..][0..4], 36, .little);
    }
    return bytes;
}

fn componentSeed() [68]u8 {
    var bytes: [68]u8 = @splat(0);
    @memcpy(bytes[0..8], "GAINTE01");
    for ([_]u32{ abi.version, component.code_address, component.code_capacity, component.work_address, component.work_capacity, 4, std.hash.Crc32.hash("test") }, 0..) |value, i| std.mem.writeInt(u32, bytes[8 + i * 4 ..][0..4], value, .little);
    @memcpy(bytes[64..68], "test");
    return bytes;
}

test "fuzz text pack envelopes and UTF-8 request bounds" {
    try std.testing.fuzz({}, run, .{ .corpus = &.{ seed(""), seed(&pack_seed), seed(&component_seed), seed("日本語 العربية á 👩‍🎤"), seed("\xff\xfe") } });
}

fn run(_: void, smith: *std.testing.Smith) !void {
    var storage: [8192]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    const length: u32 = @intCast(input.len);
    const header = pack.Header.decode(input, length) catch null;
    if (header) |h| {
        try std.testing.expect(h.bytes == length);
        try std.testing.expect(h.faces <= pack.max_faces and h.ranges <= pack.max_ranges);
        try std.testing.expect(h.font_offset < length);
        for (0..h.faces) |i| {
            const record = input[h.face_offset + i * pack.face_bytes ..][0..pack.face_bytes];
            for (0..3) |weight| {
                if (pack.face(record, weight, h)) |face| {
                    try std.testing.expect(@as(u64, face.offset) + face.bytes <= length);
                } else |_| {}
            }
        }
    }
    if (component.Header.decode(input, length)) |h| {
        try std.testing.expect(h.bytes <= component.code_capacity);
        _ = h.validate(input[component.header_bytes..]);
    } else |_| {}
    if (abi.Request.init(input, .reading, 65535, .automatic, true)) |request| {
        try std.testing.expect(input.len <= abi.max_text_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(input));
        try std.testing.expect(request.width <= abi.max_width);
        try std.testing.expectEqualSlices(u8, input, request.value());
    } else |_| {}
}
