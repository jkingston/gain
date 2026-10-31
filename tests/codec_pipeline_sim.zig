//! Deterministic integration of production buffering, decoders, PCM backpressure
//! and DMA packing. This controls event ordering, not instruction timing.
const std = @import("std");
const gain = @import("gain");
const fixtures = @import("codec_fixtures.zig");
const Frame = gain.pcm_reservoir.StereoFrame;
const Pool = gain.codec_pool.Pool;

var arena: [512 * 1024]u8 align(16) = undefined;
var packet: [65536 + 64]u8 = undefined;
var page: [65025]u8 = undefined;
var floats: [16384]f32 = undefined;
var frames: [8192]Frame = undefined;
var cache: [4096]u8 = undefined;
var compressed: [256 * 1024]u8 = undefined;
var left: [65535]i32 = undefined;
var right: [65535]i32 = undefined;
var expected: [100000]Frame = undefined;

fn workspace(pool: *Pool) gain.media_decoder.Workspace {
    return .{
        .packet = .{ .packet = &packet, .page = &page, .pcm = &floats, .frames = &frames, .pool = pool },
        .cache = &cache,
        .compressed = &compressed,
        .left = &left,
        .right = &right,
    };
}
const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    random: std.Random.DefaultPrng,
    pub fn seekTo(self: *Reader, target: u32) !void {
        if (target > self.bytes.len) return error.SeekBounds;
        self.position = target;
    }
    pub fn read(self: *Reader, output: []u8) !usize {
        const count = @min(output.len, 1 + self.random.random().uintLessThan(usize, 997), self.bytes.len - self.position);
        @memcpy(output[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};
const Capture = struct {
    count: usize = 0,
    pub fn configure(_: *Capture, _: gain.media_info.Information) !void {}
    pub fn push(self: *Capture, input: []const Frame) !void {
        if (input.len > expected.len - self.count) return error.OutputCapacity;
        @memcpy(expected[self.count..][0..input.len], input);
        self.count += input.len;
    }
};
const Simulation = struct {
    const Input = gain.input_stream.Stream(Reader, @This());
    reader: Reader = undefined,
    input: Input = undefined,
    bytes: [2053]u8 = undefined,
    burst: [997]u8 = undefined,
    pcm: [8191]Frame = undefined,
    reservoir: gain.pcm_reservoir.Ring = undefined,
    dma: [1920 * 8]u8 align(4) = undefined,
    plan: ?gain.audio_output.Plan = null,
    dither: bool = false,
    quantizer: gain.pcm.Sample.Quantizer = .{},
    produced: usize = 0,
    consumed: usize = 0,
    waits: usize = 0,
    periods: usize = 0,
    storage_completions: usize = 0,
    random: std.Random.DefaultPrng = undefined,
    pub fn init(self: *Simulation, case: fixtures.Case, seed: u64) !void {
        self.* = .{};
        self.reader = .{ .bytes = case.bytes, .random = .init(seed) };
        self.random = .init(seed ^ 0x4741494e);
        self.input = try Input.init(&self.reader, @intCast(case.bytes.len), &self.bytes, self);
        self.reservoir = try gain.pcm_reservoir.Ring.init(&self.pcm);
    }
    pub fn cancelled(_: *Simulation) bool {
        return false;
    }
    pub fn wakeStorage(_: *Simulation) void {}
    pub fn wakeInput(self: *Simulation) void {
        self.storage_completions += 1;
    }
    pub fn prepareInputWait(self: *Simulation) void {
        // Complete some reads in the exact notification-clear/wait window.
        if (self.random.random().boolean()) _ = self.input.produce(&self.burst) catch unreachable;
    }
    pub fn waitInput(self: *Simulation) void {
        self.waits += 1;
        // A spurious wake must preserve the predicate. All other wakes run
        // one bounded storage burst, as the board's storage task will do.
        if (self.waits % 7 != 0) _ = self.input.produce(&self.burst) catch unreachable;
    }
    pub fn configure(self: *Simulation, information: gain.media_info.Information) !void {
        const plan = try gain.audio_output.Plan.init(information.sample_rate, information.output_format);
        if (self.plan) |previous| try std.testing.expectEqualDeep(previous, plan);
        self.plan = plan;
        self.dither = information.source_bits > 24;
    }
    pub fn push(self: *Simulation, input: []const Frame) !void {
        var offset: usize = 0;
        while (offset < input.len) {
            const written = self.reservoir.write(input[offset..]);
            offset += written;
            self.produced += written;
            if (written == 0 or self.random.random().boolean()) {
                if (self.reservoir.available() >= self.plan.?.frames) try self.consume(false);
            }
        }
    }
    fn consume(self: *Simulation, final: bool) !void {
        const plan = self.plan.?;
        const dma = self.dma[0..plan.bytes];
        const rendered = if (self.dither) try gain.audio_output.renderPeriodDithered(&self.reservoir, dma, plan, gain.audio_output.unity_gain_q24, &self.quantizer) else try gain.audio_output.renderPeriod(&self.reservoir, dma, plan, gain.audio_output.unity_gain_q24);
        try std.testing.expectEqual(rendered.frames < plan.frames, rendered.underrun);
        if (!final) try std.testing.expect(!rendered.underrun);
        for (0..rendered.frames) |i| {
            const frame = expected[self.consumed + i];
            const shift: f64 = if (plan.format == .signed_16_packed) 65536 else 256;
            const low: f64 = if (plan.format == .signed_16_packed) -32768 else -8388608;
            const high: f64 = if (plan.format == .signed_16_packed) 32767 else 8388607;
            // Independent float64 oracle for the integer output quantizer.
            for ([_]i32{ frame.left, frame.right }, 0..) |sample, channel| {
                const quantized: i32 = @intFromFloat(@max(low, @min(high, @round(@as(f64, @floatFromInt(sample)) / shift))));
                const sample_bytes: usize = if (plan.format == .signed_16_packed) 2 else 4;
                const at = i * plan.format.bytesPerFrame() + channel * sample_bytes;
                if (sample_bytes == 2) {
                    const actual: i16 = @bitCast(std.mem.readInt(u16, dma[at..][0..2], .little));
                    try std.testing.expectEqual(quantized, actual);
                } else {
                    const actual = std.mem.readInt(u32, dma[at..][0..4], .little);
                    if (self.dither) {
                        const signed: i32 = @as(i32, @bitCast(actual << 8)) >> 8;
                        // TPDF shifts the nearest reference value by at most
                        // one output LSB. Its exact sequence has a golden test.
                        try std.testing.expect(@abs(@as(i64, signed) - quantized) <= 1);
                    } else try std.testing.expectEqual(@as(u32, @bitCast(quantized)) & 0xffffff, actual);
                }
            }
        }
        const tail = rendered.frames * plan.format.bytesPerFrame();
        for (dma[tail..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        self.consumed += rendered.frames;
        self.periods += 1;
    }
};

test "all codecs traverse buffered SD input and fixed-period DMA with seeded interleavings" {
    for (fixtures.cases) |case| {
        var reader = Reader{ .bytes = case.bytes, .random = .init(0x4741494e) };
        var pool = try Pool.init(&arena);
        var capture = Capture{};
        _ = try gain.media_decoder.run(&reader, case.bytes.len, Capture, &capture, workspace(&pool), 0);
        try std.testing.expectEqual(case.frames, capture.count);
        try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
        for ([_]u64{ 0x1234, 0x5eed, 0xffffffff }) |seed| {
            var simulation: Simulation = undefined;
            try simulation.init(case, seed);
            pool = try Pool.init(&arena);
            _ = try gain.media_decoder.run(&simulation.input, case.bytes.len, Simulation, &simulation, workspace(&pool), 0);
            while (simulation.reservoir.available() != 0) try simulation.consume(true);
            try std.testing.expectEqual(case.frames, simulation.produced);
            try std.testing.expectEqual(case.frames, simulation.consumed);
            try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
            try std.testing.expect(simulation.storage_completions > 0);
            try std.testing.expect(simulation.waits > 0);
            try std.testing.expect(simulation.periods > 1);
            if (simulation.dither) try std.testing.expect(simulation.quantizer.random != (gain.pcm.Sample.Quantizer{}).random);
        }
    }
}
