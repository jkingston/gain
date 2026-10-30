const std = @import("std");
const f20 = @import("f20");
const flac = f20.flac;
const flac_lpc = f20.flac_lpc;
const flac_pcm = f20.flac_pcm;

const trial_count = 20;
const maximum_block_frames = 65_535;
const maximum_chunk_bytes = maximum_block_frames * 8;
const maximum_compressed_bytes = 256 * 1024;

var left: [maximum_block_frames]i32 = undefined;
var right: [maximum_block_frames]i32 = undefined;
var compressed: [maximum_compressed_bytes]u8 = undefined;
var output: [maximum_chunk_bytes]u8 align(4) = undefined;
var lpc_samples: [16_384]i32 = undefined;

const SliceReader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn read(self: *SliceReader, destination: []u8) !usize {
        const count = @min(destination.len, self.bytes.len - self.position);
        @memcpy(destination[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};

const Result = struct {
    samples: [trial_count]u64,
    checksum: u64,
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(
        "gain FLAC microbenchmarks (ReleaseFast, elapsed time; lower is better)\n" ++
            "case                         min ms   median ms      p95 ms      max ms\n",
    );

    try report(stdout, "decode 192k high-order LPC", try benchmarkDecode(
        init.io,
        @embedFile("fixtures/flac-device-192.flac"),
        20,
    ));
    try report(stdout, "decode noisy Rice residuals", try benchmarkDecode(
        init.io,
        @embedFile("fixtures/flac-noise-24.flac"),
        40,
    ));
    try report(stdout, "decode constant + CRC", try benchmarkDecode(
        init.io,
        @embedFile("fixtures/flac-constant.flac"),
        200,
    ));
    try report(stdout, "decode all stereo modes", try benchmarkStereoModes(init.io, 25));
    try report(stdout, "stream decode + PCM pack", try benchmarkStream(
        init.io,
        @embedFile("fixtures/flac-device-192.flac"),
        20,
    ));
    inline for (.{ 4, 8, 16, 24, 32 }) |order| {
        try report(stdout, std.fmt.comptimePrint("LPC reconstruction order {d}", .{order}), try benchmarkLpc(
            init.io,
            order,
            400,
        ));
    }
    try stdout.flush();
}

fn benchmarkDecode(io: std.Io, source: []const u8, repetitions: usize) !Result {
    const info = try flac.parseStreamInfo(source);
    var result: Result = .{ .samples = undefined, .checksum = 0 };
    for (0..trial_count) |trial| {
        const start = now(io);
        var checksum: u64 = 0;
        for (0..repetitions) |_| {
            var offset = info.first_frame_offset;
            while (offset < source.len) {
                const frame = try flac.decodeFrame(source[offset..], info, &left, &right);
                checksum +%= @as(u32, @bitCast(left[frame.block_size - 1]));
                checksum +%= @as(u32, @bitCast(right[frame.block_size - 1]));
                offset += frame.bytes_consumed;
            }
        }
        result.samples[trial] = elapsed(io, start);
        result.checksum +%= checksum;
    }
    return result;
}

fn benchmarkStereoModes(io: std.Io, repetitions: usize) !Result {
    const sources = .{
        @embedFile("fixtures/flac-mode-independent.flac"),
        @embedFile("fixtures/flac-mode-left-side.flac"),
        @embedFile("fixtures/flac-mode-right-side.flac"),
        @embedFile("fixtures/flac-mode-mid-side.flac"),
    };
    var result: Result = .{ .samples = undefined, .checksum = 0 };
    for (0..trial_count) |trial| {
        const start = now(io);
        var checksum: u64 = 0;
        for (0..repetitions) |_| {
            inline for (sources) |source| {
                const info = try flac.parseStreamInfo(source);
                var offset = info.first_frame_offset;
                while (offset < source.len) {
                    const frame = try flac.decodeFrame(source[offset..], info, &left, &right);
                    checksum +%= @as(u32, @bitCast(left[frame.block_size - 1]));
                    checksum +%= @as(u32, @bitCast(right[frame.block_size - 1]));
                    offset += frame.bytes_consumed;
                }
            }
        }
        result.samples[trial] = elapsed(io, start);
        result.checksum +%= checksum;
    }
    return result;
}

fn benchmarkStream(io: std.Io, source: []const u8, repetitions: usize) !Result {
    var result: Result = .{ .samples = undefined, .checksum = 0 };
    for (0..trial_count) |trial| {
        const start = now(io);
        var checksum: u64 = 0;
        for (0..repetitions) |_| {
            var reader: SliceReader = .{ .bytes = source };
            var stream = try flac_pcm.Stream(SliceReader).init(
                &reader,
                &compressed,
                &left,
                &right,
            );
            const chunk = output[0..stream.plan.chunkBytes()];
            while (true) {
                const fill = try stream.fill(chunk);
                checksum +%= std.mem.readInt(u32, chunk[fill.bytes - 4 ..][0..4], .little);
                if (fill.end) break;
            }
        }
        result.samples[trial] = elapsed(io, start);
        result.checksum +%= checksum;
    }
    return result;
}

fn benchmarkLpc(io: std.Io, comptime order: u6, repetitions: usize) !Result {
    const coefficients: [order]i32 = @splat(1);
    var result: Result = .{ .samples = undefined, .checksum = 0 };
    for (0..trial_count) |trial| {
        const start = now(io);
        var checksum: u64 = 0;
        for (0..repetitions) |seed| {
            for (&lpc_samples, 0..) |*sample, index| {
                sample.* = @intCast((index + seed) & 7);
            }
            try flac_lpc.restore(&lpc_samples, order, &coefficients, 8);
            checksum +%= @as(u32, @bitCast(lpc_samples[lpc_samples.len - 1]));
        }
        result.samples[trial] = elapsed(io, start);
        result.checksum +%= checksum;
    }
    return result;
}

fn report(writer: *std.Io.Writer, name: []const u8, result: Result) !void {
    var samples = result.samples;
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(result.checksum);
    try writer.print("{s:<28} {d:>8.3} {d:>11.3} {d:>11.3} {d:>11.3}\n", .{
        name,
        milliseconds(samples[0]),
        milliseconds(samples[trial_count / 2]),
        milliseconds(samples[p95Index()]),
        milliseconds(samples[trial_count - 1]),
    });
}

fn p95Index() usize {
    return (trial_count * 95 + 99) / 100 - 1;
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn elapsed(io: std.Io, start: i96) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds - start);
}

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}
