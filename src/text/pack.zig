//! Little-endian, immutable SD font container. All offsets are checked before
//! reaching FreeType; the host generator emits the same format and a manifest.
const std = @import("std");
pub const version = 1;
pub const header_bytes = 64;
pub const face_bytes = 24;
pub const range_bytes = 12;
pub const max_faces = 256;
pub const max_ranges = 16384;
pub const Header = struct {
    faces: u32,
    ranges: u32,
    face_offset: u32,
    range_offset: u32,
    font_offset: u32,
    bytes: u32,
    cjk: [4]u16,

    pub fn decode(data: []const u8, source_bytes: u32) !Header {
        if (data.len < header_bytes or !std.mem.eql(u8, data[0..8], "GAINFT01") or word(data, 8) != version) return error.InvalidPack;
        const h = Header{ .faces = word(data, 12), .ranges = word(data, 16), .face_offset = word(data, 20), .range_offset = word(data, 24), .font_offset = word(data, 28), .bytes = word(data, 32), .cjk = .{ half(data, 36), half(data, 38), half(data, 40), half(data, 42) } };
        if (h.faces < 2 or h.faces > max_faces or h.ranges > max_ranges or (h.bytes != source_bytes or h.bytes > 128 * 1024 * 1024) or h.face_offset != header_bytes or
            @as(u64, h.face_offset) + @as(u64, h.faces) * face_bytes != h.range_offset or
            @as(u64, h.range_offset) + @as(u64, h.ranges) * range_bytes > h.font_offset or h.font_offset >= h.bytes) return error.InvalidPack;
        for (h.cjk) |family| if (family != 0xffff and family >= h.faces) return error.InvalidPack;
        return h;
    }
};
pub const Face = struct { offset: u32, bytes: u32 };
pub fn face(data: []const u8, weight: usize, header: Header) !Face {
    if (data.len != face_bytes or weight >= 3) return error.InvalidPack;
    const f = Face{ .offset = word(data, weight * 8), .bytes = word(data, weight * 8 + 4) };
    if (f.offset < header.font_offset or f.bytes < 12 or @as(u64, f.offset) + f.bytes > header.bytes) return error.InvalidPack;
    return f;
}
pub fn word(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}
pub fn half(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

test "invalid container counts, lengths and integer overflow are rejected" {
    var bytes: [header_bytes]u8 = @splat(0);
    try std.testing.expectError(error.InvalidPack, Header.decode(&bytes, 1000));
    @memcpy(bytes[0..8], "GAINFT01");
    for ([_]u32{ 1, 2, 1, 64, 112, 124, 1000 }, 0..) |n, i| std.mem.writeInt(u32, bytes[8 + i * 4 ..][0..4], n, .little);
    const header = try Header.decode(&bytes, 1000);
    var record: [face_bytes]u8 = @splat(0);
    std.mem.writeInt(u32, record[0..4], 0xfffffff0, .little);
    std.mem.writeInt(u32, record[4..8], 100, .little);
    try std.testing.expectError(error.InvalidPack, face(&record, 0, header));
    std.mem.writeInt(u32, bytes[12..16], 0xffffffff, .little);
    try std.testing.expectError(error.InvalidPack, Header.decode(&bytes, 1000));
}
