//! Host checksum oracle: same decoder, independently tested PCM references.
const std = @import("std");
const gain = @import("gain");
const fixtures = @import("fixtures");
const checksum = @import("player_pcm_checksum.zig");

var arena: [2 * 1024 * 1024]u8 align(16) = undefined;
var packet: [65536 + 64]u8 = undefined;
var page: [65025]u8 = undefined;
var floats: [16384]f32 = undefined;
var frames: [8192]gain.pcm_reservoir.StereoFrame = undefined;
var cache: [65536]u8 = undefined;
var compressed: [256 * 1024]u8 = undefined;
var left: [65535]i32 = undefined;
var right: [65535]i32 = undefined;

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn seekTo(self: *Reader, offset: u32) !void {
        if (offset > self.bytes.len) return error.SeekBounds;
        self.position = offset;
    }

    pub fn read(self: *Reader, output: []u8) !usize {
        const count = @min(output.len, self.bytes.len - self.position);
        @memcpy(output[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};

const Sink = struct {
    hash: u32 = checksum.initial,

    pub fn configure(_: *Sink, _: gain.media_info.Information) !void {}

    pub fn push(self: *Sink, input: []const gain.pcm_reservoir.StereoFrame) !void {
        self.hash = checksum.update(self.hash, input);
    }
};

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const name = arguments.next() orelse return error.MissingFixture;
    const repeats = try std.fmt.parseInt(u32, arguments.next() orelse "1", 10);
    if (arguments.next() != null or repeats == 0 or repeats > 1000) return error.InvalidArguments;
    var sink = Sink{};
    var matched = false;
    for (0..repeats) |_| for (fixtures.cases) |case| {
        if (!std.mem.eql(u8, name, "mixed") and !std.mem.eql(u8, name, case.name)) continue;
        matched = true;
        var reader = Reader{ .bytes = case.bytes };
        var pool = try gain.codec_pool.Pool.init(&arena);
        _ = try gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, .{
            .packet = .{ .packet = &packet, .page = &page, .pcm = &floats, .frames = &frames, .pool = &pool },
            .cache = &cache,
            .compressed = &compressed,
            .left = &left,
            .right = &right,
        }, 0);
        if (pool.statistics.live != 0) return error.DecoderLeak;
    };
    if (!matched) return error.UnknownFixture;
    std.debug.print("{x}\n", .{sink.hash});
}
