const std = @import("std");
const f20 = @import("f20");
const protocol = @import("f20_bench_report.zig");

const flac = f20.flac;
const flac_lpc = f20.flac_lpc;
const flac_pcm = f20.flac_pcm;
const x1000 = f20.soc;

const maximum_observations = 128;
const stream_repetitions = 4;
const maximum_block_frames = 65_535;
const compressed_bytes = 256 * 1024;
const output_bytes = maximum_block_frames * 8;
const left_samples_address = 0x8090_0000;
const right_samples_address = 0x8094_0000;
const compressed_frame_address = 0x8098_0000;
const cached_output_address = 0x80d0_0000;
const uncached_output_address = 0xa0d0_0000;
const lpc_samples_address = 0x80e0_0000;
const sd_descriptor_address = 0xa007_f000;
const sd_switch_status_address = 0xa007_f100;
const sd_scratch_address = 0xa008_0000;
const sd_bounce_address = 0xa00a_0000;

const report: *volatile protocol.Report = @ptrFromInt(protocol.report_address);
const selected_case: *volatile u32 = @ptrFromInt(protocol.selection_address);
const source: []const u8 = @as([*]const u8, @ptrFromInt(protocol.source_address))[0..protocol.source_bytes];
const left: *[maximum_block_frames]i32 = @ptrFromInt(left_samples_address);
const right: *[maximum_block_frames]i32 = @ptrFromInt(right_samples_address);
const compressed: *[compressed_bytes]u8 = @ptrFromInt(compressed_frame_address);
const output_cached: *align(4) [output_bytes]u8 = @ptrFromInt(cached_output_address);
const output_uncached: *align(4) [output_bytes]u8 = @ptrFromInt(uncached_output_address);
const lpc_samples: *[16_384]i32 = @ptrFromInt(lpc_samples_address);

const sd_descriptor: *volatile f20.storage.DmaDescriptor = @ptrFromInt(sd_descriptor_address);
const sd_switch_status: *align(4) [64]u8 = @ptrFromInt(sd_switch_status_address);
const sd_scratch: *[f20.storage.fat32.sector_bytes]u8 = @ptrFromInt(sd_scratch_address);
const sd_bounce: *align(4) [64 * 1024 - 4]u8 = @ptrFromInt(sd_bounce_address);

var timings: [maximum_observations]u32 = undefined;
var timing_count: usize = 0;

const SliceReader = struct {
    position: usize = 0,

    pub fn read(self: *SliceReader, destination: []u8) !usize {
        const count = @min(destination.len, source.len - self.position);
        @memcpy(destination[0..count], source[self.position..][0..count]);
        self.position += count;
        return count;
    }
};

fn TimedReader(comptime Inner: type) type {
    return struct {
        inner: *Inner,
        ticks: u32 = 0,

        pub fn read(self: *@This(), destination: []u8) !usize {
            const started = x1000.Timer.now();
            const count = try self.inner.read(destination);
            self.ticks +%= x1000.Timer.elapsed(started);
            return count;
        }
    };
}

export fn benchmark_main() callconv(.c) void {
    const case: protocol.Case = std.enums.fromInt(protocol.Case, selected_case.*) orelse return;
    if (case == .decode_frames or !validReport()) clearReport();
    x1000.Timer.initialize();
    switch (case) {
        .decode_frames => run(case, benchmarkDecodeFrames),
        .stream_uncached => run(case, benchmarkRamStreamUncached),
        .stream_cached => {
            run(case, benchmarkRamStreamCached);
            verifyMatchingOutput(.stream_uncached, .stream_cached);
        },
        .lpc_order_4 => run(case, benchmarkLpc4),
        .lpc_order_8 => run(case, benchmarkLpc8),
        .lpc_order_16 => run(case, benchmarkLpc16),
        .lpc_order_24 => run(case, benchmarkLpc24),
        .lpc_order_32 => run(case, benchmarkLpc32),
        .sd_initialize => run(case, benchmarkSdInitialize),
        .sd_mount => run(case, benchmarkSdMount),
        .sd_open => run(case, benchmarkSdOpen),
        .sd_stream_uncached => run(case, benchmarkSdStreamUncached),
        .sd_stream_cached => {
            run(case, benchmarkSdStreamCached);
            verifyMatchingOutput(.sd_stream_uncached, .sd_stream_cached);
        },
    }
    x1000.memoryBarrier();
}

fn run(case: protocol.Case, benchmark: *const fn (*u32, *u32) anyerror!void) void {
    const index = @backingInt(case);
    var checksum: u32 = 0;
    var auxiliary_ticks: u32 = 0;
    timing_count = 0;
    benchmark(&checksum, &auxiliary_ticks) catch |failure| {
        report.entries[index] = .{
            .case = index,
            .error_code = @intFromError(failure),
            .checksum = checksum,
        };
        report.failure_code = @intFromError(failure);
        report.completed_case_mask |= protocol.caseBit(case);
        return;
    };
    std.mem.sort(u32, timings[0..timing_count], {}, std.sort.asc(u32));
    report.entries[index] = .{
        .case = index,
        .observations = @intCast(timing_count),
        .minimum_ticks = timings[0],
        .median_ticks = timings[timing_count / 2],
        .p95_ticks = timings[p95Index(timing_count)],
        .maximum_ticks = timings[timing_count - 1],
        .auxiliary_ticks = auxiliary_ticks,
        .checksum = checksum,
    };
    report.completed_case_mask |= protocol.caseBit(case);
}

fn benchmarkDecodeFrames(checksum: *u32, _: *u32) !void {
    const info = try flac.parseStreamInfo(source);
    for (0..stream_repetitions) |_| {
        var offset = info.first_frame_offset;
        while (offset < source.len) {
            const started = x1000.Timer.now();
            const frame = try flac.decodeFrame(source[offset..], info, left, right);
            observe(x1000.Timer.elapsed(started));
            checksum.* +%= @as(u32, @bitCast(left[frame.block_size - 1]));
            checksum.* +%= @as(u32, @bitCast(right[frame.block_size - 1]));
            offset += frame.bytes_consumed;
        }
    }
}

fn benchmarkRamStreamUncached(checksum: *u32, auxiliary_ticks: *u32) !void {
    try benchmarkRamStream(output_uncached, checksum, auxiliary_ticks);
}

fn benchmarkRamStreamCached(checksum: *u32, auxiliary_ticks: *u32) !void {
    try benchmarkRamStream(output_cached, checksum, auxiliary_ticks);
}

fn benchmarkRamStream(destination: []u8, checksum: *u32, _: *u32) !void {
    for (0..stream_repetitions) |_| {
        var reader: SliceReader = .{};
        var stream = try flac_pcm.Stream(SliceReader).init(&reader, compressed, left, right);
        const chunk = destination[0..stream.plan.chunkBytes()];
        while (true) {
            const started = x1000.Timer.now();
            const fill = try stream.fill(chunk);
            x1000.memoryBarrier();
            observe(x1000.Timer.elapsed(started));
            checksum.* +%= checksumOutput(output_uncached[0..chunk.len], fill.bytes);
            if (fill.end) break;
        }
    }
}

fn benchmarkLpc4(checksum: *u32, auxiliary_ticks: *u32) !void {
    try benchmarkLpc(4, checksum, auxiliary_ticks);
}

fn benchmarkLpc8(checksum: *u32, auxiliary_ticks: *u32) !void {
    try benchmarkLpc(8, checksum, auxiliary_ticks);
}

fn benchmarkLpc16(checksum: *u32, auxiliary_ticks: *u32) !void {
    try benchmarkLpc(16, checksum, auxiliary_ticks);
}

fn benchmarkLpc24(checksum: *u32, auxiliary_ticks: *u32) !void {
    try benchmarkLpc(24, checksum, auxiliary_ticks);
}

fn benchmarkLpc32(checksum: *u32, auxiliary_ticks: *u32) !void {
    try benchmarkLpc(32, checksum, auxiliary_ticks);
}

fn benchmarkLpc(comptime order: u6, checksum: *u32, _: *u32) !void {
    const coefficients: [order]i32 = @splat(1);
    for (0..32) |seed| {
        for (lpc_samples, 0..) |*sample, index| sample.* = @intCast((index + seed) & 7);
        const started = x1000.Timer.now();
        try flac_lpc.restore(lpc_samples, order, &coefficients, 8);
        observe(x1000.Timer.elapsed(started));
        checksum.* +%= @as(u32, @bitCast(lpc_samples[lpc_samples.len - 1]));
    }
}

fn benchmarkSdStreamUncached(checksum: *u32, auxiliary_ticks: *u32) !void {
    try benchmarkSdStream(output_uncached, checksum, auxiliary_ticks);
}

fn benchmarkSdInitialize(checksum: *u32, _: *u32) !void {
    const started = x1000.Timer.now();
    _ = try f20.storage.Controller.initialize(.{
        .descriptor = sd_descriptor,
        .switch_status = sd_switch_status,
    });
    observe(x1000.Timer.elapsed(started));
    checksum.* = 1;
}

fn benchmarkSdMount(checksum: *u32, _: *u32) !void {
    var storage = try f20.storage.Controller.initialize(.{
        .descriptor = sd_descriptor,
        .switch_status = sd_switch_status,
    });
    const started = x1000.Timer.now();
    _ = try f20.storage.fat32.Volume(f20.storage.Controller).mount(&storage, sd_scratch);
    observe(x1000.Timer.elapsed(started));
    checksum.* = 1;
}

fn benchmarkSdOpen(checksum: *u32, _: *u32) !void {
    var storage = try f20.storage.Controller.initialize(.{
        .descriptor = sd_descriptor,
        .switch_status = sd_switch_status,
    });
    var volume = try f20.storage.fat32.Volume(f20.storage.Controller).mount(&storage, sd_scratch);
    const started = x1000.Timer.now();
    const file = try volume.findRoot("GAIN192 FLA".*);
    var file_reader = try volume.reader(file);
    var buffered_reader = try f20.storage.BufferedReader(@TypeOf(file_reader)).init(&file_reader, sd_bounce);
    const stream = try flac_pcm.Stream(@TypeOf(buffered_reader)).init(&buffered_reader, compressed, left, right);
    observe(x1000.Timer.elapsed(started));
    checksum.* = @truncate(stream.plan.frames);
}

fn benchmarkSdStreamCached(checksum: *u32, auxiliary_ticks: *u32) !void {
    try benchmarkSdStream(output_cached, checksum, auxiliary_ticks);
}

fn benchmarkSdStream(destination: []u8, checksum: *u32, maximum_storage_ticks: *u32) !void {
    var storage = try f20.storage.Controller.initialize(.{
        .descriptor = sd_descriptor,
        .switch_status = sd_switch_status,
    });
    var volume = try f20.storage.fat32.Volume(f20.storage.Controller).mount(&storage, sd_scratch);
    const file = try volume.findRoot("GAIN192 FLA".*);
    var file_reader = try volume.reader(file);
    var buffered_reader = try f20.storage.BufferedReader(@TypeOf(file_reader)).init(&file_reader, sd_bounce);
    var timed_reader: TimedReader(@TypeOf(buffered_reader)) = .{ .inner = &buffered_reader };
    var stream = try flac_pcm.Stream(@TypeOf(timed_reader)).init(&timed_reader, compressed, left, right);
    const chunk = destination[0..stream.plan.chunkBytes()];
    while (true) {
        const storage_before = timed_reader.ticks;
        const started = x1000.Timer.now();
        const fill = try stream.fill(chunk);
        x1000.memoryBarrier();
        observe(x1000.Timer.elapsed(started));
        maximum_storage_ticks.* = @max(maximum_storage_ticks.*, timed_reader.ticks -% storage_before);
        checksum.* +%= checksumOutput(output_uncached[0..chunk.len], fill.bytes);
        if (fill.end) break;
    }
}

fn checksumOutput(bytes: []const u8, valid_bytes: u32) u32 {
    if (valid_bytes < 4) return 0;
    const word_count = valid_bytes / 4;
    const sample_count = @min(word_count, 64);
    var checksum: u32 = 0;
    for (0..sample_count) |sample| {
        const word = sample * (word_count - 1) / @max(sample_count - 1, 1);
        const offset = word * 4;
        checksum +%= std.mem.readInt(u32, bytes[offset..][0..4], .little);
    }
    return checksum;
}

fn verifyMatchingOutput(first: protocol.Case, second: protocol.Case) void {
    if (!protocol.caseCompleted(report.completed_case_mask, first) or
        !protocol.caseCompleted(report.completed_case_mask, second)) return;
    const left_entry = report.entries[@backingInt(first)];
    const right_entry = report.entries[@backingInt(second)];
    if (left_entry.error_code == 0 and right_entry.error_code == 0 and
        left_entry.checksum != right_entry.checksum)
    {
        report.failure_code = protocol.coherency_failure;
    }
}

fn observe(ticks: u32) void {
    if (timing_count == timings.len) return;
    timings[timing_count] = ticks;
    timing_count += 1;
}

fn p95Index(count: usize) usize {
    return (count * 95 + 99) / 100 - 1;
}

fn clearReport() void {
    const bytes: [*]volatile u8 = @ptrCast(report);
    for (0..@sizeOf(protocol.Report)) |index| bytes[index] = 0;
    report.magic_bytes = protocol.magic;
    report.report_version = protocol.version;
    report.timer_frequency = protocol.timer_hz;
}

fn validReport() bool {
    return std.mem.eql(u8, @volatileCast(&report.magic_bytes), &protocol.magic) and
        report.report_version == protocol.version;
}
