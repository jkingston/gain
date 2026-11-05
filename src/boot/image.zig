//! Validated SD boot envelope. Parsing never performs MMIO or executes code.
const std = @import("std");
pub const header_bytes = 64;
pub const target_name: [32]u8 = blk: {
    var bytes: [32]u8 = @splat(0);
    const name = "Gain F20 V2.7";
    @memcpy(bytes[0..name.len], name);
    break :blk bytes;
};
pub const address = 0x80004000;
pub const limit = 0x80280000 - address;
pub const Error = error{ Truncated, BadMagic, HeaderChecksum, WrongTarget, InvalidSize, PayloadChecksum, UnexpectedEnd };
pub const Header = struct { size: u32, checksum: u32 };

fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

pub fn header(bytes: []const u8, file_size: u32) Error!Header {
    if (bytes.len < header_bytes) return error.Truncated;
    if (word(bytes, 0) != 0x27051956) return error.BadMagic;
    var copy: [header_bytes]u8 = bytes[0..header_bytes].*;
    @memset(copy[4..8], 0);
    if (std.hash.Crc32.hash(&copy) != word(bytes, 4)) return error.HeaderChecksum;
    const size = word(bytes, 12);
    if (size == 0 or size > limit or file_size != header_bytes + size) return error.InvalidSize;
    if (word(bytes, 16) != address or word(bytes, 20) != address or
        !std.mem.eql(u8, bytes[28..32], &.{ 17, 5, 5, 0 }) or
        !std.mem.eql(u8, bytes[32..64], &target_name)) return error.WrongTarget;
    return .{ .size = size, .checksum = word(bytes, 24) };
}

/// Read only into the fixed payload reservation. Execution is a separate step,
/// reachable only after the complete payload checksum has passed.
pub fn load(reader: anytype, file_size: u32, output: []u8) !Header {
    var bytes: [header_bytes]u8 = undefined;
    try readExact(reader, &bytes);
    const parsed = try header(&bytes, file_size);
    if (parsed.size > output.len) return error.InvalidSize;
    var checksum = std.hash.Crc32.init();
    var position: usize = 0;
    while (position < parsed.size) {
        const end = @min(parsed.size, position + 16 * 1024);
        const chunk = output[position..end];
        try readExact(reader, chunk);
        checksum.update(chunk);
        position = end;
    }
    if (checksum.final() != parsed.checksum) return error.PayloadChecksum;
    return parsed;
}

pub fn readExact(reader: anytype, bytes: []u8) !void {
    var position: usize = 0;
    while (position < bytes.len) {
        const count = try reader.read(bytes[position..]);
        if (count == 0) return error.UnexpectedEnd;
        position += count;
    }
}

pub fn envelope(payload: []const u8, output: []u8) []u8 {
    std.debug.assert(payload.len > 0 and payload.len <= limit and output.len >= header_bytes + payload.len);
    const result = output[0 .. header_bytes + payload.len];
    @memset(result[0..header_bytes], 0);
    for ([_]struct { usize, u32 }{ .{ 0, 0x27051956 }, .{ 12, @intCast(payload.len) }, .{ 16, address }, .{ 20, address }, .{ 24, std.hash.Crc32.hash(payload) } }) |item|
        std.mem.writeInt(u32, result[item[0]..][0..4], item[1], .big);
    @memcpy(result[28..32], &[_]u8{ 17, 5, 5, 0 });
    @memcpy(result[32..64], &target_name);
    std.mem.writeInt(u32, result[4..8], std.hash.Crc32.hash(result[0..header_bytes]), .big);
    @memcpy(result[header_bytes..], payload);
    return result;
}

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    quantum: usize = 13,
    fail_at: ?usize = null,
    fn read(self: *@This(), output: []u8) !usize {
        if (self.fail_at) |at| if (self.position >= at) return error.ReadFailed;
        const count = @min(output.len, self.bytes.len - self.position, self.quantum);
        @memcpy(output[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};

test "all truncations and every one-bit mutation reject without executing" {
    var buffer: [320]u8 = undefined;
    var payload: [256]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
    const valid = envelope(&payload, &buffer);
    var destination: [258]u8 = @splat(0xa5);
    var good = Reader{ .bytes = valid };
    _ = try load(&good, @intCast(valid.len), destination[1..257]);
    try std.testing.expectEqualSlices(u8, &payload, destination[1..257]);
    for (0..valid.len) |length| {
        var truncated = Reader{ .bytes = valid[0..length] };
        if (load(&truncated, @intCast(length), destination[1..257])) |_| return error.AcceptedTruncation else |_| {}
    }
    for (0..valid.len) |offset| for (0..8) |bit| {
        valid[offset] ^= @as(u8, 1) << @intCast(bit);
        var corrupt = Reader{ .bytes = valid };
        if (load(&corrupt, @intCast(valid.len), destination[1..257])) |_| return error.AcceptedMutation else |_| {}
        valid[offset] ^= @as(u8, 1) << @intCast(bit);
    };
    try std.testing.expectEqual(@as(u8, 0xa5), destination[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), destination[257]);
}

test "valid checksums do not bypass target and size checks" {
    var bytes: [65]u8 = undefined;
    _ = envelope("x", &bytes);
    for ([_]usize{ 12, 16, 20, 28, 29, 30, 31, 32, 63 }) |offset| {
        var changed = bytes;
        changed[offset] ^= 1;
        @memset(changed[4..8], 0);
        std.mem.writeInt(u32, changed[4..8], std.hash.Crc32.hash(changed[0..64]), .big);
        if (header(&changed, changed.len)) |_| return error.AcceptedWrongTarget else |_| {}
    }
    try std.testing.expectError(error.InvalidSize, header(&bytes, 66));
    var reader = Reader{ .bytes = &bytes, .quantum = 1, .fail_at = 20 };
    var output: [1]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, load(&reader, bytes.len, &output));
    reader = .{ .bytes = &bytes };
    try std.testing.expectError(error.InvalidSize, load(&reader, bytes.len, &.{}));
}
