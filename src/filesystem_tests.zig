//! Sparse 256 GiB card. It deliberately has no host filesystem dependency and
//! stores only boot sectors and the few clusters touched by each test.
const std = @import("std");
const fs = @import("filesystem.zig");
const ex = @import("exfat.zig");
const image = @import("boot/image.zig");
const spc = 256;
const heap = 20000;
const clusters = 2097000;
const sectors = 536870912;
const file_cluster = clusters - 10;
const Disk = struct {
    boot: [24 * 512]u8 = @splat(0),
    root: [512]u8 = @splat(0),
    upcase: [262]u8 = @splat(0),
    data: [1024]u8 align(4) = @splat(0),
    contiguous: bool = true,
    pattern: bool = false,
    missing_allocation: bool = false,
    corrupt_chain: bool = false,
    writes: usize = 0,
    fail_write: ?u32 = null,
    read_count: usize = 0,
    fat_reads: usize = 0,
    long_file: bool = false,

    const long_file_clusters = 130;

    fn fileStart(self: *const Disk) u32 {
        return if (self.long_file) clusters - 512 else file_cluster;
    }

    fn physicalFileCluster(self: *const Disk, logical: u32) u32 {
        return self.fileStart() + if (self.contiguous) logical else (logical * 73) % 256;
    }

    fn put(comptime T: type, b: []u8, at: usize, value: T) void {
        std.mem.writeInt(T, b[at..][0..@sizeOf(T)], value, .little);
    }
    fn lba(cluster: u32) u32 {
        return heap + (cluster - 2) * spc;
    }
    fn init() Disk {
        var self: Disk = .{};
        const b = self.boot[0..512];
        @memcpy(b[3..11], "EXFAT   ");
        put(u64, b, 72, sectors);
        put(u32, b, 80, 24);
        put(u32, b, 84, 16384);
        put(u32, b, 88, heap);
        put(u32, b, 92, clusters);
        put(u32, b, 96, 2);
        put(u32, b, 100, 0x12345678);
        put(u16, b, 104, 0x100);
        b[108] = 9;
        b[109] = 8;
        b[110] = 1;
        put(u16, b, 510, 0xaa55);
        var sum: u32 = 0;
        for (self.boot[0 .. 11 * 512], 0..) |byte, at| if (at != 106 and at != 107 and at != 112) {
            sum = ex.checksum32(sum, byte);
        };
        for (0..128) |i| put(u32, &self.boot, 11 * 512 + i * 4, sum);
        @memcpy(self.boot[12 * 512 ..], self.boot[0 .. 12 * 512]);
        for (0..128) |i| put(u16, &self.upcase, i * 2, @intCast(if (i >= 'a' and i <= 'z') i - 32 else i));
        put(u16, &self.upcase, 256, 0xffff);
        put(u16, &self.upcase, 258, 65407);
        put(u16, &self.upcase, 260, 0xffff);
        self.root[0] = 0x81;
        put(u32, &self.root, 20, 4);
        put(u64, &self.root, 24, (clusters + 7) / 8);
        self.root[32] = 0x82;
        put(u32, &self.root, 52, 3);
        put(u64, &self.root, 56, self.upcase.len);
        sum = 0;
        for (self.upcase) |byte| sum = ex.checksum32(sum, byte);
        put(u32, &self.root, 36, sum);
        self.entry(1024, 1024, true);
        for (&self.data, 0..) |*byte, i| byte.* = @truncate(i *% 37);
        return self;
    }
    fn entry(self: *Disk, size: u64, valid: u64, contiguous: bool) void {
        self.contiguous = contiguous;
        const p = self.root[64..160];
        @memset(p, 0);
        p[0] = 0x85;
        p[1] = 2;
        put(u16, p, 4, 0x20);
        p[32] = 0xc0;
        p[33] = if (contiguous) 3 else 1;
        p[35] = 8;
        put(u64, p, 40, valid);
        put(u32, p, 52, self.fileStart());
        put(u64, p, 56, size);
        p[64] = 0xc1;
        for ("Tone.wav", 0..) |byte, i| put(u16, p, 66 + i * 2, byte);
        self.checksum();
    }
    fn checksum(self: *Disk) void {
        var sum: u16 = 0;
        for (self.root[64..160], 0..) |byte, at| if (at != 2 and at != 3) {
            sum = ex.checksum16(sum, byte);
        };
        put(u16, &self.root, 66, sum);
    }
    pub fn readBlocks(self: *Disk, start: u32, output: []u8) !void {
        if (output.len % 512 != 0 or @as(u64, start) + output.len / 512 > sectors) return error.OutOfRange;
        self.read_count += 1;
        for (0..output.len / 512) |i| {
            const block = start + @as(u32, @intCast(i));
            const row = output[i * 512 ..][0..512];
            @memset(row, 0);
            if (block < 24) {
                @memcpy(row, self.boot[block * 512 ..][0..512]);
            } else if (block < 24 + 16384) {
                self.fat_reads += 1;
                for (0..128) |j| {
                    const cluster = (block - 24) * 128 + @as(u32, @intCast(j));
                    const link: u32 = if (self.long_file and cluster >= self.fileStart() and cluster < self.fileStart() + 256) long: {
                        if (self.contiguous) break :long 0; // NoFatChain has no usable FAT links.
                        const logical = ((cluster - self.fileStart()) * 249) % 256; // Inverse of73 modulo256.
                        break :long if (logical + 1 < long_file_clusters) self.physicalFileCluster(logical + 1) else 0xffffffff;
                    } else switch (cluster) {
                        2, 3, 6 => 0xffffffff,
                        4 => 5,
                        5 => 6,
                        file_cluster => if (self.corrupt_chain) file_cluster else file_cluster + 3,
                        file_cluster + 3 => file_cluster + 1,
                        file_cluster + 1 => 0xffffffff,
                        else => 0,
                    };
                    put(u32, row, j * 4, link);
                }
            } else if (block == heap) {
                @memcpy(row, &self.root);
            } else if (block == lba(3)) {
                @memcpy(row[0..self.upcase.len], &self.upcase);
            } else if (block >= lba(4) and block < lba(7)) {
                @memset(row, if (self.missing_allocation) 0 else 0xff);
            } else if (self.pattern and block >= lba(self.fileStart()) and block < lba(self.fileStart() + @as(u32, if (self.long_file) 256 else 4))) {
                const physical = (block - lba(self.fileStart())) / spc;
                const logical: ?u32 = if (self.contiguous) physical else if (self.long_file) (physical * 249) % 256 else switch (physical) {
                    0 => 0,
                    3 => 1,
                    1 => 2,
                    else => null,
                };
                if (logical) |index| for (row, 0..) |*byte, at| {
                    const position = index * spc * 512 + ((block - lba(self.fileStart())) % spc) * 512 + at;
                    byte.* = @truncate(position *% 37 +% if (self.long_file) index *% 19 else 0);
                };
            } else if (block >= lba(file_cluster) and block < lba(file_cluster) + 2) {
                @memcpy(row, self.data[(block - lba(file_cluster)) * 512 ..][0..512]);
            }
        }
    }
    pub fn writeBlocks(self: *Disk, start: u32, input: []const u8) !void {
        if (self.fail_write == start) return error.InjectedWriteFailure;
        self.writes += 1;
        if (start == 0 or start == 12) {
            @memcpy(self.boot[start * 512 ..][0..512], input);
            return;
        }
        if (start == lba(file_cluster) and input.len <= self.data.len) {
            @memcpy(self.data[0..input.len], input);
            return;
        }
        return error.UnexpectedWrite;
    }
    pub fn sync(_: *Disk) !void {}
};
const Volume = fs.Volume(Disk);

test "256 GiB exFAT geometry reads and seeks beyond the 128 GiB boundary" {
    var disk = Disk.init();
    var scratch: [512]u8 = undefined;
    var volume = try Volume.mount(&disk, &scratch);
    try std.testing.expectEqual(fs.Kind.exfat, volume.kind());
    try std.testing.expectEqual(256, volume.sectors_per_cluster);
    const file = try (try volume.findPath("tone.WAV")).file();
    const untouched = disk.data;
    var reader = try volume.reader(file);
    var actual: [1024]u8 align(4) = undefined;
    try std.testing.expectEqual(1024, try reader.read(&actual));
    try std.testing.expectEqualSlices(u8, &untouched, &actual);
    try reader.seekTo(517);
    var part: [23]u8 = undefined;
    try std.testing.expectEqual(part.len, try reader.read(&part));
    try std.testing.expectEqualSlices(u8, untouched[517..540], &part);
    try std.testing.expectEqual(0, disk.writes);
}

test "exFAT never exposes bytes beyond ValidDataLength" {
    var disk = Disk.init();
    disk.entry(1024, 517, true);
    var scratch: [512]u8 = undefined;
    var volume = try Volume.mount(&disk, &scratch);
    const file = try (try volume.findPath("Tone.wav")).file();
    var reader = try volume.reader(file);
    var actual: [1024]u8 align(4) = undefined;
    try std.testing.expectEqual(actual.len, try reader.read(&actual));
    try std.testing.expectEqualSlices(u8, disk.data[0..517], actual[0..517]);
    try std.testing.expect(std.mem.allEqual(u8, actual[517..], 0));
    try std.testing.expectError(error.InvalidWrite, volume.overwrite(file));
}

test "exFAT checks boot and directory checksums and recovers read-only from backup" {
    var disk = Disk.init();
    var scratch: [512]u8 = undefined;
    disk.boot[120] ^= 1;
    var volume = try Volume.mount(&disk, &scratch);
    const file = try (try volume.findPath("Tone.wav")).file();
    var writer = try volume.overwrite(file);
    var data: [512]u8 align(4) = @splat(1);
    try std.testing.expectError(error.ReadOnlyFilesystem, writer.write(&data));
    disk.boot[12 * 512 + 120] ^= 1;
    try std.testing.expectError(error.BootChecksum, Volume.mount(&disk, &scratch));
    disk = Disk.init();
    disk.root[72] ^= 1;
    volume = try Volume.mount(&disk, &scratch);
    try std.testing.expectError(error.EntryChecksum, volume.findPath("Tone.wav"));
}

test "fixed-allocation writes check bitmap and bracket data with dirty flags" {
    var disk = Disk.init();
    var scratch: [512]u8 = undefined;
    var volume = try Volume.mount(&disk, &scratch);
    const file = try (try volume.findPath("Tone.wav")).file();
    var writer = try volume.overwrite(file);
    var data: [512]u8 align(4) = @splat(0x32);
    try writer.write(&data);
    try std.testing.expectEqual(2, disk.boot[106]);
    try std.testing.expectEqual(2, disk.boot[12 * 512 + 106]);
    try writer.sync();
    try std.testing.expectEqual(0, disk.boot[106]);
    try std.testing.expectEqualSlices(u8, &data, disk.data[0..512]);
    disk = Disk.init();
    disk.missing_allocation = true;
    volume = try Volume.mount(&disk, &scratch);
    writer = try volume.overwrite(file);
    try std.testing.expectError(error.UnallocatedCluster, writer.write(&data));
    try std.testing.expectError(error.ReadOnlyFilesystem, writer.sync());
    try std.testing.expectEqual(2, disk.boot[106]);
}

test "loader consumes the same exFAT file API and validates payload before entry" {
    var disk = Disk.init();
    var envelope: [1024]u8 = undefined;
    var payload: [960]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i *% 41);
    _ = image.envelope(&payload, &envelope);
    disk.data = envelope;
    var scratch: [512]u8 = undefined;
    var volume = try Volume.mount(&disk, &scratch);
    var reader = try volume.reader(try (try volume.findPath("Tone.wav")).file());
    var output: [960]u8 = undefined;
    _ = try image.load(&reader, 1024, &output);
    try std.testing.expectEqualSlices(u8, &payload, &output);
    try std.testing.expectEqual(0, disk.writes);
}

test "contiguous and fragmented exFAT streams cross clusters and seek identically" {
    for ([_]bool{ false, true }) |contiguous| {
        var disk = Disk.init();
        const size = 2 * spc * 512 + 513;
        disk.entry(size, size, contiguous);
        disk.pattern = true;
        var scratch: [512]u8 = undefined;
        var volume = try Volume.mount(&disk, &scratch);
        var reader = try volume.reader(try (try volume.findPath("Tone.wav")).file());
        var bytes: [4093]u8 align(4) = undefined;
        for ([_]u32{ 0, spc * 512 - 17, spc * 512, 2 * spc * 512 - 23, size, size - 1, 512 }) |target| {
            try reader.seekTo(target);
            const count = try reader.read(&bytes);
            try std.testing.expectEqual(@min(bytes.len, size - target), count);
            for (bytes[0..count], target..) |byte, at| try std.testing.expectEqual(@as(u8, @truncate(at *% 37)), byte);
        }
        try std.testing.expectEqual(0, disk.writes);
    }
}

test "sparse seeks preserve exFAT data and validity across multiple checkpoints without indexing NoFatChain" {
    const seeks = @import("file_seek_index.zig");
    const Observer = struct {
        cancel: bool = false,
        pub fn cancelled(self: @This()) bool {
            return self.cancel;
        }
    };
    const cluster_bytes = spc * 512;
    const size = Disk.long_file_clusters * cluster_bytes;
    const valid = size - 613;
    for ([_]bool{ false, true }) |contiguous| {
        var disk = Disk.init();
        disk.long_file = true;
        disk.entry(size, valid, contiguous);
        disk.pattern = true;
        var scratch: [512]u8 = undefined;
        var volume = try Volume.mount(&disk, &scratch);
        const file = try (try volume.findPath("Tone.wav")).file();
        var reader = try volume.reader(file);
        var index: seeks.Index = .{};
        try std.testing.expectError(error.Cancelled, index.seek(&reader, size, cluster_bytes, Observer{ .cancel = true }));
        try std.testing.expectEqual(0, reader.position);
        try index.seek(&reader, size, cluster_bytes, Observer{});
        try std.testing.expectEqual(if (contiguous) @as(usize, 0) else 3, index.count);
        try std.testing.expectEqual(size, reader.position);
        try std.testing.expectEqual(0, reader.remaining);
        try std.testing.expectEqual(valid, reader.valid_length);
        const at_eof = reader;
        try std.testing.expectError(error.InvalidSeek, index.seek(&reader, size + 1, cluster_bytes, Observer{}));
        try std.testing.expectEqual(at_eof.position, reader.position);
        var direct = try volume.reader(file);
        var indexed_bytes: [4093]u8 align(4) = undefined;
        var direct_bytes: [4093]u8 align(4) = undefined;
        for ([_]u32{ 0, 64 * cluster_bytes - 17, 64 * cluster_bytes, 128 * cluster_bytes + 7, valid - 17, valid, size - 1, size, 512 }) |target| {
            reader = try volume.reader(file);
            const before = disk.fat_reads;
            try index.seek(&reader, target, cluster_bytes, Observer{});
            if (contiguous) try std.testing.expectEqual(before, disk.fat_reads) else try std.testing.expect(disk.fat_reads - before < seeks.stride);
            const count = try reader.read(&indexed_bytes);
            try direct.seekTo(target);
            try std.testing.expectEqual(count, try direct.read(&direct_bytes));
            try std.testing.expectEqualSlices(u8, direct_bytes[0..count], indexed_bytes[0..count]);
            try std.testing.expectEqual(@min(indexed_bytes.len, size - target), count);
            for (indexed_bytes[0..count], target..) |byte, at| try std.testing.expectEqual(if (at >= valid) @as(u8, 0) else @as(u8, @truncate(at *% 37 +% (at / cluster_bytes) *% 19)), byte);
        }
        try std.testing.expectEqual(0, disk.writes);
    }
}

test "failed data writes leave the volume dirty and disable further writes" {
    var disk = Disk.init();
    disk.fail_write = Disk.lba(file_cluster);
    var scratch: [512]u8 = undefined;
    var volume = try Volume.mount(&disk, &scratch);
    var writer = try volume.overwrite(try (try volume.findPath("Tone.wav")).file());
    var bytes: [512]u8 align(4) = @splat(0);
    try std.testing.expectError(error.InjectedWriteFailure, writer.write(&bytes));
    try std.testing.expectEqual(2, disk.boot[106]);
    try std.testing.expectError(error.ReadOnlyFilesystem, writer.write(&bytes));
    try std.testing.expectError(error.ReadOnlyFilesystem, writer.sync());
}

test "malformed exFAT stream ranges and surrogate names are rejected" {
    var scratch: [512]u8 = undefined;
    for ([_]u8{ 0, 1, 2 }) |mutation| {
        var disk = Disk.init();
        switch (mutation) {
            0 => Disk.put(u64, &disk.root, 104, 1025),
            1 => Disk.put(u32, &disk.root, 116, clusters + 2),
            2 => Disk.put(u16, &disk.root, 130, 0xdc00),
            else => unreachable,
        }
        disk.checksum();
        var volume = try Volume.mount(&disk, &scratch);
        if (volume.findPath("Tone.wav")) |_| return error.AcceptedMalformedEntry else |_| {}
    }
}

const Partitioned = struct {
    disk: Disk,
    headers: [3 * 512]u8 = @splat(0),
    const start = 2048;
    fn init(gpt: bool) Partitioned {
        var self = Partitioned{ .disk = Disk.init() };
        Disk.put(u16, &self.headers, 510, 0xaa55);
        self.headers[450] = if (gpt) 0xee else 7;
        Disk.put(u32, &self.headers, 454, if (gpt) 1 else start);
        Disk.put(u32, &self.headers, 458, if (gpt) start + sectors else sectors);
        const boot = &self.disk.boot;
        Disk.put(u64, boot, 64, start);
        var sum: u32 = 0;
        for (boot[0 .. 11 * 512], 0..) |byte, at| if (at != 106 and at != 107 and at != 112) {
            sum = ex.checksum32(sum, byte);
        };
        for (0..128) |i| Disk.put(u32, boot, 11 * 512 + i * 4, sum);
        @memcpy(boot[12 * 512 ..], boot[0 .. 12 * 512]);
        if (gpt) {
            const entry = self.headers[1024..1536];
            @memcpy(entry[0..16], &[_]u8{ 0xa2, 0xa0, 0xd0, 0xeb, 0xe5, 0xb9, 0x33, 0x44, 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7 });
            Disk.put(u64, entry, 32, start);
            Disk.put(u64, entry, 40, start + sectors - 1);
            const header = self.headers[512..1024];
            @memcpy(header[0..8], "EFI PART");
            Disk.put(u32, header, 8, 0x10000);
            Disk.put(u32, header, 12, 92);
            Disk.put(u64, header, 24, 1);
            Disk.put(u64, header, 32, start + sectors + 33);
            Disk.put(u64, header, 40, 34);
            Disk.put(u64, header, 48, start + sectors - 1);
            Disk.put(u64, header, 72, 2);
            Disk.put(u32, header, 80, 4);
            Disk.put(u32, header, 84, 128);
            Disk.put(u32, header, 88, std.hash.Crc32.hash(entry));
            Disk.put(u32, header, 16, std.hash.Crc32.hash(header[0..92]));
        }
        return self;
    }
    pub fn readBlocks(self: *Partitioned, lba: u32, output: []u8) !void {
        if (lba < 3 and output.len == 512) {
            @memcpy(output, self.headers[lba * 512 ..][0..512]);
            return;
        }
        if (lba < start) return error.OutOfRange;
        try self.disk.readBlocks(lba - start, output);
    }
};

test "MBR and checksummed GPT exFAT partitions resolve the same 256 GiB stream" {
    for ([_]bool{ false, true }) |gpt| {
        var disk = Partitioned.init(gpt);
        var scratch: [512]u8 = undefined;
        var volume = try fs.Volume(Partitioned).mount(&disk, &scratch);
        var reader = try volume.reader(try (try volume.findPath("Tone.wav")).file());
        var actual: [1024]u8 align(4) = undefined;
        try std.testing.expectEqual(actual.len, try reader.read(&actual));
        try std.testing.expectEqualSlices(u8, &disk.disk.data, &actual);
    }
    for ([_]usize{ 512 + 56, 1024 + 19 }) |at| {
        var disk = Partitioned.init(true);
        disk.headers[at] ^= 1;
        var scratch: [512]u8 = undefined;
        try std.testing.expectError(error.InvalidGpt, fs.Volume(Partitioned).mount(&disk, &scratch));
    }
}
