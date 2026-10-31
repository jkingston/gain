pub const sector_bytes = 512;

pub const Error = error{
    InvalidBootSector,
    InvalidPartition,
    UnsupportedSectorSize,
    NotFat32,
    CorruptFilesystem,
    InvalidName,
    NotFound,
    IsDirectory,
    NotDirectory,
    UnexpectedEndOfChain,
    BadCluster,
};

pub const File = struct {
    first_cluster: u32,
    size: u32,
};

pub const maximum_name_bytes = 192;

pub const Directory = struct {
    first_cluster: u32,
};

pub const EntryKind = enum { file, directory };

pub const DirectoryEntry = struct {
    name_bytes: [maximum_name_bytes]u8 = @splat(0),
    name_length: u8 = 0,
    kind: EntryKind,
    first_cluster: u32,
    size: u32,
    attributes: u8,

    pub fn name(self: *const DirectoryEntry) []const u8 {
        return self.name_bytes[0..self.name_length];
    }

    pub fn file(self: DirectoryEntry) Error!File {
        if (self.kind != .file) return error.IsDirectory;
        return .{ .first_cluster = self.first_cluster, .size = self.size };
    }

    pub fn directory(self: DirectoryEntry) Error!Directory {
        if (self.kind != .directory) return error.NotDirectory;
        if (self.first_cluster < first_data_cluster) return error.CorruptFilesystem;
        return .{ .first_cluster = self.first_cluster };
    }
};

/// Allocation-free, read-only FAT32 access. `Device.readBlocks` is the only
/// device-specific operation and must fill a whole number of 512-byte sectors.
pub fn Volume(comptime Device: type) type {
    return struct {
        const Self = @This();

        device: *Device,
        scratch: *[sector_bytes]u8,
        partition_lba: u32,
        partition_sectors: u32,
        sectors_per_cluster: u8,
        fat_lba: u32,
        fat_sectors: u32,
        data_lba: u32,
        root_cluster: u32,
        cluster_count: u32,

        pub fn mount(device: *Device, scratch: *[sector_bytes]u8) !Self {
            try device.readBlocks(0, scratch);

            var partition_lba: u32 = 0;
            var partition_sectors: u32 = read32(scratch, 32);
            if (!looksLikeBootSector(scratch)) {
                if (!hasBootSignature(scratch)) return error.InvalidPartition;
                const entry = firstUsablePartition(scratch) orelse return error.InvalidPartition;
                partition_lba = read32(scratch, entry + 8);
                partition_sectors = read32(scratch, entry + 12);
                if (partition_lba == 0 or partition_sectors == 0) return error.InvalidPartition;
                try device.readBlocks(partition_lba, scratch);
            }

            if (!hasBootSignature(scratch)) return error.InvalidBootSector;
            if (read16(scratch, 11) != sector_bytes) return error.UnsupportedSectorSize;

            const sectors_per_cluster = scratch[13];
            const reserved_sectors = read16(scratch, 14);
            const fat_count = scratch[16];
            const root_entries = read16(scratch, 17);
            const fat16_sectors = read16(scratch, 22);
            const fat_sectors = read32(scratch, 36);
            const root_cluster = read32(scratch, 44) & cluster_mask;
            const boot_total_sectors = if (read16(scratch, 19) != 0)
                @as(u32, read16(scratch, 19))
            else
                read32(scratch, 32);

            if (!isPowerOfTwo(sectors_per_cluster) or reserved_sectors == 0 or
                fat_count == 0 or root_entries != 0 or fat16_sectors != 0 or
                fat_sectors == 0 or root_cluster < first_data_cluster or
                boot_total_sectors == 0)
            {
                return error.NotFat32;
            }
            if (partition_sectors == 0) partition_sectors = boot_total_sectors;
            if (boot_total_sectors > partition_sectors) return error.CorruptFilesystem;

            const fat_area = @as(u64, fat_count) * fat_sectors;
            const first_data_sector = @as(u64, reserved_sectors) + fat_area;
            if (first_data_sector >= boot_total_sectors) return error.CorruptFilesystem;
            const data_sectors = boot_total_sectors - @as(u32, @intCast(first_data_sector));
            const cluster_count = data_sectors / sectors_per_cluster;
            if (cluster_count < minimum_fat32_clusters) return error.NotFat32;
            if (@as(u64, root_cluster) >= @as(u64, cluster_count) + first_data_cluster) {
                return error.CorruptFilesystem;
            }

            const fat_lba = @as(u64, partition_lba) + reserved_sectors;
            const data_lba = @as(u64, partition_lba) + first_data_sector;
            if (fat_lba > maximum_lba or data_lba > maximum_lba) return error.CorruptFilesystem;

            return .{
                .device = device,
                .scratch = scratch,
                .partition_lba = partition_lba,
                .partition_sectors = partition_sectors,
                .sectors_per_cluster = sectors_per_cluster,
                .fat_lba = @intCast(fat_lba),
                .fat_sectors = fat_sectors,
                .data_lba = @intCast(data_lba),
                .root_cluster = root_cluster,
                .cluster_count = cluster_count,
            };
        }

        pub fn rootDirectory(self: Self) Directory {
            return .{ .first_cluster = self.root_cluster };
        }

        pub fn iterate(self: *Self, directory: Directory) !DirectoryIterator {
            if (!self.validCluster(directory.first_cluster)) return error.BadCluster;
            return .{ .volume = self, .cluster = directory.first_cluster };
        }

        pub const DirectoryIterator = struct {
            volume: *Self,
            cluster: u32,
            sector_index: u8 = 0,
            entry_offset: usize = sector_bytes,
            finished: bool = false,
            long_units: [maximum_long_name_units]u16 = @splat(0xffff),
            long_unit_count: usize = 0,
            long_checksum: u8 = 0,
            expected_ordinal: u5 = 0,
            long_active: bool = false,

            pub fn next(self: *DirectoryIterator) !?DirectoryEntry {
                while (!self.finished) {
                    if (self.entry_offset == sector_bytes) try self.loadSector();
                    if (self.finished) return null;

                    const entry = self.volume.scratch[self.entry_offset..][0..directory_entry_bytes];
                    self.entry_offset += directory_entry_bytes;
                    const first = entry[0];
                    if (first == directory_end) {
                        self.finished = true;
                        return null;
                    }
                    if (first == directory_deleted) {
                        self.resetLongName();
                        continue;
                    }

                    const attributes = entry[11];
                    if (attributes == long_name_attributes) {
                        self.consumeLongName(entry) catch {
                            self.resetLongName();
                        };
                        continue;
                    }
                    if (attributes & volume_label_attribute != 0) {
                        self.resetLongName();
                        continue;
                    }

                    const high = read16(entry, 20);
                    const low = read16(entry, 26);
                    const first_cluster = (@as(u32, high) << 16 | low) & cluster_mask;
                    const size = read32(entry, 28);
                    const kind: EntryKind = if (attributes & directory_attribute != 0) .directory else .file;
                    // FAT32 encodes `..` as cluster zero when its parent is the
                    // root directory. Directory handles validate their cluster
                    // when opened; accepting the entry here lets callers skip
                    // the two navigation records normally.
                    if (kind == .file and size != 0 and first_cluster < first_data_cluster) {
                        self.resetLongName();
                        return error.CorruptFilesystem;
                    }

                    var result = DirectoryEntry{
                        .kind = kind,
                        .first_cluster = first_cluster,
                        .size = size,
                        .attributes = attributes,
                    };
                    const has_long_name = self.long_active and self.expected_ordinal == 0 and
                        self.long_checksum == shortNameChecksum(entry[0..11]);
                    if (has_long_name) {
                        result.name_length = @intCast(encodeLongName(
                            self.long_units[0..self.long_unit_count],
                            &result.name_bytes,
                        ));
                    }
                    if (!has_long_name or result.name_length == 0) {
                        result.name_length = @intCast(decodeShortName(entry[0..11], &result.name_bytes));
                    }
                    self.resetLongName();
                    return result;
                }
                return null;
            }

            fn loadSector(self: *DirectoryIterator) !void {
                if (self.sector_index == self.volume.sectors_per_cluster) {
                    self.cluster = (try self.volume.nextClusterOrEnd(self.cluster)) orelse {
                        self.finished = true;
                        return;
                    };
                    self.sector_index = 0;
                }
                const lba = try self.volume.clusterLba(self.cluster) + self.sector_index;
                try self.volume.device.readBlocks(lba, self.volume.scratch);
                self.sector_index += 1;
                self.entry_offset = 0;
            }

            fn consumeLongName(self: *DirectoryIterator, entry: *const [directory_entry_bytes]u8) !void {
                const raw_ordinal = entry[0];
                const ordinal: u5 = @intCast(raw_ordinal & long_name_ordinal_mask);
                if (ordinal == 0 or ordinal > maximum_long_name_entries or entry[12] != 0 or
                    read16(entry, 26) != 0)
                {
                    return error.CorruptFilesystem;
                }
                const starts_sequence = raw_ordinal & long_name_last_entry != 0;
                if (starts_sequence) {
                    self.long_units = @splat(0xffff);
                    self.long_unit_count = @as(usize, ordinal) * long_name_units_per_entry;
                    self.long_checksum = entry[13];
                    self.expected_ordinal = ordinal;
                    self.long_active = true;
                }
                if (!self.long_active or entry[13] != self.long_checksum or ordinal != self.expected_ordinal) {
                    return error.CorruptFilesystem;
                }

                const base = (@as(usize, ordinal) - 1) * long_name_units_per_entry;
                for (long_name_unit_offsets, 0..) |offset, index| {
                    self.long_units[base + index] = read16(entry, offset);
                }
                self.expected_ordinal -= 1;
            }

            fn resetLongName(self: *DirectoryIterator) void {
                self.long_active = false;
                self.long_unit_count = 0;
                self.expected_ordinal = 0;
            }
        };

        pub fn findRoot(self: *Self, short_name: [11]u8) !File {
            if (!validShortName(short_name)) return error.InvalidName;

            var cluster = self.root_cluster;
            while (true) {
                const cluster_lba = try self.clusterLba(cluster);
                for (0..self.sectors_per_cluster) |sector_index| {
                    try self.device.readBlocks(cluster_lba + @as(u32, @intCast(sector_index)), self.scratch);
                    var entry_offset: usize = 0;
                    while (entry_offset < sector_bytes) : (entry_offset += directory_entry_bytes) {
                        const first = self.scratch[entry_offset];
                        if (first == directory_end) return error.NotFound;
                        if (first == directory_deleted) continue;

                        const attributes = self.scratch[entry_offset + 11];
                        if (attributes == long_name_attributes or attributes & volume_label_attribute != 0) continue;
                        if (!equalName(self.scratch[entry_offset..][0..11], short_name[0..])) continue;
                        if (attributes & directory_attribute != 0) return error.IsDirectory;

                        const high = read16(self.scratch, entry_offset + 20);
                        const low = read16(self.scratch, entry_offset + 26);
                        const first_cluster = (@as(u32, high) << 16 | low) & cluster_mask;
                        const size = read32(self.scratch, entry_offset + 28);
                        if (size != 0 and first_cluster < first_data_cluster) return error.CorruptFilesystem;
                        return .{ .first_cluster = first_cluster, .size = size };
                    }
                }
                cluster = try self.nextCluster(cluster);
            }
        }

        pub fn reader(self: *Self, file: File) !Reader {
            if (file.size != 0 and !self.validCluster(file.first_cluster)) return error.BadCluster;
            return .{
                .volume = self,
                .size = file.size,
                .first_cluster = file.first_cluster,
                .remaining = file.size,
                .cluster = file.first_cluster,
            };
        }

        pub const Reader = struct {
            volume: *Self,
            remaining: u32,
            size: u32,
            first_cluster: u32,
            cluster: u32,
            cluster_offset: u32 = 0,
            position: u32 = 0,

            pub fn read(self: *Reader, output: []u8) !usize {
                if (output.len == 0 or self.remaining == 0) return 0;

                var written: usize = 0;
                while (written < output.len and self.remaining != 0) {
                    const cluster_bytes = @as(u32, self.volume.sectors_per_cluster) * sector_bytes;
                    if (self.cluster_offset == cluster_bytes) {
                        self.cluster = try self.volume.nextCluster(self.cluster);
                        self.cluster_offset = 0;
                    }

                    const sector_in_cluster = self.cluster_offset / sector_bytes;
                    const offset_in_sector: usize = @intCast(self.cluster_offset % sector_bytes);
                    const sector_lba = try self.volume.clusterLba(self.cluster) + sector_in_cluster;
                    const wanted = @min(output.len - written, @as(usize, self.remaining));

                    const destination = @intFromPtr(output.ptr) + written;
                    if (offset_in_sector == 0 and wanted >= sector_bytes and destination & 3 == 0) {
                        const sectors_left = self.volume.sectors_per_cluster - @as(u8, @intCast(sector_in_cluster));
                        const whole_sectors = @min(wanted / sector_bytes, @as(usize, sectors_left));
                        const byte_count = whole_sectors * sector_bytes;
                        try self.volume.device.readBlocks(sector_lba, output[written..][0..byte_count]);
                        self.consume(byte_count);
                        written += byte_count;
                    } else {
                        try self.volume.device.readBlocks(sector_lba, self.volume.scratch);
                        const byte_count = @min(wanted, sector_bytes - offset_in_sector);
                        copy(output[written..][0..byte_count], self.volume.scratch[offset_in_sector..][0..byte_count]);
                        self.consume(byte_count);
                        written += byte_count;
                    }
                }
                return written;
            }

            /// Seek without reading file contents. Forward seeks retain the
            /// current FAT traversal; backwards seeks restart at the first cluster.
            pub fn seekTo(self: *Reader, target: u32) !void {
                if (target > self.size) return error.InvalidSeek;
                const cluster_bytes = @as(u32, self.volume.sectors_per_cluster) * sector_bytes;
                var cluster = if (target >= self.position) self.cluster else self.first_cluster;
                var base = if (target >= self.position) self.position - self.cluster_offset else 0;
                // EOF at a cluster boundary need not traverse a nonexistent link.
                while (@as(u64, base) + cluster_bytes < target or (@as(u64, base) + cluster_bytes == target and target < self.size)) {
                    cluster = try self.volume.nextCluster(cluster);
                    base += cluster_bytes;
                }
                // Publish the new position only after successful FAT traversal.
                self.cluster = cluster;
                self.cluster_offset = target - base;
                self.position = target;
                self.remaining = self.size - target;
            }

            fn consume(self: *Reader, count: usize) void {
                const amount: u32 = @intCast(count);
                self.remaining -= amount;
                self.cluster_offset += amount;
                self.position += amount;
            }
        };

        fn clusterLba(self: Self, cluster: u32) Error!u32 {
            if (!self.validCluster(cluster)) return error.BadCluster;
            const relative = @as(u64, cluster - first_data_cluster) * self.sectors_per_cluster;
            const lba = @as(u64, self.data_lba) + relative;
            if (lba > maximum_lba) return error.CorruptFilesystem;
            return @intCast(lba);
        }

        fn nextCluster(self: *Self, cluster: u32) !u32 {
            return (try self.nextClusterOrEnd(cluster)) orelse error.UnexpectedEndOfChain;
        }

        fn nextClusterOrEnd(self: *Self, cluster: u32) !?u32 {
            if (!self.validCluster(cluster)) return error.BadCluster;
            const fat_offset = @as(u64, cluster) * fat_entry_bytes;
            const fat_sector_offset = fat_offset / sector_bytes;
            if (fat_sector_offset >= self.fat_sectors) return error.CorruptFilesystem;
            const entry_offset: usize = @intCast(fat_offset % sector_bytes);
            try self.device.readBlocks(self.fat_lba + @as(u32, @intCast(fat_sector_offset)), self.scratch);
            const next = read32(self.scratch, entry_offset) & cluster_mask;
            if (next >= end_of_chain) return null;
            if (next == bad_cluster or !self.validCluster(next)) return error.BadCluster;
            return next;
        }

        fn validCluster(self: Self, cluster: u32) bool {
            return cluster >= first_data_cluster and
                @as(u64, cluster) < @as(u64, self.cluster_count) + first_data_cluster;
        }
    };
}

const directory_entry_bytes = 32;
const fat_entry_bytes = 4;
const directory_end = 0x00;
const directory_deleted = 0xe5;
const long_name_attributes = 0x0f;
const volume_label_attribute = 0x08;
const directory_attribute = 0x10;
const long_name_last_entry = 0x40;
const long_name_ordinal_mask = 0x1f;
const long_name_units_per_entry = 13;
const maximum_long_name_entries = 20;
const maximum_long_name_units = maximum_long_name_entries * long_name_units_per_entry;
const long_name_unit_offsets = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
const first_data_cluster = 2;
const minimum_fat32_clusters = 65_525;
const cluster_mask = 0x0fff_ffff;
const bad_cluster = 0x0fff_fff7;
const end_of_chain = 0x0fff_fff8;
const maximum_lba = 0xffff_ffff;

fn looksLikeBootSector(sector: *const [sector_bytes]u8) bool {
    return hasBootSignature(sector) and read16(sector, 11) == sector_bytes and
        isPowerOfTwo(sector[13]) and sector[16] != 0;
}

fn hasBootSignature(sector: *const [sector_bytes]u8) bool {
    return sector[510] == 0x55 and sector[511] == 0xaa;
}

fn firstUsablePartition(sector: *const [sector_bytes]u8) ?usize {
    for (0..4) |index| {
        const offset = 446 + index * 16;
        if (sector[offset + 4] != 0 and read32(sector, offset + 8) != 0 and
            read32(sector, offset + 12) != 0)
        {
            return offset;
        }
    }
    return null;
}

fn validShortName(name: [11]u8) bool {
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn equalName(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn shortNameChecksum(name: []const u8) u8 {
    var checksum: u8 = 0;
    for (name[0..11]) |byte| checksum = ((checksum >> 1) | (checksum << 7)) +% byte;
    return checksum;
}

fn decodeShortName(name: []const u8, output: *[maximum_name_bytes]u8) usize {
    var written: usize = 0;
    var base_end: usize = 8;
    while (base_end != 0 and name[base_end - 1] == ' ') base_end -= 1;
    for (name[0..base_end], 0..) |raw, index| {
        output[written] = if (index == 0 and raw == 0x05) 0xe5 else raw;
        written += 1;
    }
    var extension_end: usize = 11;
    while (extension_end > 8 and name[extension_end - 1] == ' ') extension_end -= 1;
    if (extension_end > 8 and written + 1 < output.len) {
        output[written] = '.';
        written += 1;
        for (name[8..extension_end]) |byte| {
            if (written == output.len) break;
            output[written] = byte;
            written += 1;
        }
    }
    return written;
}

fn encodeLongName(units: []const u16, output: *[maximum_name_bytes]u8) usize {
    var written: usize = 0;
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const first = units[index];
        if (first == 0 or first == 0xffff) break;
        var codepoint: u21 = first;
        if (first >= 0xd800 and first <= 0xdbff) {
            if (index + 1 >= units.len) break;
            const second = units[index + 1];
            if (second < 0xdc00 or second > 0xdfff) break;
            codepoint = 0x10000 + (@as(u21, first - 0xd800) << 10) + (second - 0xdc00);
            index += 1;
        } else if (first >= 0xdc00 and first <= 0xdfff) break;

        const needed: usize = if (codepoint < 0x80) 1 else if (codepoint < 0x800) 2 else if (codepoint < 0x10000) 3 else 4;
        if (written + needed > output.len) break;
        switch (needed) {
            1 => output[written] = @intCast(codepoint),
            2 => {
                output[written] = @intCast(0xc0 | codepoint >> 6);
                output[written + 1] = @intCast(0x80 | codepoint & 0x3f);
            },
            3 => {
                output[written] = @intCast(0xe0 | codepoint >> 12);
                output[written + 1] = @intCast(0x80 | codepoint >> 6 & 0x3f);
                output[written + 2] = @intCast(0x80 | codepoint & 0x3f);
            },
            4 => {
                output[written] = @intCast(0xf0 | codepoint >> 18);
                output[written + 1] = @intCast(0x80 | codepoint >> 12 & 0x3f);
                output[written + 2] = @intCast(0x80 | codepoint >> 6 & 0x3f);
                output[written + 3] = @intCast(0x80 | codepoint & 0x3f);
            },
            else => unreachable,
        }
        written += needed;
    }
    return written;
}

fn isPowerOfTwo(value: u8) bool {
    return value != 0 and value & (value - 1) == 0;
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | @as(u16, bytes[offset + 1]) << 8;
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        @as(u32, bytes[offset + 1]) << 8 |
        @as(u32, bytes[offset + 2]) << 16 |
        @as(u32, bytes[offset + 3]) << 24;
}

fn copy(destination: []u8, source: []const u8) void {
    for (destination, source) |*target, byte| target.* = byte;
}
