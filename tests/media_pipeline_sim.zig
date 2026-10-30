const std = @import("std");
const f20 = @import("f20");
const fat32 = f20.storage.fat32;
const wav = f20.storage.wav;
const pcm = f20.pcm;
const playback = f20.playback;

const partition_lba = 2_048;
const reserved_sectors = 32;
const fat_sectors = 600;
const data_lba = partition_lba + reserved_sectors + fat_sectors;
const maximum_file_bytes = 1_536;
const chunk_bytes = 256;
const buffer_count = 3;

const Source = enum { signed_16, signed_24_packed, signed_24_in_32 };

const MemoryCard = struct {
    image: [maximum_file_bytes]u8 = @splat(0),
    file_bytes: u32,

    fn init(rate: u32, source: Source) MemoryCard {
        var self = MemoryCard{ .file_bytes = 0 };
        self.file_bytes = @intCast(makeWave(&self.image, rate, source));
        return self;
    }

    pub fn readBlocks(self: *MemoryCard, first_lba: u32, output: []u8) !void {
        if (output.len == 0 or output.len % fat32.sector_bytes != 0) return error.InvalidRead;
        var offset: usize = 0;
        while (offset < output.len) : (offset += fat32.sector_bytes) {
            self.readSector(
                first_lba + @as(u32, @intCast(offset / fat32.sector_bytes)),
                output[offset..][0..fat32.sector_bytes],
            );
        }
    }

    fn readSector(self: *MemoryCard, lba: u32, output: *[fat32.sector_bytes]u8) void {
        output.* = @splat(0);
        switch (lba) {
            0 => makeMbr(output),
            partition_lba => makeBootSector(output),
            partition_lba + reserved_sectors => makeFat(output),
            data_lba => makeRootDirectory(output, self.file_bytes),
            data_lba + 1 => self.copyFileSector(output, 0),
            data_lba + 3 => self.copyFileSector(output, 1),
            data_lba + 5 => self.copyFileSector(output, 2),
            else => {},
        }
    }

    fn copyFileSector(self: *MemoryCard, output: *[fat32.sector_bytes]u8, sector: usize) void {
        const start = sector * fat32.sector_bytes;
        if (start >= self.file_bytes) return;
        const count = @min(fat32.sector_bytes, self.file_bytes - start);
        @memcpy(output[0..count], self.image[start..][0..count]);
    }
};

const Volume = fat32.Volume(MemoryCard);

const ChoppyReader = struct {
    inner: *Volume.Reader,
    call: usize = 0,

    pub fn read(self: *ChoppyReader, output: []u8) !usize {
        if (output.len == 0) return 0;
        const limits = [_]usize{ 1, 7, 31, 5, 113, 2, 47 };
        const limit = limits[self.call % limits.len];
        self.call += 1;
        return self.inner.read(output[0..@min(output.len, limit)]);
    }
};

test "fragmented WAV files feed exact DMA frames through the production pipeline" {
    const rates = [_]u32{ 44_100, 48_000, 88_200, 96_000, 176_400, 192_000 };
    const sources = [_]Source{ .signed_16, .signed_24_packed, .signed_24_in_32 };
    for (rates) |rate| for (sources) |source| try runPipeline(rate, source);
}

test "PCM planning rejects media the hardware path cannot preserve" {
    var info = testWaveInfo();
    info.encoding = .ieee_float;
    try std.testing.expectError(error.UnsupportedEncoding, pcm.Plan.fromWave(info));
    info = testWaveInfo();
    info.channels = 1;
    try std.testing.expectError(error.UnsupportedChannels, pcm.Plan.fromWave(info));
    info = testWaveInfo();
    info.bits_per_sample = 32;
    info.valid_bits_per_sample = 32;
    info.block_align = 8;
    try std.testing.expectError(error.UnsupportedSampleFormat, pcm.Plan.fromWave(info));
    info = testWaveInfo();
    info.channel_mask = 4;
    try std.testing.expectError(error.InvalidChannelMask, pcm.Plan.fromWave(info));
}

test "PCM filling reports truncation and rejects partial DMA frames" {
    const ShortReader = struct {
        bytes: []const u8,
        offset: usize = 0,

        pub fn read(self: *@This(), output: []u8) !usize {
            const count = @min(output.len, self.bytes.len - self.offset);
            @memcpy(output[0..count], self.bytes[self.offset..][0..count]);
            self.offset += count;
            return count;
        }
    };
    var source = ShortReader{ .bytes = &[_]u8{ 1, 2, 3 } };
    var stream = try pcm.Stream(ShortReader).init(&source, testWaveInfo());
    var output: [4]u8 = undefined;
    try std.testing.expectError(error.Truncated, stream.fill(&output));

    var complete = ShortReader{ .bytes = &[_]u8{ 1, 2, 3, 4 } };
    var aligned = try pcm.Stream(ShortReader).init(&complete, testWaveInfo());
    var partial: [3]u8 = undefined;
    try std.testing.expectError(error.InvalidOutputBuffer, aligned.fill(&partial));
}

fn runPipeline(rate: u32, source: Source) !void {
    var card = MemoryCard.init(rate, source);
    var scratch: [fat32.sector_bytes]u8 = undefined;
    var volume = try Volume.mount(&card, &scratch);
    const file = try volume.findRoot("PIPE    WAV".*);
    var file_reader = try volume.reader(file);
    var reader = ChoppyReader{ .inner = &file_reader };
    const info = try wav.parse(&reader);
    var stream = try pcm.Stream(ChoppyReader).init(&reader, info);

    try std.testing.expectEqual(rate, stream.plan.sample_rate);
    try std.testing.expect(f20.audio.sampleRate(rate) != null);
    try std.testing.expectEqual(
        if (source == .signed_16) pcm.OutputFormat.signed_16_packed else .signed_24_in_u32,
        stream.plan.output_format,
    );
    _ = f20.audio.sampleFormat(stream.plan.output_format);

    const total_chunks = try stream.plan.chunkCount(chunk_bytes);
    try std.testing.expectEqual(@as(u32, 5), total_chunks);
    var state = try playback.State.init(.{
        .buffer_count = buffer_count,
        .descriptor_count = @intCast(total_chunks),
        .total_chunks = total_chunks,
    });
    var buffers: [buffer_count][chunk_bytes]u8 = undefined;
    var fills: u32 = 0;
    for (&buffers) |*buffer| {
        _ = try stream.fill(buffer);
        fills += 1;
    }

    while (!state.finished) {
        const chunk = state.currentChunk().?;
        const slot: usize = @intCast(chunk % buffer_count);
        try verifyChunk(&buffers[slot], chunk, source);
        const observed: u7 = @intCast((chunk + 1) % total_chunks);
        const transition = try state.advance(observed);
        if (transition.refill) |refill| {
            _ = try stream.fill(&buffers[refill.slot]);
            try state.completeRefill(refill);
            fills += 1;
        }
    }
    try std.testing.expectEqual(total_chunks, fills);
    try std.testing.expectEqual(@as(u32, 0), stream.remaining_frames);
    var extra: [chunk_bytes]u8 = @splat(0xaa);
    const end = try stream.fill(&extra);
    try std.testing.expect(end.end);
    try std.testing.expectEqual(@as(u32, 0), end.bytes);
    try std.testing.expectEqualSlices(u8, &@as([chunk_bytes]u8, @splat(0)), &extra);
}

fn testWaveInfo() wav.Info {
    return .{
        .encoding = .pcm_integer,
        .channels = 2,
        .sample_rate = 48_000,
        .byte_rate = 192_000,
        .block_align = 4,
        .bits_per_sample = 16,
        .valid_bits_per_sample = 16,
        .channel_mask = 3,
        .data_offset = 44,
        .data_bytes = 4,
    };
}

fn verifyChunk(actual: *const [chunk_bytes]u8, chunk: u32, source: Source) !void {
    var expected: [chunk_bytes]u8 = @splat(0);
    const output_frame_bytes: usize = if (source == .signed_16) 4 else 8;
    const total_frames = frameCount(source);
    const first_frame = @as(usize, chunk) * (chunk_bytes / output_frame_bytes);
    for (0..chunk_bytes / output_frame_bytes) |offset| {
        const frame = first_frame + offset;
        if (frame >= total_frames) break;
        writeExpectedFrame(expected[offset * output_frame_bytes ..], frame, source);
    }
    try std.testing.expectEqualSlices(u8, &expected, actual);
}

fn makeWave(output: *[maximum_file_bytes]u8, rate: u32, source: Source) usize {
    const extensible = source == .signed_24_in_32;
    const header_bytes: usize = if (extensible) 68 else 44;
    const source_frame_bytes: usize = switch (source) {
        .signed_16 => 4,
        .signed_24_packed => 6,
        .signed_24_in_32 => 8,
    };
    const frames = frameCount(source);
    const data_bytes = frames * source_frame_bytes;
    const file_bytes = header_bytes + data_bytes;
    @memcpy(output[0..4], "RIFF");
    write32(output, 4, @intCast(file_bytes - 8));
    @memcpy(output[8..12], "WAVE");
    @memcpy(output[12..16], "fmt ");
    write32(output, 16, if (extensible) 40 else 16);
    write16(output, 20, if (extensible) 0xfffe else 1);
    write16(output, 22, 2);
    write32(output, 24, rate);
    write32(output, 28, @intCast(rate * source_frame_bytes));
    write16(output, 32, @intCast(source_frame_bytes));
    write16(output, 34, switch (source) {
        .signed_16 => 16,
        .signed_24_packed => 24,
        .signed_24_in_32 => 32,
    });
    if (extensible) {
        write16(output, 36, 22);
        write16(output, 38, 24);
        write32(output, 40, 3);
        output[44] = 1;
        const guid_tail = [_]u8{ 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 };
        @memcpy(output[48..60], &guid_tail);
    }
    const data_offset: usize = if (extensible) 60 else 36;
    @memcpy(output[data_offset..][0..4], "data");
    write32(output, data_offset + 4, @intCast(data_bytes));
    var offset = header_bytes;
    for (0..frames) |frame| offset += writeSourceFrame(output[offset..], frame, source);
    return file_bytes;
}

fn frameCount(source: Source) usize {
    const output_frame_bytes: usize = if (source == .signed_16) 4 else 8;
    return chunk_bytes * 4 / output_frame_bytes + 5;
}

fn writeSourceFrame(output: []u8, frame: usize, source: Source) usize {
    const left = sample24(frame, false);
    const right = sample24(frame, true);
    switch (source) {
        .signed_16 => {
            write16(output, 0, @truncate(left));
            write16(output, 2, @truncate(right));
            return 4;
        },
        .signed_24_packed => {
            write24(output, 0, left);
            write24(output, 3, right);
            return 6;
        },
        .signed_24_in_32 => {
            write32(output, 0, left << 8);
            write32(output, 4, right << 8);
            return 8;
        },
    }
}

fn writeExpectedFrame(output: []u8, frame: usize, source: Source) void {
    const left = sample24(frame, false);
    const right = sample24(frame, true);
    if (source == .signed_16) {
        write16(output, 0, @truncate(left));
        write16(output, 2, @truncate(right));
    } else {
        write32(output, 0, left);
        write32(output, 4, right);
    }
}

fn sample24(frame: usize, right: bool) u32 {
    const value: u32 = @truncate(@as(u64, frame) * 0x01_0203 + 0x12_3456);
    const low24 = value & 0x00ff_ffff;
    return if (right) low24 ^ 0x00ff_ffff else low24;
}

fn makeMbr(sector: *[fat32.sector_bytes]u8) void {
    sector[446 + 4] = 0x0c;
    write32(sector, 446 + 8, partition_lba);
    write32(sector, 446 + 12, 70_000);
    signature(sector);
}

fn makeBootSector(sector: *[fat32.sector_bytes]u8) void {
    sector[0] = 0xeb;
    sector[2] = 0x90;
    write16(sector, 11, fat32.sector_bytes);
    sector[13] = 1;
    write16(sector, 14, reserved_sectors);
    sector[16] = 1;
    write32(sector, 32, 70_000);
    write32(sector, 36, fat_sectors);
    write32(sector, 44, 2);
    signature(sector);
}

fn makeFat(sector: *[fat32.sector_bytes]u8) void {
    write32(sector, 0, 0x0fff_fff8);
    write32(sector, 4, 0xffff_ffff);
    write32(sector, 8, 0x0fff_ffff);
    write32(sector, 12, 5);
    write32(sector, 20, 7);
    write32(sector, 28, 0x0fff_ffff);
}

fn makeRootDirectory(sector: *[fat32.sector_bytes]u8, file_bytes: u32) void {
    @memcpy(sector[0..11], "PIPE    WAV");
    sector[11] = 0x20;
    write16(sector, 26, 3);
    write32(sector, 28, file_bytes);
}

fn signature(sector: *[fat32.sector_bytes]u8) void {
    sector[510] = 0x55;
    sector[511] = 0xaa;
}

fn write16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn write24(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
}

fn write32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}
