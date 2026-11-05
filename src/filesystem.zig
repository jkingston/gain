//! Mount-local file handles for FAT32 and exFAT. Both filesystems are immutable
//! except for aligned overwrites of existing allocations under device ownership.
const std = @import("std");
const fat = @import("fat32.zig");
const exfat = @import("exfat.zig");
pub const sector_bytes = fat.sector_bytes;
pub const File = fat.File;
pub const Directory = fat.Directory;
pub const DirectoryEntry = fat.DirectoryEntry;
pub const EntryKind = fat.EntryKind;
pub const maximum_name_bytes = fat.maximum_name_bytes;
pub const Kind = enum { fat32, exfat };

pub fn Volume(comptime Device: type) type {
    return struct {
        const Self = @This();
        const Fat = fat.Volume(Device);
        const Exfat = exfat.Volume(Device);
        inner: union(Kind) { fat32: Fat, exfat: Exfat },
        device: *Device,
        scratch: *[sector_bytes]u8,
        serial: u32,
        sectors_per_cluster: u32,

        pub fn mount(device: *Device, scratch: *[sector_bytes]u8) !Self {
            const partition = try @import("partition.zig").locate(device, scratch);
            const start = partition.start;
            const sectors = partition.sectors;
            try device.readBlocks(start, scratch);
            if (exfat.isBoot(scratch)) {
                const value = try Exfat.mount(device, scratch, start, sectors);
                return .{ .inner = .{ .exfat = value }, .device = device, .scratch = scratch, .serial = value.serial, .sectors_per_cluster = value.sectors_per_cluster };
            }
            const value = try Fat.mountAt(device, scratch, start, sectors);
            return .{ .inner = .{ .fat32 = value }, .device = device, .scratch = scratch, .serial = value.serial, .sectors_per_cluster = value.sectors_per_cluster };
        }

        pub fn kind(self: *const Self) Kind {
            return std.meta.activeTag(self.inner);
        }

        pub fn rootDirectory(self: *const Self) Directory {
            return switch (self.inner) {
                .fat32 => |value| value.rootDirectory(),
                .exfat => |value| .{ .first_cluster = value.root_cluster },
            };
        }

        pub const DirectoryIterator = union(Kind) {
            fat32: Fat.DirectoryIterator,
            exfat: Exfat.DirectoryIterator,
            pub fn next(self: *DirectoryIterator) !?DirectoryEntry {
                return switch (self.*) {
                    inline else => |*value| value.next(),
                };
            }
        };

        pub fn iterate(self: *Self, directory: Directory) !DirectoryIterator {
            return switch (self.inner) {
                .fat32 => |*value| .{ .fat32 = try value.iterate(directory) },
                .exfat => |*value| .{ .exfat = try value.iterate(directory) },
            };
        }

        pub fn findPath(self: *Self, path: []const u8) !DirectoryEntry {
            var parts = std.mem.tokenizeScalar(u8, path, '/');
            var directory = self.rootDirectory();
            var result: ?DirectoryEntry = null;
            while (parts.next()) |part| {
                if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidName;
                var iterator = try self.iterate(directory);
                result = null;
                while (try iterator.next()) |entry| {
                    if (if (self.inner == .exfat) try self.inner.exfat.namesEqual(entry.name(), part) else std.ascii.eqlIgnoreCase(entry.name(), part)) {
                        result = entry;
                        break;
                    }
                }
                const entry = result orelse return error.NotFound;
                if (parts.peek() != null) directory = try entry.directory();
            }
            return result orelse error.NotFound;
        }

        pub fn findRoot(self: *Self, name: [11]u8) !File {
            var buffer: [12]u8 = undefined;
            const base = std.mem.trimEnd(u8, name[0..8], " ");
            const extension = std.mem.trimEnd(u8, name[8..11], " ");
            const text = try std.fmt.bufPrint(&buffer, if (extension.len == 0) "{s}{s}" else "{s}.{s}", .{ base, extension });
            return (try self.findPath(text)).file();
        }

        fn clusterLba(self: *Self, cluster: u32) !u32 {
            return switch (self.inner) {
                inline else => |*value| value.clusterLba(cluster),
            };
        }
        fn nextCluster(self: *Self, cluster: u32) !u32 {
            return switch (self.inner) {
                inline else => |*value| value.nextCluster(cluster),
            };
        }
        fn validCluster(self: *Self, cluster: u32) bool {
            return switch (self.inner) {
                inline else => |*value| value.validCluster(cluster),
            };
        }

        pub fn reader(self: *Self, file: File) !Reader {
            if (file.size != 0 and !self.validCluster(file.first_cluster)) return error.BadCluster;
            return .{ .volume = self, .size = file.size, .valid_length = @min(file.valid_length, file.size), .first_cluster = file.first_cluster, .remaining = file.size, .cluster = file.first_cluster, .contiguous = file.contiguous };
        }
        pub const Reader = struct {
            volume: *Self,
            contiguous: bool = false,
            valid_length: u32,
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
                        self.cluster = try self.advance(self.cluster);
                        self.cluster_offset = 0;
                    }

                    const sector_in_cluster = self.cluster_offset / sector_bytes;
                    const offset_in_sector: usize = @intCast(self.cluster_offset % sector_bytes);
                    const sector_lba = try self.volume.clusterLba(self.cluster) + sector_in_cluster;
                    if (self.position >= self.valid_length) {
                        const count = @min(output.len - written, self.remaining);
                        @memset(output[written..][0..count], 0);
                        // Advance through allocation on later calls via seekTo;
                        // undefined on-disk bytes are never returned to callers.
                        try self.seekTo(self.position + @as(u32, @intCast(count)));
                        written += count;
                        continue;
                    }
                    const wanted = @min(output.len - written, @as(usize, self.remaining), self.valid_length - self.position);

                    const destination = @intFromPtr(output.ptr) + written;
                    if (offset_in_sector == 0 and wanted >= sector_bytes and destination & 3 == 0) {
                        const sectors_left = self.volume.sectors_per_cluster - sector_in_cluster;
                        const whole_sectors = @min(wanted / sector_bytes, @as(usize, sectors_left));
                        const byte_count = whole_sectors * sector_bytes;
                        try self.volume.device.readBlocks(sector_lba, output[written..][0..byte_count]);
                        self.consume(byte_count);
                        written += byte_count;
                    } else {
                        try self.volume.device.readBlocks(sector_lba, self.volume.scratch);
                        const byte_count = @min(wanted, sector_bytes - offset_in_sector);
                        @memcpy(output[written..][0..byte_count], self.volume.scratch[offset_in_sector..][0..byte_count]);
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
                if (self.contiguous) {
                    const logical = if (target == self.size and target != 0) (target - 1) / cluster_bytes else target / cluster_bytes;
                    cluster = self.first_cluster + logical;
                    if (self.size != 0 and !self.volume.validCluster(cluster)) return error.BadCluster;
                    base = logical * cluster_bytes;
                }
                // EOF at a cluster boundary need not traverse a nonexistent link.
                while (@as(u64, base) + cluster_bytes < target or (@as(u64, base) + cluster_bytes == target and target < self.size)) {
                    cluster = try self.advance(cluster);
                    base += cluster_bytes;
                }
                // Publish the new position only after successful FAT traversal.
                self.cluster = cluster;
                self.cluster_offset = target - base;
                self.position = target;
                self.remaining = self.size - target;
            }

            fn advance(self: *Reader, cluster: u32) !u32 {
                if (!self.contiguous) return self.volume.nextCluster(cluster);
                const next = cluster + 1;
                if (!self.volume.validCluster(next)) return error.BadCluster;
                return next;
            }

            fn consume(self: *Reader, count: usize) void {
                const amount: u32 = @intCast(count);
                self.remaining -= amount;
                self.cluster_offset += amount;
                self.position += amount;
            }
        };

        pub fn overwrite(self: *Self, file: File) !Overwrite {
            if (file.size == 0 or file.size % 512 != 0 or (@min(file.valid_length, file.size)) != file.size) return error.InvalidWrite;
            return .{ .cursor = try self.reader(file) };
        }
        pub const Overwrite = struct {
            cursor: Reader,
            pub fn seekTo(self: *Overwrite, at: u32) !void {
                if (at % 512 != 0) return error.InvalidWrite;
                try self.cursor.seekTo(at);
            }
            pub fn write(self: *Overwrite, input: []const u8) !void {
                if (input.len == 0 or input.len % 512 != 0 or input.len > self.cursor.remaining or @intFromPtr(input.ptr) & 3 != 0) return error.InvalidWrite;
                const volume = self.cursor.volume;
                if (volume.inner == .exfat) try volume.inner.exfat.beginWrites();
                errdefer if (volume.inner == .exfat) {
                    volume.inner.exfat.writes_failed = true;
                };
                const bytes = volume.sectors_per_cluster * 512;
                var done: usize = 0;
                while (done < input.len) {
                    if (self.cursor.cluster_offset == bytes) {
                        self.cursor.cluster = try self.cursor.advance(self.cursor.cluster);
                        self.cursor.cluster_offset = 0;
                    }
                    if (volume.inner == .exfat and !try volume.inner.exfat.allocated(self.cursor.cluster)) return error.UnallocatedCluster;
                    const count = @min(input.len - done, bytes - self.cursor.cluster_offset);
                    const lba = try volume.clusterLba(self.cursor.cluster) + self.cursor.cluster_offset / 512;
                    try volume.device.writeBlocks(lba, input[done..][0..count]);
                    self.cursor.consume(count);
                    done += count;
                }
            }
            pub fn sync(self: *Overwrite) !void {
                const volume = self.cursor.volume;
                if (volume.inner == .exfat) return volume.inner.exfat.sync();
                try volume.device.sync();
            }
        };
    };
}

fn word(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
