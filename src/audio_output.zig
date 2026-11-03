const std = @import("std");
const pcm = @import("pcm.zig");
const pcm_reservoir = @import("pcm_reservoir.zig");

pub const period_microseconds: u32 = 10_000;
pub const unity_gain_q24: u32 = 1 << 24;

pub const Error = error{
    InvalidSampleRate,
    InvalidPeriod,
    NonIntegralPeriod,
    InvalidOutputBuffer,
    InvalidGain,
    InvalidDitherFormat,
};

pub const Plan = struct {
    sample_rate: u32,
    format: pcm.OutputFormat,
    frames: u32,
    bytes: u32,

    pub fn init(sample_rate: u32, format: pcm.OutputFormat) Error!Plan {
        if (sample_rate == 0) return error.InvalidSampleRate;
        // Keep a constant descriptor length without rounding the native rate.
        // 22.05/11.025 kHz need 20/40 ms respectively; other board rates
        // contain an integral number of frames in the preferred 10 ms period.
        const numerator = @as(u64, sample_rate) * period_microseconds;
        const multiplier = 1_000_000 / std.math.gcd(numerator, 1_000_000);
        return initWithPeriod(sample_rate, format, @intCast(period_microseconds * multiplier));
    }

    pub fn initWithPeriod(
        sample_rate: u32,
        format: pcm.OutputFormat,
        requested_period_microseconds: u32,
    ) Error!Plan {
        if (sample_rate == 0) return error.InvalidSampleRate;
        const frame_numerator = @as(u64, sample_rate) * requested_period_microseconds;
        if (frame_numerator % 1_000_000 != 0) return error.NonIntegralPeriod;
        const frames = frame_numerator / 1_000_000;
        if (frames == 0 or frames > @as(u64, std.math.maxInt(u32)) / format.bytesPerFrame()) return error.InvalidPeriod;
        return .{
            .sample_rate = sample_rate,
            .format = format,
            .frames = @intCast(frames),
            .bytes = @intCast(frames * format.bytesPerFrame()),
        };
    }

    /// A missed descriptor interrupt must be checked within one DMA period.
    /// Waiting two periods can exhaust a three-buffer ring after wake latency.
    pub fn refillWatchdogTicks(self: Plan, clock_hz: u32) u64 {
        return @max(1, @as(u64, self.frames) * clock_hz / self.sample_rate);
    }
};

pub const Render = struct {
    frames: u32,
    underrun: bool,
};

/// Pulls one fixed-duration period from full-scale Q1.31 cached PCM and writes the
/// exact uncached AIC DMA layout. Gain is deliberately applied here rather than
/// by a codec so queued PCM does not delay a volume change.
pub fn renderPeriod(
    reservoir: *pcm_reservoir.Ring,
    output: []u8,
    plan: Plan,
    gain_q24: u32,
) Error!Render {
    return render(false, reservoir, output, plan, gain_q24, null);
}

/// Precision reduction is an output decision, after canonical PCM buffering.
/// Separate specializations keep the exact integer path free of PRNG work.
pub fn renderPeriodDithered(
    reservoir: *pcm_reservoir.Ring,
    output: []u8,
    plan: Plan,
    gain_q24: u32,
    quantizer: *pcm.Sample.Quantizer,
) Error!Render {
    if (plan.format != .signed_24_in_u32) return error.InvalidDitherFormat;
    return render(true, reservoir, output, plan, gain_q24, quantizer);
}

fn render(
    comptime dither: bool,
    reservoir: *pcm_reservoir.Ring,
    output: []u8,
    plan: Plan,
    gain_q24: u32,
    quantizer: ?*pcm.Sample.Quantizer,
) Error!Render {
    if (gain_q24 > unity_gain_q24) return error.InvalidGain;
    if (output.len != plan.bytes or @intFromPtr(output.ptr) & 3 != 0) {
        return error.InvalidOutputBuffer;
    }

    const words: [*]u32 = @ptrCast(@alignCast(output.ptr));
    var rendered: u32 = 0;
    while (rendered < plan.frames) {
        const span = reservoir.readable(plan.frames - rendered);
        if (span.len == 0) {
            // Samples overwrite complete DMA words. Silence only the unfilled
            // tail, avoiding a redundant write pass over uncached PCM output.
            @memset(output[@as(usize, rendered) * plan.format.bytesPerFrame() ..], 0);
            return .{ .frames = rendered, .underrun = true };
        }
        for (span, rendered..) |frame, at| packFrame(dither, words, @intCast(at), frame, plan.format, gain_q24, quantizer);
        reservoir.consume(span.len);
        rendered += @intCast(span.len);
    }
    return .{ .frames = rendered, .underrun = false };
}

test "batched output matches sample-at-a-time bytes and dither through wraps and short reads" {
    const capacity = 2053;
    var source: [capacity]pcm_reservoir.StereoFrame = undefined;
    for (&source, 0..) |*frame, i| frame.* = .{
        .left = @bitCast(@as(u32, @truncate(i *% 982451653))),
        .right = @bitCast(@as(u32, @truncate(i *% 32452843))),
    };
    var actual: [1920 * 8]u8 align(4) = undefined;
    var expected: [1920 * 8]u8 align(4) = undefined;
    inline for ([_]pcm.OutputFormat{ .signed_16_packed, .signed_24_in_u32 }) |format| {
        const plan = try Plan.init(192000, format);
        for ([_]usize{ 0, 1, 13, 1900, capacity }) |available_frames| for ([_]usize{ 0, 1, 134, capacity - 1 }) |start| for ([_]u32{ 0, unity_gain_q24 / 2, unity_gain_q24 }) |gain| {
            inline for (.{ false, true }) |dither| {
                if (comptime dither and format == .signed_16_packed) continue;
                var ring = try pcm_reservoir.Ring.initFilled(&source, available_frames);
                ring.consumer_index = start;
                ring.producer_index = (start + available_frames) % capacity;
                ring.read_sequence.store(0xfffffff0, .monotonic);
                ring.write_sequence.store(0xfffffff0 +% @as(u32, @intCast(available_frames)), .monotonic);
                var reference = try pcm_reservoir.Ring.initFilled(&source, available_frames);
                reference.consumer_index = ring.consumer_index;
                reference.producer_index = ring.producer_index;
                reference.read_sequence.store(0xfffffff0, .monotonic);
                reference.write_sequence.store(ring.write_sequence.load(.monotonic), .monotonic);
                var quantizer = pcm.Sample.Quantizer{};
                var reference_quantizer = pcm.Sample.Quantizer{};
                @memset(&expected, 0);
                const expected_words: [*]u32 = @ptrCast(&expected);
                var count: u32 = 0;
                while (count < plan.frames) : (count += 1) {
                    const frame = reference.pop() orelse break;
                    packFrame(dither, expected_words, count, frame, format, gain, if (dither) &reference_quantizer else null);
                }
                @memset(&actual, 0xa5);
                const got = if (dither) try renderPeriodDithered(&ring, actual[0..plan.bytes], plan, gain, &quantizer) else try renderPeriod(&ring, actual[0..plan.bytes], plan, gain);
                try std.testing.expectEqual(count, got.frames);
                try std.testing.expectEqual(count < plan.frames, got.underrun);
                try std.testing.expectEqualSlices(u8, expected[0..plan.bytes], actual[0..plan.bytes]);
                try std.testing.expectEqual(reference_quantizer.random, quantizer.random);
                try std.testing.expectEqual(reference.consumer_index, ring.consumer_index);
                try std.testing.expectEqual(reference.available(), ring.available());
            }
        };
    }
}

fn packFrame(
    comptime dither: bool,
    output: [*]u32,
    frame_index: u32,
    frame: pcm_reservoir.StereoFrame,
    format: pcm.OutputFormat,
    gain_q24: u32,
    quantizer: ?*pcm.Sample.Quantizer,
) void {
    switch (format) {
        .signed_16_packed => {
            const left_16: i16 = @intCast(quantizeWithGain(
                frame.left,
                gain_q24,
                16,
                -32_768,
                32_767,
            ));
            const right_16: i16 = @intCast(quantizeWithGain(
                frame.right,
                gain_q24,
                16,
                -32_768,
                32_767,
            ));
            output[frame_index] = @as(u16, @bitCast(left_16)) |
                @as(u32, @as(u16, @bitCast(right_16))) << 16;
        },
        .signed_24_in_u32 => {
            const target = frame_index * 2;
            const left_24 = if (dither) quantizer.?.to24(scaleSample(frame.left, gain_q24), true) else quantizeWithGain(
                frame.left,
                gain_q24,
                8,
                -8_388_608,
                8_388_607,
            );
            const right_24 = if (dither) quantizer.?.to24(scaleSample(frame.right, gain_q24), true) else quantizeWithGain(
                frame.right,
                gain_q24,
                8,
                -8_388_608,
                8_388_607,
            );
            output[target] = @as(u32, @bitCast(left_24)) & 0x00ff_ffff;
            output[target + 1] = @as(u32, @bitCast(right_24)) & 0x00ff_ffff;
        },
    }
}

fn quantizeWithGain(
    sample: i32,
    gain_q24: u32,
    comptime output_shift: u6,
    minimum: i32,
    maximum: i32,
) i32 {
    const product = @as(i64, sample) * gain_q24;
    const magnitude: u64 = @intCast(if (product < 0) -product else product);
    const total_shift = 24 + output_shift;
    const rounded: i64 = @intCast(
        (magnitude + (@as(u64, 1) << (total_shift - 1))) >> total_shift,
    );
    const signed = if (product < 0) -rounded else rounded;
    return @intCast(@max(@min(signed, maximum), minimum));
}

fn scaleSample(sample: i32, gain_q24: u32) i32 {
    if (gain_q24 == unity_gain_q24) return sample;
    const product = @as(i64, sample) * gain_q24;
    const magnitude: u64 = @intCast(if (product < 0) -product else product);
    const rounded: i64 = @intCast((magnitude + (1 << 23)) >> 24);
    return @intCast(if (product < 0) -rounded else rounded);
}

test "twenty millisecond periods are integral at every supported rate" {
    const expected = [_]struct { rate: u32, frames: u32 }{
        .{ .rate = 44_100, .frames = 882 },
        .{ .rate = 48_000, .frames = 960 },
        .{ .rate = 88_200, .frames = 1_764 },
        .{ .rate = 96_000, .frames = 1_920 },
        .{ .rate = 176_400, .frames = 3_528 },
        .{ .rate = 192_000, .frames = 3_840 },
    };
    for (expected) |item| {
        const plan = try Plan.initWithPeriod(item.rate, .signed_24_in_u32, 20_000);
        try std.testing.expectEqual(item.frames, plan.frames);
        try std.testing.expectEqual(item.frames * 8, plan.bytes);
    }
}

test "ten millisecond periods are integral at every supported rate" {
    const expected = [_]struct { rate: u32, frames: u32 }{
        .{ .rate = 44_100, .frames = 441 },
        .{ .rate = 48_000, .frames = 480 },
        .{ .rate = 88_200, .frames = 882 },
        .{ .rate = 96_000, .frames = 960 },
        .{ .rate = 176_400, .frames = 1_764 },
        .{ .rate = 192_000, .frames = 1_920 },
    };
    for (expected) |item| {
        const plan = try Plan.initWithPeriod(item.rate, .signed_24_in_u32, 10_000);
        try std.testing.expectEqual(item.frames, plan.frames);
        try std.testing.expectEqual(item.frames * 8, plan.bytes);
    }
}

test "plan rejects zero rate and fractional frame periods" {
    try std.testing.expectError(error.InvalidSampleRate, Plan.initWithPeriod(
        0,
        .signed_24_in_u32,
        10_000,
    ));
    try std.testing.expectError(error.NonIntegralPeriod, Plan.initWithPeriod(
        44_100,
        .signed_24_in_u32,
        1_000,
    ));
}

test "unity output preserves exact PCM and a later period sees new gain" {
    const plan = try Plan.initWithPeriod(1_000, .signed_24_in_u32, 20_000);
    var source: [40]pcm_reservoir.StereoFrame = undefined;
    for (&source, 0..) |*frame, index| frame.* = .{
        .left = @as(i32, @intCast(1_000 + index)) << 8,
        .right = -2_000 << 8,
    };

    var ring = try pcm_reservoir.Ring.initFilled(&source, source.len);
    var first: [20 * 8]u8 align(4) = undefined;
    var second: [20 * 8]u8 align(4) = undefined;

    const first_result = try renderPeriod(&ring, &first, plan, unity_gain_q24);
    try std.testing.expect(!first_result.underrun);
    const first_words: *const [40]u32 = @ptrCast(&first);
    try std.testing.expectEqual(@as(u32, 1_000), first_words[0]);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -2_000))) & 0x00ff_ffff, first_words[1]);

    const second_result = try renderPeriod(&ring, &second, plan, unity_gain_q24 / 2);
    try std.testing.expect(!second_result.underrun);
    const second_words: *const [40]u32 = @ptrCast(&second);
    try std.testing.expectEqual(@as(u32, 510), second_words[0]);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -1_000))) & 0x00ff_ffff, second_words[1]);
}

test "underrun consumes available frames and silences the remainder" {
    const plan = try Plan.initWithPeriod(1_000, .signed_16_packed, 20_000);
    var source = [_]pcm_reservoir.StereoFrame{
        .{ .left = 100 << 16, .right = -100 << 16 },
        .{ .left = 200 << 16, .right = -200 << 16 },
    };

    var ring = try pcm_reservoir.Ring.initFilled(&source, source.len);
    var output: [20 * 4]u8 align(4) = undefined;
    const result = try renderPeriod(&ring, &output, plan, unity_gain_q24);
    try std.testing.expect(result.underrun);
    try std.testing.expectEqual(@as(u32, 2), result.frames);
    const words: *const [20]u32 = @ptrCast(&output);
    try std.testing.expect(words[0] != 0);
    for (words[2..]) |word| try std.testing.expectEqual(@as(u32, 0), word);
}

test "Q1.31 boundaries quantize and saturate exactly" {
    const source = [_]pcm_reservoir.StereoFrame{
        .{ .left = std.math.minInt(i32), .right = std.math.maxInt(i32) },
        .{ .left = -128, .right = 128 },
    };

    var storage_24 = source;
    var ring_24 = try pcm_reservoir.Ring.initFilled(&storage_24, storage_24.len);
    const plan_24 = try Plan.initWithPeriod(200, .signed_24_in_u32, 10_000);
    var output_24: [16]u8 align(4) = undefined;
    _ = try renderPeriod(&ring_24, &output_24, plan_24, unity_gain_q24);
    const words_24: *const [4]u32 = @ptrCast(&output_24);
    try std.testing.expectEqual(@as(u32, 0x0080_0000), words_24[0]);
    try std.testing.expectEqual(@as(u32, 0x007f_ffff), words_24[1]);
    try std.testing.expectEqual(@as(u32, 0x00ff_ffff), words_24[2]);
    try std.testing.expectEqual(@as(u32, 1), words_24[3]);

    var storage_16 = source;
    var ring_16 = try pcm_reservoir.Ring.initFilled(&storage_16, storage_16.len);
    const plan_16 = try Plan.initWithPeriod(200, .signed_16_packed, 10_000);
    var output_16: [8]u8 align(4) = undefined;
    _ = try renderPeriod(&ring_16, &output_16, plan_16, unity_gain_q24);
    const words_16: *const [2]u32 = @ptrCast(&output_16);
    try std.testing.expectEqual(@as(u32, 0x7fff_8000), words_16[0]);
    try std.testing.expectEqual(@as(u32, 0), words_16[1]);
}

test "gain and output width use one final rounding step" {
    var source = [1]pcm_reservoir.StereoFrame{.{ .left = 128, .right = -128 }};
    var ring = try pcm_reservoir.Ring.initFilled(&source, 1);
    const plan = try Plan.initWithPeriod(100, .signed_24_in_u32, 10_000);
    var output: [8]u8 align(4) = undefined;
    _ = try renderPeriod(&ring, &output, plan, unity_gain_q24 - 1);
    const words: *const [2]u32 = @ptrCast(&output);
    try std.testing.expectEqual(@as(u32, 0), words[0]);
    try std.testing.expectEqual(@as(u32, 0), words[1]);
}

test "zero gain silences a complete period and invalid buffers are rejected" {
    var source: [2]pcm_reservoir.StereoFrame = @splat(.{
        .left = std.math.maxInt(i32),
        .right = std.math.minInt(i32),
    });
    const plan = try Plan.initWithPeriod(200, .signed_24_in_u32, 10_000);
    var output: [17]u8 align(4) = @splat(0xaa);

    var ring = try pcm_reservoir.Ring.initFilled(&source, source.len);
    _ = try renderPeriod(&ring, output[0..16], plan, 0);
    for (output[0..16]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    ring = try pcm_reservoir.Ring.initFilled(&source, source.len);
    try std.testing.expectError(
        error.InvalidOutputBuffer,
        renderPeriod(&ring, output[1..17], plan, unity_gain_q24),
    );
    try std.testing.expectError(
        error.InvalidGain,
        renderPeriod(&ring, output[0..16], plan, unity_gain_q24 + 1),
    );
}

test "output period admission rejects zero and unrepresentable DMA sizes" {
    try std.testing.expectError(error.InvalidPeriod, Plan.initWithPeriod(48_000, .signed_24_in_u32, 0));
    try std.testing.expectError(error.InvalidPeriod, Plan.initWithPeriod(1_000_000, .signed_24_in_u32, std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 480), (try Plan.init(48_000, .signed_24_in_u32)).frames);
}

test "native low sample rates keep exact timing with the shortest integral period" {
    for ([_]struct { rate: u32, frames: u32 }{
        .{ .rate = 8000, .frames = 80 },
        .{ .rate = 11025, .frames = 441 },
        .{ .rate = 12000, .frames = 120 },
        .{ .rate = 16000, .frames = 160 },
        .{ .rate = 22050, .frames = 441 },
        .{ .rate = 24000, .frames = 240 },
        .{ .rate = 32000, .frames = 320 },
    }) |case| {
        const plan = try Plan.init(case.rate, .signed_24_in_u32);
        try std.testing.expectEqual(case.frames, plan.frames);
        // An exact number of periods must account for every frame in a second.
        try std.testing.expectEqual(@as(u32, 0), case.rate % plan.frames);
    }
}

test "captured late two-period poll overruns while one-period watchdog keeps ownership" {
    const playback = @import("playback.zig");

    const plan = try Plan.init(48_000, .signed_24_in_u32);
    const period_ticks: u32 = 60_000;
    var state = try playback.State.init(.{ .buffer_count = 3, .descriptor_count = 120, .total_chunks = 240 });
    for (0..27) |_| {
        const step = try state.advance(state.nextDescriptor());
        if (step.refill) |refill| try state.completeRefill(refill);
    }
    // Native FLAC capture: frontier 27 -> 30, maximum poll gap 123128
    // ticks. A poll phase near the end of a period exposes the third crossing.
    const phase: u32 = period_ticks - 10;
    const late_gap: u32 = 123_128;
    const missed = (phase + late_gap) / period_ticks;
    try std.testing.expectEqual(@as(u32, 3), missed);
    try std.testing.expectError(error.DescriptorOverrun, state.completionsTo(@intCast(27 + missed)));
    const wake_latency = late_gap - 2 * period_ticks;
    const bounded = (phase + plan.refillWatchdogTicks(6_000_000) + wake_latency) / period_ticks;
    try std.testing.expectEqual(@as(u32, 2), bounded);
    try std.testing.expectEqual(@as(u8, 2), try state.completionsTo(@intCast(27 + bounded)));
}

test "watchdog phase and wake latency stay inside the three-buffer margin across ring wrap" {
    const playback = @import("playback.zig");

    const rates = [_]u32{ 8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000, 176_400, 192_000 };
    for (rates) |rate| {
        const plan = try Plan.init(rate, .signed_24_in_u32);
        const period_ticks = @as(u64, plan.frames) * 6_000_000 / rate;
        for ([_]u32{ 0, 27, 119, 239 }) |completed| {
            var baseline = try playback.State.init(.{ .buffer_count = 3, .descriptor_count = 120, .total_chunks = 480 });
            for (0..completed) |_| {
                const step = try baseline.advance(baseline.nextDescriptor());
                if (step.refill) |refill| try baseline.completeRefill(refill);
            }
            for (0..64) |phase_index| {
                for (0..16) |latency_index| {
                    const phase = phase_index * period_ticks / 64;
                    const latency = latency_index * period_ticks / 160; // <10% of one period.
                    const crossings = (phase + plan.refillWatchdogTicks(6_000_000) + latency) / period_ticks;
                    const observed: u7 = @intCast((completed + crossings) % 120);
                    var state = baseline;
                    const count = try state.completionsTo(observed);
                    try std.testing.expectEqual(crossings, count);
                    for (0..count) |_| {
                        const step = try state.advance(state.nextDescriptor());
                        if (step.refill) |refill| try state.completeRefill(refill);
                    }
                    try std.testing.expectEqual(completed + crossings, state.chunks_completed);
                }
            }
        }
    }
}

test "dithered DMA output retains its golden sequence across period boundaries" {
    const plan = try Plan.init(1600, .signed_24_in_u32);
    const source: [16]pcm_reservoir.StereoFrame = @splat(.{ .left = 0, .right = 0 });
    var first_storage: [16]pcm_reservoir.StereoFrame = undefined;
    var first = try pcm_reservoir.Ring.init(&first_storage);
    _ = first.write(&source);
    var whole: [128]u8 align(4) = undefined;
    var quantizer = pcm.Sample.Quantizer{};
    const result = try renderPeriodDithered(&first, &whole, plan, unity_gain_q24, &quantizer);
    try std.testing.expectEqual(@as(u32, 16), result.frames);
    try std.testing.expect(!result.underrun);
    // Independently generated first 32 TPDF outputs for the documented seed.
    const expected = [_]i32{ 0, 0, 0, 0, 0, 0, -1, 0, 0, 1, -1, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, -1, 0, -1, 0 };
    for (expected, 0..) |sample, index| {
        try std.testing.expectEqual(@as(u32, @bitCast(sample)) & 0xffffff, std.mem.readInt(u32, whole[index * 4 ..][0..4], .little));
    }
    var split_storage: [16]pcm_reservoir.StereoFrame = undefined;
    var split = try pcm_reservoir.Ring.init(&split_storage);
    _ = split.write(&source);
    var pieces: [128]u8 align(4) = undefined;
    var split_quantizer = pcm.Sample.Quantizer{};
    const half_plan = try Plan.init(800, .signed_24_in_u32);
    _ = try renderPeriodDithered(&split, pieces[0..64], half_plan, unity_gain_q24, &split_quantizer);
    _ = try renderPeriodDithered(&split, pieces[64..], half_plan, unity_gain_q24, &split_quantizer);
    try std.testing.expectEqualSlices(u8, &whole, &pieces);
    try std.testing.expectEqual(quantizer.random, split_quantizer.random);
}

test "dither never changes drained padding or consumes rejected 16-bit output" {
    var frames: [1]pcm_reservoir.StereoFrame = undefined;
    var ring = try pcm_reservoir.Ring.init(&frames);
    var output: [128]u8 align(4) = undefined;
    var quantizer = pcm.Sample.Quantizer{};
    const initial_seed = quantizer.random;
    const plan = try Plan.init(1600, .signed_24_in_u32);
    const result = try renderPeriodDithered(&ring, &output, plan, unity_gain_q24, &quantizer);
    try std.testing.expect(result.underrun and result.frames == 0);
    try std.testing.expectEqual(initial_seed, quantizer.random);
    for (output) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    _ = ring.write(&.{.{ .left = 1, .right = -1 }});
    const packed_plan = try Plan.init(1600, .signed_16_packed);
    @memset(&output, 0xa5);
    try std.testing.expectError(error.InvalidDitherFormat, renderPeriodDithered(&ring, output[0..64], packed_plan, unity_gain_q24, &quantizer));
    try std.testing.expectEqual(@as(usize, 1), ring.available());
    try std.testing.expectEqual(initial_seed, quantizer.random);
    for (output) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}
