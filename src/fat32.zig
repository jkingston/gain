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
    UnexpectedEndOfChain,
    BadCluster,
};

pub const File = struct {
    first_cluster: u32,
    size: u32,
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
                .remaining = file.size,
                .cluster = file.first_cluster,
            };
        }

        pub const Reader = struct {
            volume: *Self,
            remaining: u32,
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
            if (!self.validCluster(cluster)) return error.BadCluster;
            const fat_offset = @as(u64, cluster) * fat_entry_bytes;
            const fat_sector_offset = fat_offset / sector_bytes;
            if (fat_sector_offset >= self.fat_sectors) return error.CorruptFilesystem;
            const entry_offset: usize = @intCast(fat_offset % sector_bytes);
            try self.device.readBlocks(self.fat_lba + @as(u32, @intCast(fat_sector_offset)), self.scratch);
            const next = read32(self.scratch, entry_offset) & cluster_mask;
            if (next >= end_of_chain) return error.UnexpectedEndOfChain;
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
