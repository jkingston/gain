//! Bounded exFAT traversal. Allocation and directory mutation belong to the
//! host; firmware may overwrite only already-valid, allocated file sectors.
//! Layout: Microsoft exFAT revision 1.00 specification.
const std = @import("std");
const fat = @import("fat32.zig");

pub const sector_bytes = 512;
const entry_bytes = 32;
const first_cluster = 2;
const end_of_chain = 0xfffffff8;
const bad_cluster = 0xfffffff7;
const dirty_flag = 2;
const media_failure_flag = 4;

fn int(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

pub fn checksum32(sum: u32, value: u8) u32 {
    return std.math.rotr(u32, sum, 1) +% value;
}

pub fn checksum16(sum: u16, value: u8) u16 {
    return std.math.rotr(u16, sum, 1) +% value;
}

pub fn isBoot(bytes: []const u8) bool {
    return bytes.len >= sector_bytes and std.mem.eql(u8, bytes[3..11], "EXFAT   ");
}

pub fn Volume(comptime Device: type) type {
    return struct {
        const Self = @This();
        device: *Device,
        scratch: *[sector_bytes]u8,
        partition_lba: u32,
        partition_sectors: u32,
        sectors_per_cluster: u32,
        fat_lba: u32,
        fat_sectors: u32,
        data_lba: u32,
        root_cluster: u32,
        cluster_count: u32,
        serial: u32,
        flags: u16,
        bitmap_cluster: u32 = 0,
        bitmap_size: u32 = 0,
        upcase_cluster: u32 = 0,
        upcase_size: u32 = 0,
        upcase_checksum: u32 = 0,
        fat_cache_lba: ?u32 = null,
        fat_cache: [sector_bytes]u8 = undefined,
        upcase_index: [256]struct { offset: u32, scalar: u32 } = undefined,
        upcase_cache_lba: ?u32 = null,
        upcase_cache: [512]u8 = undefined,
        writes_active: bool = false,
        writes_failed: bool = false,

        pub fn mount(device: *Device, scratch: *[sector_bytes]u8, start: u32, sectors: u32) !Self {
            // Both boot regions are independently checksummed. A valid backup
            // can recover a damaged main region, but does not permit writes.
            var used_backup = false;
            var self = boot(device, scratch, start, sectors, 0) catch blk: {
                used_backup = true;
                break :blk try boot(device, scratch, start, sectors, 12);
            };
            if (used_backup) self.writes_failed = true;
            var directory = try self.iterate(.{ .first_cluster = self.root_cluster });
            while (try directory.raw()) |entry| {
                switch (entry[0]) {
                    0x81 => {
                        if (self.bitmap_cluster != 0 or entry[1] != 0) return error.CorruptFilesystem;
                        self.bitmap_cluster = int(u32, &entry, 20);
                        const length = int(u64, &entry, 24);
                        if (length < (@as(u64, self.cluster_count) + 7) / 8 or length > std.math.maxInt(u32)) return error.CorruptFilesystem;
                        self.bitmap_size = @intCast(length);
                    },
                    0x82 => {
                        if (self.upcase_cluster != 0) return error.CorruptFilesystem;
                        self.upcase_cluster = int(u32, &entry, 20);
                        const length = int(u64, &entry, 24);
                        if (length == 0 or length > 131072 or length % 2 != 0) return error.CorruptFilesystem;
                        self.upcase_size = @intCast(length);
                        self.upcase_checksum = int(u32, &entry, 4);
                    },
                    else => {},
                }
            }
            if (!self.validCluster(self.bitmap_cluster) or !self.validCluster(self.upcase_cluster)) return error.CorruptFilesystem;
            // Validate before any filename comparison uses the volume mapping.
            var sum: u32 = 0;
            var left = self.upcase_size;
            var cluster = self.upcase_cluster;
            while (left != 0) {
                for (0..self.sectors_per_cluster) |sector| {
                    try device.readBlocks(try self.clusterLba(cluster) + @as(u32, @intCast(sector)), scratch);
                    const count = @min(left, sector_bytes);
                    for (scratch[0..count]) |byte| sum = checksum32(sum, byte);
                    left -= count;
                    if (left == 0) break;
                }
                if (left != 0) cluster = try self.nextCluster(cluster);
            }
            if (sum != self.upcase_checksum) return error.CorruptFilesystem;
            try self.indexUpcase();
            return self;
        }

        fn boot(device: *Device, scratch: *[sector_bytes]u8, start: u32, sectors: u32, region: u32) !Self {
            if (@as(u64, start) + region + 12 > @as(u64, std.math.maxInt(u32)) + 1) return error.InvalidPartition;
            try device.readBlocks(start + region, scratch);
            const b = scratch;
            if (!isBoot(b) or int(u16, b, 510) != 0xaa55 or !std.mem.allEqual(u8, b[11..64], 0)) return error.InvalidBootSector;
            if (b[108] != 9) return error.UnsupportedSectorSize;
            if (b[109] > 16 or b[110] != 1 or int(u16, b, 104) != 0x100) return error.UnsupportedExfat;
            const length = int(u64, b, 72);
            const offset = int(u64, b, 64);
            const fat_offset = int(u32, b, 80);
            const fat_size = int(u32, b, 84);
            const heap = int(u32, b, 88);
            const clusters = int(u32, b, 92);
            const root = int(u32, b, 96);
            const spc = @as(u32, 1) << @intCast(b[109]);
            if (length < 24 or length > sectors or offset != start or clusters == 0 or clusters > 0xfffffff5 or
                fat_offset < 24 or @as(u64, fat_size) * sector_bytes < (@as(u64, clusters) + 2) * 4 or
                heap < @as(u64, fat_offset) + fat_size or @as(u64, heap) + @as(u64, clusters) * spc > length or
                @as(u64, start) + length > @as(u64, std.math.maxInt(u32)) + 1 or root < 2 or root - 2 >= clusters)
                return error.CorruptFilesystem;
            const self = Self{
                .device = device,
                .scratch = scratch,
                .partition_lba = start,
                .partition_sectors = @intCast(length),
                .sectors_per_cluster = spc,
                .fat_lba = start + fat_offset,
                .fat_sectors = fat_size,
                .data_lba = start + heap,
                .root_cluster = root,
                .cluster_count = clusters,
                .serial = int(u32, b, 100),
                .flags = int(u16, b, 106),
            };
            if (self.flags & 0xfff8 != 0 or self.flags & 1 != 0) return error.UnsupportedExfat;
            var sum: u32 = 0;
            for (0..11) |sector| {
                if (sector != 0) try device.readBlocks(start + region + @as(u32, @intCast(sector)), scratch);
                for (scratch, 0..) |byte, at| {
                    if (sector == 0 and (at == 106 or at == 107 or at == 112)) continue;
                    sum = checksum32(sum, byte);
                }
            }
            try device.readBlocks(start + region + 11, scratch);
            for (0..128) |i| if (int(u32, scratch, i * 4) != sum) return error.BootChecksum;
            return self;
        }

        fn upcaseWord(self: *Self, at: u32) !u16 {
            if (at >= self.upcase_size) return error.CorruptFilesystem;
            var cluster = self.upcase_cluster;
            var offset = at;
            const bytes = self.sectors_per_cluster * 512;
            while (offset >= bytes) {
                cluster = try self.nextCluster(cluster);
                offset -= bytes;
            }
            const lba = try self.clusterLba(cluster) + offset / 512;
            if (self.upcase_cache_lba != lba) {
                try self.device.readBlocks(lba, self.scratch);
                self.upcase_cache = self.scratch.*;
                self.upcase_cache_lba = lba;
            }
            return int(u16, &self.upcase_cache, offset % 512);
        }

        fn indexUpcase(self: *Self) !void {
            var at: u32 = 0;
            var scalar: u32 = 0;
            var checkpoint: usize = 0;
            while (scalar < 65536) {
                const before = at;
                const first = scalar;
                const value = try self.upcaseWord(at);
                at += 2;
                if (value == 0xffff and scalar != 0xffff) {
                    const count = try self.upcaseWord(at);
                    at += 2;
                    if (count == 0 or scalar + count > 65536) return error.CorruptFilesystem;
                    // Identity compression cannot override mandatory ASCII case.
                    if (scalar <= 'z' and scalar + count > 'a') return error.CorruptFilesystem;
                    scalar += count;
                } else {
                    if (scalar < 128 and value != std.ascii.toUpper(@intCast(scalar))) return error.CorruptFilesystem;
                    scalar += 1;
                }
                while (checkpoint < 256 and checkpoint * 256 < scalar) : (checkpoint += 1) {
                    self.upcase_index[checkpoint] = .{ .offset = before, .scalar = first };
                }
            }
            if (at != self.upcase_size) return error.CorruptFilesystem;
        }

        fn upper(self: *Self, unit: u16) !u16 {
            if (unit < 128) return std.ascii.toUpper(@intCast(unit));
            const checkpoint = self.upcase_index[unit / 256];
            var scalar = checkpoint.scalar;
            var at = checkpoint.offset;
            while (scalar <= unit) {
                const value = try self.upcaseWord(at);
                at += 2;
                if (value == 0xffff and scalar != 0xffff) {
                    const count = try self.upcaseWord(at);
                    at += 2;
                    if (@as(u32, unit) - scalar < count) return unit;
                    scalar += count;
                } else {
                    if (scalar == unit) return value;
                    scalar += 1;
                }
            }
            return error.CorruptFilesystem;
        }

        pub fn namesEqual(self: *Self, left: []const u8, right: []const u8) !bool {
            if (std.mem.eql(u8, left, right)) return true;
            var lhs: [255]u16 = undefined;
            var rhs: [255]u16 = undefined;
            const l = std.unicode.utf8ToUtf16Le(&lhs, left) catch return false;
            const r = std.unicode.utf8ToUtf16Le(&rhs, right) catch return false;
            if (l != r) return false;
            for (lhs[0..l], rhs[0..r]) |a, b| if (try self.upper(std.mem.littleToNative(u16, a)) != try self.upper(std.mem.littleToNative(u16, b))) return false;
            return true;
        }

        pub fn validCluster(self: *const Self, cluster: u32) bool {
            return cluster >= first_cluster and cluster - first_cluster < self.cluster_count;
        }

        pub fn clusterLba(self: *const Self, cluster: u32) !u32 {
            if (!self.validCluster(cluster)) return error.BadCluster;
            return self.data_lba + (cluster - first_cluster) * self.sectors_per_cluster;
        }

        pub fn nextClusterOrEnd(self: *Self, cluster: u32) !?u32 {
            if (!self.validCluster(cluster)) return error.BadCluster;
            const sector = self.fat_lba + cluster / 128;
            if (self.fat_cache_lba != sector) {
                try self.device.readBlocks(sector, self.scratch);
                self.fat_cache = self.scratch.*;
                self.fat_cache_lba = sector;
            }
            const next = int(u32, &self.fat_cache, (cluster % 128) * 4);
            if (next >= end_of_chain) return null;
            if (next == bad_cluster or !self.validCluster(next)) return error.BadCluster;
            return next;
        }

        pub fn nextCluster(self: *Self, cluster: u32) !u32 {
            return (try self.nextClusterOrEnd(cluster)) orelse error.UnexpectedEndOfChain;
        }

        pub fn iterate(self: *Self, directory: fat.Directory) !DirectoryIterator {
            if (!self.validCluster(directory.first_cluster)) return error.BadCluster;
            return .{ .volume = self, .cluster = directory.first_cluster, .contiguous = directory.contiguous, .remaining = directory.data_length, .anchor = directory.first_cluster };
        }

        pub const DirectoryIterator = struct {
            volume: *Self,
            cluster: u32,
            contiguous: bool,
            remaining: u64,
            sector_index: u32 = 0,
            entry_offset: usize = sector_bytes,
            sector: [sector_bytes]u8 = undefined,
            finished: bool = false,
            anchor: u32,
            power: u32 = 1,
            hops: u32 = 0,

            fn raw(self: *DirectoryIterator) !?[entry_bytes]u8 {
                if (self.finished) return null;
                if (self.entry_offset == sector_bytes) {
                    if (self.remaining == 0) {
                        self.finished = true;
                        return null;
                    }
                    if (self.sector_index == self.volume.sectors_per_cluster) {
                        const following = if (self.contiguous) self.cluster + 1 else (try self.volume.nextClusterOrEnd(self.cluster)) orelse {
                            self.finished = true;
                            return null;
                        };
                        self.hops += 1;
                        if (following == self.anchor) return error.CyclicChain;
                        if (self.hops == self.power) {
                            self.anchor = following;
                            self.power *|= 2;
                            self.hops = 0;
                        }
                        self.cluster = following;
                        self.sector_index = 0;
                    }
                    try self.volume.device.readBlocks(try self.volume.clusterLba(self.cluster) + self.sector_index, self.volume.scratch);
                    self.sector = self.volume.scratch.*;
                    self.sector_index += 1;
                    if (self.remaining != std.math.maxInt(u64)) self.remaining -|= sector_bytes;
                    self.entry_offset = 0;
                }
                const entry = self.sector[self.entry_offset..][0..entry_bytes].*;
                self.entry_offset += entry_bytes;
                if (entry[0] == 0) {
                    self.finished = true;
                    return null;
                }
                return entry;
            }

            pub fn next(self: *DirectoryIterator) !?fat.DirectoryEntry {
                while (try self.raw()) |primary| {
                    if (primary[0] & 0x80 == 0) continue;
                    if (primary[0] != 0x85) {
                        if (primary[0] == 0x81 or primary[0] == 0x82 or primary[0] == 0x83 or primary[0] & 0x20 != 0) continue;
                        return error.UnsupportedDirectoryEntry;
                    }
                    const count = primary[1];
                    if (count < 2) return error.CorruptFilesystem;
                    var sum: u16 = 0;
                    for (primary, 0..) |byte, i| if (i != 2 and i != 3) {
                        sum = checksum16(sum, byte);
                    };
                    const stream = (try self.raw()) orelse return error.CorruptFilesystem;
                    if (stream[0] != 0xc0 or stream[1] & 1 == 0 or stream[1] & 0xfc != 0 or stream[3] == 0) return error.CorruptFilesystem;
                    for (stream) |byte| sum = checksum16(sum, byte);
                    var units: [255]u16 = undefined;
                    const names = (@as(u16, stream[3]) + 14) / 15;
                    if (count < names + 1) return error.CorruptFilesystem;
                    for (0..count - 1) |i| {
                        const part = (try self.raw()) orelse return error.CorruptFilesystem;
                        for (part) |byte| sum = checksum16(sum, byte);
                        if (i < names) {
                            if (part[0] != 0xc1) return error.CorruptFilesystem;
                            for (0..15) |j| {
                                const index = i * 15 + j;
                                if (index < stream[3]) units[index] = int(u16, &part, 2 + j * 2);
                            }
                        } else if (part[0] & 0xe0 != 0xe0) return error.UnsupportedDirectoryEntry;
                    }
                    if (sum != int(u16, &primary, 2)) return error.EntryChecksum;
                    const size = int(u64, &stream, 24);
                    const valid = int(u64, &stream, 8);
                    const cluster = int(u32, &stream, 20);
                    const directory = int(u16, &primary, 4) & 0x10 != 0;
                    const contiguous = stream[1] & 2 != 0;
                    if (valid > size or (size == 0 and cluster != 0) or (size != 0 and !self.volume.validCluster(cluster)) or (directory and (valid != size or size == 0))) return error.CorruptFilesystem;
                    if (contiguous and size != 0 and (size - 1) / (self.volume.sectors_per_cluster * 512) >= self.volume.cluster_count - (cluster - 2)) return error.CorruptFilesystem;
                    // The current media pipeline has 32-bit file offsets. Large
                    // files remain visible to the host and are skipped by Gain.
                    if (size > std.math.maxInt(u32)) continue;
                    var result = fat.DirectoryEntry{ .kind = if (directory) .directory else .file, .first_cluster = cluster, .size = @intCast(size), .attributes = @truncate(int(u16, &primary, 4)), .modified = int(u32, &primary, 12), .contiguous = contiguous, .valid_length = @intCast(valid) };
                    var out: usize = 0;
                    var i: usize = 0;
                    while (i < stream[3]) : (i += 1) {
                        const unit = units[i];
                        var scalar: u21 = unit;
                        if (unit >= 0xd800 and unit <= 0xdbff) {
                            i += 1;
                            if (i >= stream[3] or units[i] < 0xdc00 or units[i] > 0xdfff) return error.InvalidName;
                            scalar = 0x10000 + (@as(u21, unit - 0xd800) << 10) + (units[i] - 0xdc00);
                        } else if (unit >= 0xdc00 and unit <= 0xdfff) return error.InvalidName;
                        if (scalar < 0x20 or scalar == '/' or scalar == '\\') return error.InvalidName;
                        var encoded: [4]u8 = undefined;
                        const n = try std.unicode.utf8Encode(scalar, &encoded);
                        if (out + n > result.name_bytes.len) {
                            out = 0;
                            break;
                        }
                        @memcpy(result.name_bytes[out..][0..n], encoded[0..n]);
                        out += n;
                    }
                    if (out == 0) continue;
                    result.name_length = @intCast(out);
                    return result;
                }
                return null;
            }
        };

        /// Check the allocation bitmap before any fixed-allocation write.
        pub fn allocated(self: *Self, cluster: u32) !bool {
            if (!self.validCluster(cluster)) return error.BadCluster;
            const bit = cluster - 2;
            var current = self.bitmap_cluster;
            var offset = bit / 8;
            const bytes = self.sectors_per_cluster * 512;
            while (offset >= bytes) {
                current = try self.nextCluster(current);
                offset -= bytes;
            }
            try self.device.readBlocks(try self.clusterLba(current) + offset / 512, self.scratch);
            return self.scratch[offset % 512] & (@as(u8, 1) << @intCast(bit % 8)) != 0;
        }

        pub fn beginWrites(self: *Self) !void {
            errdefer self.writes_failed = true;
            if (self.writes_failed or self.flags & (dirty_flag | media_failure_flag) != 0 and !self.writes_active) return error.ReadOnlyFilesystem;
            if (self.writes_active) return;
            self.writes_active = true;
            self.setFlags(self.flags | dirty_flag) catch |failure| {
                self.writes_failed = true;
                return failure;
            };
            try self.device.sync();
        }

        fn setFlags(self: *Self, flags: u16) !void {
            for ([_]u32{ 0, 12 }) |region| {
                try self.device.readBlocks(self.partition_lba + region, self.scratch);
                if (!isBoot(self.scratch)) return error.InvalidBootSector;
                std.mem.writeInt(u16, self.scratch[106..108], flags, .little);
                try self.device.writeBlocks(self.partition_lba + region, self.scratch);
            }
            self.flags = flags;
        }

        pub fn sync(self: *Self) !void {
            errdefer self.writes_failed = true;
            if (self.writes_failed) return error.ReadOnlyFilesystem;
            try self.device.sync();
            if (self.writes_active) {
                self.setFlags(self.flags & ~@as(u16, dirty_flag)) catch |failure| {
                    self.writes_failed = true;
                    return failure;
                };
                try self.device.sync();
                self.writes_active = false;
            }
        }
    };
}
