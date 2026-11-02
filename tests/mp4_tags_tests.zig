const std = @import("std");
const tags = @import("mp4_tags");
const Source = struct {
    bytes: []const u8,
    length: u64,
    pub fn read(self: *@This(), offset: u64, output: []u8) !void {
        if (offset > self.length or output.len > self.length - offset) return error.Truncated;
        @memcpy(output, self.bytes[@intCast(offset)..][0..output.len]);
    }
    pub fn int(self: *@This(), comptime T: type, offset: u64, comptime endian: std.builtin.Endian) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.read(offset, &bytes);
        return std.mem.readInt(T, &bytes, endian);
    }
};
const Fixture = struct {
    bytes: [1024]u8 = @splat(0),
    length: usize = 0,
    text_offset: usize = 0,
    art_offset: usize = 0,
    fn begin(self: *@This(), kind: *const [4]u8) usize {
        const at = self.length;
        self.length += 8;
        @memcpy(self.bytes[at + 4 ..][0..4], kind);
        return at;
    }
    fn end(self: *@This(), at: usize) void {
        std.mem.writeInt(u32, self.bytes[at..][0..4], @intCast(self.length - at), .big);
    }
    fn append(self: *@This(), bytes: []const u8) void {
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }
    fn data(self: *@This(), bytes: []const u8) usize {
        const at = self.begin("data");
        self.append(&.{ 0, 0, 0, 1, 0, 0, 0, 0 });
        const payload = self.length;
        self.append(bytes);
        self.end(at);
        return payload;
    }
    fn init() Fixture {
        var fixture = Fixture{};
        const movie = fixture.begin("moov");
        const user = fixture.begin("udta");
        const meta = fixture.begin("meta");
        fixture.append(&.{ 0, 0, 0, 0 });
        const list = fixture.begin("ilst");
        const title = fixture.begin("\xa9nam");
        fixture.text_offset = fixture.data("Title A");
        _ = fixture.data("Title B");
        fixture.end(title);
        const cover = fixture.begin("covr");
        fixture.art_offset = fixture.data("encoded picture bytes");
        fixture.end(cover);
        fixture.end(list);
        fixture.end(meta);
        fixture.end(user);
        fixture.end(movie);
        return fixture;
    }
    fn scan(self: *const Fixture, hash_art: bool) !tags.Summary {
        var source = Source{ .bytes = self.bytes[0..self.length], .length = self.length };
        return tags.scan(&source, hash_art);
    }
};
test "M4A repeated text is counted and edits invalidate text and picture separately" {
    var fixture = Fixture.init();
    const before = try fixture.scan(true);
    try std.testing.expectEqual(@as(u32, 2), before.repeats[0]);
    try std.testing.expectEqualStrings("Title A", before.values[0][0..before.lengths[0]]);
    fixture.bytes[fixture.text_offset + 6] = 'C';
    const text = try fixture.scan(true);
    try std.testing.expect(!std.mem.eql(u8, &before.tag_digest, &text.tag_digest));
    try std.testing.expectEqual(before.art_digest, text.art_digest);
    fixture.bytes[fixture.art_offset + 5] ^= 1;
    const art = try fixture.scan(true);
    try std.testing.expectEqual(text.tag_digest, art.tag_digest);
    try std.testing.expect(!std.mem.eql(u8, &text.art_digest, &art.art_digest));
}
test "M4A every truncation is rejected and a tag-only check does not depend on picture payload" {
    var fixture = Fixture.init();
    for (0..fixture.length) |length| {
        var source = Source{ .bytes = fixture.bytes[0..length], .length = length };
        if (tags.scan(&source, true)) |_| return error.AcceptedTruncation else |_| {}
    }
    const before = try fixture.scan(false);
    @memset(fixture.bytes[fixture.art_offset..fixture.length], 0xff);
    const after = try fixture.scan(false);
    try std.testing.expectEqual(before.tag_digest, after.tag_digest);
    try std.testing.expectEqual(@as(u32, 1), after.art_count);
}
