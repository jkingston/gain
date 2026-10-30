const std = @import("std");
const f20 = @import("f20");
const fat32 = f20.storage.fat32;
const flac_pcm = f20.flac_pcm;
const pcm = f20.pcm;
const playback = f20.playback;

const encoded = @embedFile("fixtures/flac-24.flac");
const reference = @embedFile("fixtures/flac-24.s32le");
const partition_lba = 2_048;
const reserved_sectors = 32;
const fat_sectors = 600;
const data_lba = partition_lba + reserved_sectors + fat_sectors;
const first_file_cluster = 3;
const block_frames = 4_096;
const chunk_bytes = block_frames * 8;
const buffer_count = 3;

const MemoryCard = struct {
    pub fn readBlocks(self: *MemoryCard, first_lba: u32, output: []u8) !void {
        if (output.len == 0 or output.len % fat32.sector_bytes != 0 or
            @intFromPtr(output.ptr) & 3 != 0)
        {
            return error.InvalidRead;
        }
        var offset: usize = 0;
        while (offset < output.len) : (offset += fat32.sector_bytes) {
            self.readSector(
                first_lba + @as(u32, @intCast(offset / fat32.sector_bytes)),
                output[offset..][0..fat32.sector_bytes],
            );
        }
    }

    fn readSector(_: *MemoryCard, lba: u32, output: *[fat32.sector_bytes]u8) void {
        output.* = @splat(0);
        if (lba == 0) return makeMbr(output);
        if (lba == partition_lba) return makeBootSector(output);
        if (lba == partition_lba + reserved_sectors) return makeFat(output);
        if (lba == data_lba) return makeRootDirectory(output);
        if (lba <= data_lba) return;

        const file_sector = lba - data_lba - 1;
        const start = @as(usize, file_sector) * fat32.sector_bytes;
        if (start >= encoded.len) return;
        const count = @min(fat32.sector_bytes, encoded.len - start);
        @memcpy(output[0..count], encoded[start..][0..count]);
    }
};

const Volume = fat32.Volume(MemoryCard);

const Buffered = f20.storage.BufferedReader(Volume.Reader);

test "FAT32 FLAC feeds exact fixed-size chunks through the production stream" {
    var card = MemoryCard{};
    var sector: [fat32.sector_bytes]u8 = undefined;
    var volume = try Volume.mount(&card, &sector);
    const file = try volume.findRoot("PIPE    FLA".*);
    var file_reader = try volume.reader(file);
    var bounce: [8_195]u8 align(4) = undefined;
    var reader = try Buffered.init(&file_reader, &bounce);
    var compressed: [7_416]u8 = undefined;
    var left: [block_frames]i32 = undefined;
    var right: [block_frames]i32 = undefined;
    var stream = try flac_pcm.Stream(Buffered).init(
        &reader,
        &compressed,
        &left,
        &right,
    );

    try std.testing.expectEqual(@as(u32, 48_000), stream.plan.sample_rate);
    try std.testing.expectEqual(pcm.OutputFormat.signed_24_in_u32, stream.plan.output_format);
    try std.testing.expectEqual(@as(u16, block_frames), stream.plan.block_frames);
    try std.testing.expectEqual(@as(u24, chunk_bytes), stream.plan.chunkBytes());
    const chunk_count = try stream.plan.chunkCount();
    try std.testing.expectEqual(@as(u32, 4), chunk_count);

    var state = try playback.State.init(.{
        .buffer_count = buffer_count,
        .descriptor_count = 8,
        .total_chunks = chunk_count,
    });
    var buffers: [buffer_count][chunk_bytes]u8 align(4) = undefined;
    var fills: u32 = 0;
    for (&buffers) |*buffer| {
        _ = try stream.fill(buffer);
        fills += 1;
    }

    while (!state.finished) {
        const chunk = state.currentChunk().?;
        const slot: usize = @intCast(chunk % buffer_count);
        try verifyChunk(&buffers[slot], chunk);
        const observed: u7 = @intCast((chunk + 1) % 8);
        const transition = try state.advance(observed);
        if (transition.refill) |refill| {
            _ = try stream.fill(&buffers[refill.slot]);
            try state.completeRefill(refill);
            fills += 1;
        }
    }

    try std.testing.expectEqual(chunk_count, fills);
    try std.testing.expectEqual(@as(u64, 0), stream.remaining_frames);
    try std.testing.expectEqual(@as(u64, reference.len / 8), stream.decoder.decoded_samples);
    try std.testing.expectEqual(@as(u32, encoded.len), file_reader.position);
}

test "sequential FLAC decoder rejects workspaces that cannot hold one frame" {
    var card = MemoryCard{};
    var sector: [fat32.sector_bytes]u8 = undefined;
    var volume = try Volume.mount(&card, &sector);
    const file = try volume.findRoot("PIPE    FLA".*);
    var file_reader = try volume.reader(file);
    var bounce: [8_195]u8 align(4) = undefined;
    var reader = try Buffered.init(&file_reader, &bounce);
    var compressed: [7_415]u8 = undefined;
    var left: [block_frames]i32 = undefined;
    var right: [block_frames]i32 = undefined;
    try std.testing.expectError(
        error.CompressedBufferTooSmall,
        flac_pcm.Stream(Buffered).init(&reader, &compressed, &left, &right),
    );
}

test "FAT32 never submits an unaligned bulk transfer after FLAC metadata" {
    var card = MemoryCard{};
    var sector: [fat32.sector_bytes]u8 align(4) = undefined;
    var volume = try Volume.mount(&card, &sector);
    const file = try volume.findRoot("PIPE    FLA".*);
    var reader = try volume.reader(file);
    var prefix: [94]u8 align(4) = undefined;
    try std.testing.expectEqual(prefix.len, try reader.read(&prefix));
    try std.testing.expectEqualSlices(u8, encoded[0..prefix.len], &prefix);

    // Position 94 leaves 418 bytes in the first sector. An aligned output then
    // advances to address +418, which is not valid for the F20's SD DMA. The
    // FAT32 reader must keep using its aligned sector scratch in this case.
    var metadata: [8_192]u8 align(4) = undefined;
    try std.testing.expectEqual(metadata.len, try reader.read(&metadata));
    try std.testing.expectEqualSlices(u8, encoded[94..8_286], &metadata);
}

fn verifyChunk(actual: *const [chunk_bytes]u8, chunk: u32) !void {
    var expected: [chunk_bytes]u8 = @splat(0);
    const first_frame = @as(usize, chunk) * block_frames;
    for (0..block_frames) |offset| {
        const frame = first_frame + offset;
        if (frame * 8 >= reference.len) break;
        for (0..2) |channel| {
            const source = frame * 8 + channel * 4;
            const target = offset * 8 + channel * 4;
            expected[target] = reference[source + 1];
            expected[target + 1] = reference[source + 2];
            expected[target + 2] = reference[source + 3];
        }
    }
    try std.testing.expectEqualSlices(u8, &expected, actual);
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
    const file_sectors = (encoded.len + fat32.sector_bytes - 1) / fat32.sector_bytes;
    for (0..file_sectors) |index| {
        const cluster = first_file_cluster + index;
        const next: u32 = if (index + 1 == file_sectors)
            0x0fff_ffff
        else
            @intCast(cluster + 1);
        write32(sector, cluster * 4, next);
    }
}

fn makeRootDirectory(sector: *[fat32.sector_bytes]u8) void {
    @memcpy(sector[0..11], "PIPE    FLA");
    sector[11] = 0x20;
    write16(sector, 26, first_file_cluster);
    write32(sector, 28, encoded.len);
}

fn signature(sector: *[fat32.sector_bytes]u8) void {
    sector[510] = 0x55;
    sector[511] = 0xaa;
}

fn write16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn write32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}
