const std = @import("std");
const flac = @import("flac");
const playback = @import("playback");

const source = @embedFile("fixtures/flac-device-192.flac");
const block_frames = 16_384;
const buffer_count = 3;
const descriptor_count = 120;
const timer_ticks_per_second = 6_000_000;
const sample_rate = 192_000;

// Captured on the F20 while decoding the same 24-bit/192 kHz workload. The
// first three frames are prefilled; subsequent frames run between DMA events.
const measured_decode_ticks = [_]u32{
    301_275, 318_720, 328_750, 347_468, 287_163, 304_310,
    281_691, 325_716, 316_363, 334_791, 316_264, 327_629,
    258_740, 278_750, 300_277, 337_250, 293_256, 316_355,
    282_489, 297_627, 272_754, 339_364, 316_850, 104_756,
};

// Captured from the complete production fill path. ReleaseSmall crossed the
// fourth block boundary on-device and produced UnexpectedDescriptor. The
// optimized trace includes FAT32, physical microSD DMA, bounce copying, native
// decoding and final PCM packing after the production fixes.
const release_small_fill_ticks = [_]u32{
    469_781, 485_585, 495_953, 516_249, 453_341, 470_903,
    446_901, 492_854, 483_423, 502_147, 483_612, 495_206,
    425_909, 444_072, 465_964, 505_161, 462_718, 484_392,
    447_870, 464_278, 441_055, 507_242, 484_124, 209_166,
};

const optimized_sd_fill_ticks = [_]u32{
    399_811, 413_115, 422_188, 446_191, 385_168, 396_476,
    373_536, 417_378, 411_103, 431_279, 412_583, 424_185,
    353_809, 376_326, 388_272, 427_798, 392_047, 418_248,
    376_856, 386_333, 366_970, 435_161, 416_189, 173_801,
};

const Decoder = struct {
    info: flac.StreamInfo,
    input_offset: usize,
    decoded_frames: u32 = 0,
    left: [block_frames]i32 = undefined,
    right: [block_frames]i32 = undefined,
    slots: [buffer_count][block_frames * 2]i32 = undefined,

    fn fill(self: *Decoder, slot: usize) !void {
        @memset(&self.slots[slot], 0);
        const frame = try flac.decodeFrame(
            source[self.input_offset..],
            self.info,
            &self.left,
            &self.right,
        );
        for (0..frame.block_size) |index| {
            self.slots[slot][index * 2] = self.left[index];
            self.slots[slot][index * 2 + 1] = self.right[index];
        }
        self.input_offset += frame.bytes_consumed;
        self.decoded_frames += frame.block_size;
    }
};

test "exact F20 24-bit 192 kHz triple-buffer workload" {
    const info = try flac.parseStreamInfo(source);
    try std.testing.expectEqual(@as(u20, sample_rate), info.sample_rate);
    try std.testing.expectEqual(@as(u16, block_frames), info.minimum_block_size);
    try std.testing.expectEqual(@as(u16, block_frames), info.maximum_block_size);
    const chunk_count: u32 = @intCast((info.total_samples + block_frames - 1) / block_frames);

    var state = try playback.State.init(.{
        .buffer_count = buffer_count,
        .descriptor_count = descriptor_count,
        .total_chunks = chunk_count,
    });
    var decoder = Decoder{ .info = info, .input_offset = info.first_frame_offset };
    for (0..buffer_count) |slot| try decoder.fill(slot);

    var completed: u32 = 0;
    while (!state.finished) {
        const observed: u7 = @intCast((completed + 1) % descriptor_count);
        const transition = try state.advance(observed);
        completed += 1;
        if (transition.refill) |refill| {
            try decoder.fill(refill.slot);
            try state.completeRefill(refill);
        }
    }

    try std.testing.expectEqual(chunk_count, completed);
    try std.testing.expectEqual(@as(u32, @intCast(info.total_samples)), decoder.decoded_frames);
    try std.testing.expectEqual(source.len, decoder.input_offset);
}

test "simulation catches undersized FLAC work buffers" {
    const info = try flac.parseStreamInfo(source);
    var left: [4096]i32 = undefined;
    var right: [4096]i32 = undefined;
    try std.testing.expectError(
        error.OutputTooSmall,
        flac.decodeFrame(source[info.first_frame_offset..], info, &left, &right),
    );
}

fn descriptorEventsRemainObservable(decode_ticks: []const u32) bool {
    const chunk_ticks = block_frames * timer_ticks_per_second / sample_rate;
    for (decode_ticks[buffer_count..]) |ticks| {
        if (ticks >= chunk_ticks) return false;
    }
    return true;
}

test "measured decode trace keeps every DMA event observable" {
    try std.testing.expect(descriptorEventsRemainObservable(&measured_decode_ticks));
    const chunk_ticks = block_frames * timer_ticks_per_second / sample_rate;
    const worst = std.mem.max(u32, &measured_decode_ticks);
    try std.testing.expectEqual(@as(u32, 512_000), chunk_ticks);
    try std.testing.expectEqual(@as(u32, 347_468), worst);
    try std.testing.expect(worst * 100 / chunk_ticks <= 68);
}

test "simulation rejects a missed FLAC refill deadline" {
    var delayed = measured_decode_ticks;
    delayed[7] = block_frames * timer_ticks_per_second / sample_rate;
    try std.testing.expect(!descriptorEventsRemainObservable(&delayed));
}

test "production optimization fixes the captured descriptor miss" {
    try std.testing.expect(!descriptorEventsRemainObservable(&release_small_fill_ticks));
    try std.testing.expect(descriptorEventsRemainObservable(&optimized_sd_fill_ticks));
    const chunk_ticks = block_frames * timer_ticks_per_second / sample_rate;
    const worst = std.mem.max(u32, &optimized_sd_fill_ticks);
    try std.testing.expectEqual(@as(u32, 446_191), worst);
    try std.testing.expect(worst * 1_000 / chunk_ticks <= 872);
}
