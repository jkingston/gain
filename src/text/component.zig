//! Versioned fixed-address engine envelope. Corruption is rejected before any
//! code executes; the normal boot image and recovery path remain independent.
const std = @import("std");
const abi = @import("contract.zig");
pub const header_bytes = 64;
pub const code_address: u32 = 0x81010000;
pub const code_capacity: u32 = 1024 * 1024;
pub const work_address: u32 = 0x80d78000;
pub const work_capacity: u32 = 0x88000;
pub const Header = struct {
    bytes: u32,
    crc: u32,

    pub fn decode(data: []const u8, file_bytes: u32) !Header {
        if (data.len < header_bytes or !std.mem.eql(u8, data[0..8], "GAINTE01")) return error.InvalidComponent;
        const word = @import("pack.zig").word;
        if (word(data, 8) != abi.version or word(data, 12) != code_address or word(data, 16) != code_capacity or
            word(data, 20) != work_address or word(data, 24) != work_capacity) return error.InvalidComponent;
        const h = Header{ .bytes = word(data, 28), .crc = word(data, 32) };
        if (h.bytes == 0 or h.bytes > code_capacity or @as(u64, h.bytes) + header_bytes != file_bytes) return error.InvalidComponent;
        return h;
    }

    pub fn validate(self: Header, code: []const u8) bool {
        return code.len == self.bytes and std.hash.Crc32.hash(code) == self.crc;
    }
};

test "component address, sizes, version and checksum are validated before execution" {
    var header: [header_bytes]u8 = @splat(0);
    @memcpy(header[0..8], "GAINTE01");
    for ([_]u32{ abi.version, code_address, code_capacity, work_address, work_capacity, 4, std.hash.Crc32.hash("test") }, 0..) |n, i| std.mem.writeInt(u32, header[8 + i * 4 ..][0..4], n, .little);
    const result = try Header.decode(&header, 68);
    try std.testing.expect(result.validate("test"));
    try std.testing.expect(!result.validate("fail"));
    header[12] ^= 1;
    try std.testing.expectError(error.InvalidComponent, Header.decode(&header, 68));
}
