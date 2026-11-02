const std = @import("std");
const codec = @import("codecs");

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn read(self: *@This(), output: []u8) !usize {
        const count = @min(output.len, self.bytes.len - self.position);
        @memcpy(output[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }

    pub fn seekTo(self: *@This(), position: u32) !void {
        if (position > self.bytes.len) return error.Truncated;
        self.position = position;
    }
};

// Smith.slice consumes a little-endian u32 length before the seed payload.
// 0xffffffff selects all remaining seed bytes (clamped to the buffer size).
test "fuzz audio containers and PCM conversions with destination canaries" {
    try std.testing.fuzz({}, run, .{
        .corpus = &.{
            "\xff\xff\xff\xffFORM",
            "\xff\xff\xff\xffRIFF",
            "\xff\xff\xff\xffFORM\x00\x00\x00\x04AIFF",
            "\xff\xff\xff\xffFORM\xff\xff\xff\xffAIFC",
            "\xff\xff\xff\xffFORM\x00\x00\x00\x32AIFFCOMM\x00\x00\x00\x12\x00\x01\x00\x00\x00\x02\x00\x10\x40\x0e\xac\x44\x00\x00\x00\x00\x00\x00SSND\x00\x00\x00\x0c\x00\x00\x00\x00\x00\x00\x00\x00\x7f\xff\x80\x00",
            &.{ 255, 255, 255, 255, 0, 3, 24, 1, 0x7f, 0xff, 0xff, 0x80, 0, 0 },
            &.{ 255, 255, 255, 255, 2, 8, 64, 0, 0x3f, 0xe0, 0, 0, 0, 0, 0, 0 },
            &.{ 255, 255, 255, 255, 0, 4, 32, 0, 0x7f, 0xff, 0xff, 0xff },
        },
    });
}

fn run(_: void, smith: *std.testing.Smith) !void {
    var bytes: [4096]u8 = undefined;
    const input = bytes[0..smith.slice(&bytes)];
    var reader = Reader{ .bytes = input };
    const maybe_aiff = codec.aiff.parse(&reader) catch null;
    if (maybe_aiff) |info| try exercise(&reader, info.plan);
    reader.position = 0;
    const maybe_wave = codec.wav.parse(&reader) catch null;
    if (maybe_wave) |info| if (codec.pcm.Plan.fromWave(info)) |plan| {
        try exercise(&reader, plan);
    } else |_| {};
    if (input.len < 4) return;
    const format = codec.pcm.Sample.Format{
        .encoding = switch (input[0] % 3) {
            0 => .signed,
            1 => .unsigned,
            else => .float,
        },
        .bytes = @intCast(input[1] % 9),
        .valid_bits = @intCast(input[2] % 65),
        .endian = if (input[3] & 1 == 0) .little else .big,
    };
    if (!format.valid()) return;
    const source = input[4..];
    const channels: u16 = 1 + input[3] % 2;
    const frames = source.len / (format.bytes * channels);
    const plan = try codec.pcm.Plan.fromFormat(48000, channels, format, @intCast(frames));
    reader = .{ .bytes = source };
    try exercise(&reader, plan);
}

fn exercise(reader: *Reader, plan: codec.pcm.Plan) !void {
    var memory: [72]u8 = @splat(0xa5);
    var stream = codec.pcm.Stream(Reader).fromPlan(reader, plan);
    const output = memory[4..68];
    // Bounded even if malicious metadata declares billions of sample frames.
    _ = stream.fill(output) catch null;
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, memory[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, memory[68..72]);
}
