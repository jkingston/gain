const std = @import("std");
const gain = @import("gain");
const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    pub fn seekTo(self: *Reader, target: u32) !void {
        if (target > self.bytes.len) return error.Truncated;
        self.position = target;
    }
    pub fn read(self: *Reader, output: []u8) !usize {
        const count = @min(output.len, 31, self.bytes.len - self.position);
        @memcpy(output[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};
const Source = gain.media_source.Source(Reader);
fn seed(comptime bytes: []const u8) []const u8 {
    return "\xff\xff\xff\xff" ++ bytes;
}
test "fuzz MP4 atom sizes timing edits and sample cursors" {
    try std.testing.fuzz({}, runMp4, .{ .corpus = &.{
        seed("ftyp"),
        seed(@embedFile("fixtures/codecs/aac44.m4a")),
        seed(@embedFile("fixtures/codecs/alac16.m4a")),
        seed(@embedFile("fixtures/codecs/aac-co64-v1-chapters.m4a")),
        seed(@embedFile("fixtures/codecs/aac-multichunk.m4a")),
    } });
}
fn runMp4(_: void, smith: *std.testing.Smith) !void {
    var storage: [65536]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    var reader = Reader{ .bytes = input };
    var cache: [512]u8 = undefined;
    var source = try Source.init(&reader, input.len, &cache);
    const track = gain.mp4.parse(&source) catch return;
    _ = gain.mp4.readChapters(&source) catch null;
    for ([_]u64{ 0, track.frames / 2, track.frames, std.math.maxInt(u64) }) |frame| {
        const index = track.seekSample(&source, frame) catch continue;
        var cursor = gain.mp4.Cursor.init(&track, &source, index) catch continue;
        // Limit test work even if the file declares a long fixed-size track.
        for (0..64) |_| {
            const packet = (cursor.next(&source) catch break) orelse break;
            try std.testing.expect(packet.offset <= input.len);
            try std.testing.expect(packet.size <= input.len - packet.offset);
        }
    }
}
test "fuzz Ogg page framing and packet output bounds" {
    try std.testing.fuzz({}, runOgg, .{ .corpus = &.{
        seed("OggS"),
        seed(@embedFile("fixtures/codecs/vorbis44.ogg")),
        seed(@embedFile("fixtures/codecs/vorbis-continued.ogg")),
        seed(@embedFile("fixtures/codecs/opus-chain.ogg")),
    } });
}
fn runOgg(_: void, smith: *std.testing.Smith) !void {
    var storage: [65536]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    var reader = Reader{ .bytes = input };
    var cache: [512]u8 = undefined;
    var source = try Source.init(&reader, input.len, &cache);
    var body: [65025]u8 = undefined;
    var parser = gain.ogg.Reader(Source){ .source = &source, .body = &body };
    var output: [65544]u8 = @splat(0xa5);
    for (0..4096) |_| {
        const packet = (parser.next(output[4..65540]) catch break) orelse break;
        try std.testing.expect(packet.bytes.len <= 65536);
    }
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, output[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, output[65540..65544]);
    var title: [32]u8 = undefined;
    _ = gain.ogg.title(input, 0, &title) catch null;
}
