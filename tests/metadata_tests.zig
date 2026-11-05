const std = @import("std");
const metadata = @import("metadata");
const Source = struct {
    bytes: []const u8,
    length: u64,
    forbidden_start: u64 = 0,
    forbidden_end: u64 = 0,

    pub fn read(self: *@This(), at: u64, out: []u8) !void {
        if (at > self.length or out.len > self.length - at) return error.Truncated;
        if (out.len != 0 and at < self.forbidden_end and at + out.len > self.forbidden_start) return error.ReadAudioPayload;
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
    pub fn int(self: *@This(), comptime T: type, at: u64, comptime endian: std.builtin.Endian) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.read(at, &bytes);
        return std.mem.readInt(T, &bytes, endian);
    }
};
test "native Vorbis and Opus tags match independently encoded codec fixtures" {
    const cases = [_]struct { bytes: []const u8, extension: []const u8, rate: u32 }{
        .{ .bytes = @embedFile("fixtures/codecs/opus48.opus"), .extension = ".opus", .rate = 48000 },
        .{ .bytes = @embedFile("fixtures/codecs/vorbis44.ogg"), .extension = ".ogg", .rate = 44100 },
        .{ .bytes = @embedFile("fixtures/codecs/vorbis-continued.ogg"), .extension = ".ogg", .rate = 44100 },
    };
    for (cases) |case| {
        var source = Source{ .bytes = case.bytes, .length = case.bytes.len };
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const tags = try metadata.extract(arena.allocator(), &source, case.extension);
        try std.testing.expectEqualStrings("Gain spike", tags.title);
        try std.testing.expectEqual(case.rate, tags.sample_rate);
        try std.testing.expect(tags.duration_ms > 0);
        var corrupt = try std.testing.allocator.dupe(u8, case.bytes);
        defer std.testing.allocator.free(corrupt);
        corrupt[30] ^= 1;
        source.bytes = corrupt;
        if (metadata.extract(arena.allocator(), &source, case.extension)) |_| return error.AcceptedCorruptOgg else |_| {}
    }
}

test "MPEG tags and Xing timing are read without decoding samples" {
    const bytes = @embedFile("fixtures/codecs/stereo44.mp3");
    var source = Source{ .bytes = bytes, .length = bytes.len };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tags = try metadata.extract(arena.allocator(), &source, ".mp3");
    try std.testing.expectEqual(44100, tags.sample_rate);
    try std.testing.expectEqual(2, tags.channels);
    try std.testing.expectEqualStrings("mp3", tags.codec);
}

test "WAV INFO and AIFF names after PCM payloads are indexed without reading the audio" {
    const wave = @embedFile("fixtures/codecs/wave16.wav");
    const suffix = "LIST\x1a\x00\x00\x00INFOINAM\x0e\x00\x00\x00Fictional Song";
    const bytes = try std.testing.allocator.alloc(u8, wave.len + suffix.len);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..wave.len], wave);
    @memcpy(bytes[wave.len..], suffix);
    std.mem.writeInt(u32, bytes[4..8], @intCast(bytes.len - 8), .little);
    const data = std.mem.indexOf(u8, wave, "data").?;
    var source = Source{ .bytes = bytes, .length = bytes.len, .forbidden_start = data + 8, .forbidden_end = wave.len };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tags = try metadata.extract(arena.allocator(), &source, ".wav");
    try std.testing.expectEqualStrings("Fictional Song", tags.title);
    try std.testing.expectEqualStrings("wave", tags.codec);
    try std.testing.expect(tags.duration_ms > 0);
    const aiff = @embedFile("fixtures/codecs/aiff24.aiff");
    const name = "NAME\x00\x00\x00\x04Name";
    const other = try std.testing.allocator.alloc(u8, aiff.len + name.len);
    defer std.testing.allocator.free(other);
    @memcpy(other[0..aiff.len], aiff);
    @memcpy(other[aiff.len..], name);
    std.mem.writeInt(u32, other[4..8], @intCast(other.len - 8), .big);
    const sound = std.mem.indexOf(u8, aiff, "SSND").?;
    source = .{ .bytes = other, .length = other.len, .forbidden_start = sound + 16, .forbidden_end = aiff.len };
    const info = try metadata.extract(arena.allocator(), &source, ".aiff");
    try std.testing.expectEqualStrings("Name", info.title);
    try std.testing.expectEqual(24, info.bits);
}

test "MPEG header lookalikes cannot supply a fabricated sample rate" {
    var bytes: [512]u8 = @splat(0);
    @memcpy(bytes[0..4], &[_]u8{ 0xff, 0xfb, 0x90, 0x00 });
    var source = Source{ .bytes = &bytes, .length = bytes.len };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tags = try metadata.extract(arena.allocator(), &source, ".mp3");
    try std.testing.expectEqual(0, tags.sample_rate);
    try std.testing.expectEqual(0, tags.duration_ms);
}

test "every truncated codec header is bounded by the declared file length" {
    const cases = [_]struct { bytes: []const u8, extension: []const u8 }{
        .{ .bytes = @embedFile("fixtures/codecs/opus48.opus"), .extension = ".opus" },
        .{ .bytes = @embedFile("fixtures/codecs/stereo44.mp3"), .extension = ".mp3" },
        .{ .bytes = @embedFile("fixtures/codecs/wave16.wav"), .extension = ".wav" },
        .{ .bytes = @embedFile("fixtures/codecs/aiff24.aiff"), .extension = ".aiff" },
    };
    for (cases) |case| for (0..@min(case.bytes.len, 256)) |length| {
        var source = Source{ .bytes = case.bytes, .length = length };
        var memory: [32 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&memory);
        _ = metadata.extract(fixed.allocator(), &source, case.extension) catch continue;
    };
}

test "fuzz bounded tag and container readers" {
    try std.testing.fuzz({}, fuzz, .{ .corpus = &.{
        "\xff\xff\xff\xffID3\x04\x00\x00\x00\x00\x00\x00",
        "\xff\xff\xff\xff" ++ @embedFile("fixtures/codecs/opus48.opus"),
        "\xff\xff\xff\xff" ++ @embedFile("fixtures/codecs/stereo44.mp3"),
        "\xff\xff\xff\xff" ++ @embedFile("fixtures/codecs/wave16.wav"),
        "\xff\xff\xff\xff" ++ @embedFile("fixtures/codecs/aiff24.aiff"),
    } });
}

fn fuzz(_: void, smith: *std.testing.Smith) !void {
    var bytes: [8192]u8 = undefined;
    const input = bytes[0..smith.slice(&bytes)];
    var source = Source{ .bytes = input, .length = input.len };
    var memory: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    if (metadata.extract(fixed.allocator(), &source, ".mp3")) |tags| try checkText(tags) else |_| {}

    // Preserve the outer ID3 framing so mutations exercise text encodings,
    // frame flags and picture descriptions instead of stopping at the magic.
    var framed: [8213]u8 = @splat(0);
    @memcpy(framed[0..3], "ID3");
    framed[3] = 4;
    const ids = [_][]const u8{ "TIT2", "TXXX", "APIC" };
    @memcpy(framed[10..14], ids[if (input.len == 0) 0 else input[0] % ids.len]);
    framed[20] = if (input.len == 0) 0 else input[0] % 4;
    @memcpy(framed[21..][0..input.len], input);
    const frame_length: u32 = @intCast(input.len + 1);
    for (0..4) |i| {
        const shift: u5 = @intCast((3 - i) * 7);
        framed[6 + i] = @intCast(((frame_length + 10) >> shift) & 127);
        framed[14 + i] = @intCast((frame_length >> shift) & 127);
    }
    source = .{ .bytes = framed[0 .. input.len + 21], .length = input.len + 21 };
    fixed.reset();
    if (metadata.extract(fixed.allocator(), &source, ".mp3")) |tags| try checkText(tags) else |_| {}
    if (metadata.embeddedPicture(&source)) |picture| {
        if (picture) |range| try std.testing.expect(range.offset <= source.length and range.length <= source.length - range.offset);
    } else |_| {}
}

fn checkText(tags: anytype) !void {
    for ([_][]const u8{ tags.title, tags.artist, tags.album, tags.album_artist, tags.genre, tags.date }) |value| {
        try std.testing.expect(value.len <= 4096);
        try std.testing.expect(std.unicode.utf8ValidateSlice(value));
    }
}
