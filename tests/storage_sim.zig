const std = @import("std");
const fat32 = @import("fat32");
const wav = @import("wav");

const partition_lba = 2_048;
const reserved_sectors = 32;
const fat_sectors = 600;
const data_lba = partition_lba + reserved_sectors + fat_sectors;
const file_bytes = 600;

const MemoryCard = struct {
    image: [file_bytes]u8,

    fn init() MemoryCard {
        var self = MemoryCard{ .image = @splat(0) };
        makeWave(&self.image);
        return self;
    }

    pub fn readBlocks(self: *MemoryCard, first_lba: u32, output: []u8) !void {
        if (output.len == 0 or output.len % fat32.sector_bytes != 0) return error.InvalidRead;
        var offset: usize = 0;
        while (offset < output.len) : (offset += fat32.sector_bytes) {
            self.readSector(first_lba + @as(u32, @intCast(offset / fat32.sector_bytes)), output[offset..][0..fat32.sector_bytes]);
        }
    }

    fn readSector(self: *MemoryCard, lba: u32, output: *[fat32.sector_bytes]u8) void {
        output.* = @splat(0);
        switch (lba) {
            0 => makeMbr(output),
            partition_lba => makeBootSector(output),
            partition_lba + reserved_sectors => makeFat(output),
            data_lba => makeRootDirectory(output),
            data_lba + 1 => @memcpy(output, self.image[0..fat32.sector_bytes]),
            data_lba + 3 => @memcpy(output[0 .. file_bytes - fat32.sector_bytes], self.image[fat32.sector_bytes..]),
            data_lba + 4 => makeAlbumDirectory(output),
            else => {},
        }
    }
};

test "production FAT32 reader follows a fragmented file into the WAV parser" {
    var card = MemoryCard.init();
    var scratch: [fat32.sector_bytes]u8 = undefined;
    var volume = try fat32.Volume(MemoryCard).mount(&card, &scratch);
    const file = try volume.findRoot("GAIN    WAV".*);
    try std.testing.expectEqual(@as(u32, file_bytes), file.size);
    try std.testing.expectEqual(@as(u32, 3), file.first_cluster);

    var reader = try volume.reader(file);
    const info = try wav.parse(&reader);
    try std.testing.expectEqual(wav.Encoding.pcm_integer, info.encoding);
    try std.testing.expectEqual(@as(u16, 2), info.channels);
    try std.testing.expectEqual(@as(u32, 48_000), info.sample_rate);
    try std.testing.expectEqual(@as(u16, 16), info.bits_per_sample);
    try std.testing.expectEqual(@as(u32, 56), info.data_offset);
    try std.testing.expectEqual(@as(u32, 544), info.data_bytes);

    var audio: [544]u8 = undefined;
    try std.testing.expectEqual(audio.len, try reader.read(&audio));
    try std.testing.expectEqual(@as(usize, 0), try reader.read(&audio));
    for (audio, 0..) |byte, index| {
        try std.testing.expectEqual(@as(u8, @truncate(index *% 37)), byte);
    }
}

test "FAT32 reader handles arbitrary caller buffer boundaries" {
    var card = MemoryCard.init();
    var scratch: [fat32.sector_bytes]u8 = undefined;
    var volume = try fat32.Volume(MemoryCard).mount(&card, &scratch);
    const file = try volume.findRoot("GAIN    WAV".*);
    var reader = try volume.reader(file);
    var actual: [file_bytes]u8 = undefined;
    var offset: usize = 0;
    const steps = [_]usize{ 1, 7, 123, 509, 17 };
    var step: usize = 0;
    while (offset < actual.len) : (step += 1) {
        const requested = @min(steps[step % steps.len], actual.len - offset);
        const count = try reader.read(actual[offset..][0..requested]);
        try std.testing.expect(count != 0);
        offset += count;
    }
    try std.testing.expectEqualSlices(u8, &card.image, &actual);
}

test "FAT32 directory iterator decodes nested long filenames" {
    var card = MemoryCard.init();
    var scratch: [fat32.sector_bytes]u8 = undefined;
    var volume = try fat32.Volume(MemoryCard).mount(&card, &scratch);
    var root = try volume.iterate(volume.rootDirectory());

    const gain = (try root.next()).?;
    try std.testing.expectEqualStrings("GAIN.WAV", gain.name());
    const album = (try root.next()).?;
    try std.testing.expectEqual(fat32.EntryKind.directory, album.kind);
    try std.testing.expectEqualStrings("Synthetic Album Editions", album.name());
    try std.testing.expect((try root.next()) == null);

    var contents = try volume.iterate(try album.directory());
    const dot = (try contents.next()).?;
    try std.testing.expectEqualStrings(".", dot.name());
    const parent = (try contents.next()).?;
    try std.testing.expectEqualStrings("..", parent.name());
    const aria = (try contents.next()).?;
    try std.testing.expectEqual(fat32.EntryKind.file, aria.kind);
    try std.testing.expectEqualStrings("01 - Tone.flac", aria.name());
    try std.testing.expectEqual(@as(u32, 123), (try aria.file()).size);
    try std.testing.expect((try contents.next()) == null);
}

test "WAV parser rejects inconsistent format arithmetic" {
    var image = MemoryCard.init().image;
    write32(&image, 28, 123); // byte rate
    var reader = SliceReader{ .bytes = &image };
    try std.testing.expectError(error.InvalidFormat, wav.parse(&reader));
}

test "WAV parser accepts 24-bit extensible PCM" {
    var image: [72]u8 = @splat(0);
    @memcpy(image[0..4], "RIFF");
    write32(&image, 4, image.len - 8);
    @memcpy(image[8..12], "WAVE");
    @memcpy(image[12..16], "fmt ");
    write32(&image, 16, 40);
    write16(&image, 20, 0xfffe);
    write16(&image, 22, 2);
    write32(&image, 24, 96_000);
    write32(&image, 28, 576_000);
    write16(&image, 32, 6);
    write16(&image, 34, 24);
    write16(&image, 36, 22);
    write16(&image, 38, 24);
    write32(&image, 40, 3);
    image[44] = 1;
    image[48] = 0x00;
    image[49] = 0x00;
    image[50] = 0x10;
    image[51] = 0x00;
    image[52] = 0x80;
    image[54] = 0x00;
    image[55] = 0xaa;
    image[57] = 0x38;
    image[58] = 0x9b;
    image[59] = 0x71;
    @memcpy(image[60..64], "data");
    write32(&image, 64, 0);

    var reader = SliceReader{ .bytes = &image };
    const info = try wav.parse(&reader);
    try std.testing.expectEqual(wav.Encoding.pcm_integer, info.encoding);
    try std.testing.expectEqual(@as(u16, 24), info.valid_bits_per_sample);
    try std.testing.expectEqual(@as(u32, 3), info.channel_mask);
    try std.testing.expectEqual(@as(u32, 96_000), info.sample_rate);
}

test "WAV parser never escapes arbitrary input" {
    try std.testing.fuzz({}, fuzzWave, .{ .corpus = &.{
        "",
        "\xff\xff\xff\xffRIFF\x04\x00\x00\x00WAVE",
        "\xff\xff\xff\xffRIFF\xff\xff\xff\xffWAVEfmt ",
    } });
}

fn fuzzWave(_: void, smith: *std.testing.Smith) !void {
    var bytes: [1_024]u8 = undefined;
    const length = smith.slice(&bytes);
    var reader = SliceReader{ .bytes = bytes[0..length] };
    _ = wav.parse(&reader) catch {};
}

const SliceReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn read(self: *SliceReader, output: []u8) !usize {
        const count = @min(output.len, self.bytes.len - self.offset);
        @memcpy(output[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};

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
    write32(sector, 8, 0x0fff_ffff); // root cluster 2
    write32(sector, 12, 5); // file cluster 3 continues at cluster 5
    write32(sector, 20, 0x0fff_ffff);
    write32(sector, 24, 0x0fff_ffff); // album directory cluster 6
    write32(sector, 28, 0x0fff_ffff); // album file cluster 7
}

fn makeRootDirectory(sector: *[fat32.sector_bytes]u8) void {
    @memcpy(sector[0..11], "GAIN    WAV");
    sector[11] = 0x20;
    write16(sector, 26, 3);
    write32(sector, 28, file_bytes);
    const alias = "SYNTH~1    ".*;
    const checksum = shortChecksum(&alias);
    writeLongNameEntry(sector, 32, 2, true, "Synthetic Album Editions", checksum);
    writeLongNameEntry(sector, 64, 1, false, "Synthetic Album Editions", checksum);
    @memcpy(sector[96..107], &alias);
    sector[107] = 0x10;
    write16(sector, 96 + 26, 6);
}

fn makeAlbumDirectory(sector: *[fat32.sector_bytes]u8) void {
    const dot = ".          ".*;
    @memcpy(sector[0..11], &dot);
    sector[11] = 0x10;
    write16(sector, 26, 6);
    const parent = "..         ".*;
    @memcpy(sector[32..43], &parent);
    sector[43] = 0x10;
    write16(sector, 32 + 26, 0);

    const alias = "01-TON~1FLA".*;
    const checksum = shortChecksum(&alias);
    writeLongNameEntry(sector, 64, 2, true, "01 - Tone.flac", checksum);
    writeLongNameEntry(sector, 96, 1, false, "01 - Tone.flac", checksum);
    @memcpy(sector[128..139], &alias);
    sector[139] = 0x20;
    write16(sector, 128 + 26, 7);
    write32(sector, 128 + 28, 123);
}

fn makeWave(image: *[file_bytes]u8) void {
    @memcpy(image[0..4], "RIFF");
    write32(image, 4, file_bytes - 8);
    @memcpy(image[8..12], "WAVE");
    @memcpy(image[12..16], "fmt ");
    write32(image, 16, 16);
    write16(image, 20, 1);
    write16(image, 22, 2);
    write32(image, 24, 48_000);
    write32(image, 28, 192_000);
    write16(image, 32, 4);
    write16(image, 34, 16);
    @memcpy(image[36..40], "JUNK");
    write32(image, 40, 3);
    image[44] = 1;
    image[45] = 2;
    image[46] = 3;
    image[47] = 0;
    @memcpy(image[48..52], "data");
    write32(image, 52, 544);
    for (image[56..], 0..) |*byte, index| byte.* = @truncate(index *% 37);
}

fn signature(sector: *[fat32.sector_bytes]u8) void {
    sector[510] = 0x55;
    sector[511] = 0xaa;
}

fn writeLongNameEntry(
    sector: *[fat32.sector_bytes]u8,
    offset: usize,
    ordinal: u8,
    last: bool,
    name: []const u8,
    checksum: u8,
) void {
    const positions = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    sector[offset] = ordinal | if (last) @as(u8, 0x40) else 0;
    sector[offset + 11] = 0x0f;
    sector[offset + 13] = checksum;
    const base = (@as(usize, ordinal) - 1) * positions.len;
    for (positions, 0..) |position, index| {
        const source = base + index;
        const unit: u16 = if (source < name.len) name[source] else if (source == name.len) 0 else 0xffff;
        write16(sector, offset + position, unit);
    }
}

fn shortChecksum(name: *const [11]u8) u8 {
    var checksum: u8 = 0;
    for (name) |byte| checksum = ((checksum >> 1) | (checksum << 7)) +% byte;
    return checksum;
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
