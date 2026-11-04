//! Sparse, read-only FAT seek checkpoints. One owner extends the index lazily;
//! warm random seeks traverse at most one stride, regardless of file length.
const std = @import("std");
pub const stride = 64;
pub const capacity = 4096;
pub const maximum_bytes = 128 * 1024 * 1024;

pub const Index = struct {
    clusters: [capacity]u32 = undefined,
    count: usize = 0,
    first: u32 = 0,
    size: u32 = 0,
    cluster_bytes: u32 = 0,

    pub fn reset(self: *Index) void {
        self.count = 0;
        self.first = 0;
        self.size = 0;
        self.cluster_bytes = 0;
    }

    pub fn seek(self: *Index, reader: anytype, target: u32, cluster_bytes: u32, observer: anytype) !void {
        if (reader.size > maximum_bytes or target > reader.size or cluster_bytes < 512 or !std.math.isPowerOfTwo(cluster_bytes)) return error.InvalidSeek;
        if (self.count == 0 or self.first != reader.first_cluster or self.size != reader.size or self.cluster_bytes != cluster_bytes) {
            self.first = reader.first_cluster;
            self.size = reader.size;
            self.cluster_bytes = cluster_bytes;
            self.clusters[0] = reader.first_cluster;
            self.count = 1;
        }
        // EOF at an exact cluster boundary belongs to the preceding cluster;
        // there may be no next FAT link to index.
        const position = if (target == reader.size and target != 0) target - 1 else target;
        const wanted = position / cluster_bytes / stride;
        if (wanted >= capacity) return error.InvalidSeek;
        while (self.count <= wanted) {
            if (observer.cancelled()) return error.Cancelled;
            self.restore(reader, self.count - 1);
            try reader.seekTo(@intCast(self.count * stride * cluster_bytes));
            self.clusters[self.count] = reader.cluster;
            self.count += 1;
        }
        if (observer.cancelled()) return error.Cancelled;
        self.restore(reader, wanted);
        try reader.seekTo(target);
    }

    fn restore(self: *const Index, reader: anytype, anchor: usize) void {
        const position: u32 = @intCast(anchor * stride * self.cluster_bytes);
        reader.cluster = self.clusters[anchor];
        reader.cluster_offset = 0;
        reader.position = position;
        reader.remaining = reader.size - position;
    }
};

test "fragmented random seeks are bounded after lazy indexing and cancellation can resume" {
    const Reader = struct {
        first_cluster: u32 = 7,
        size: u32 = maximum_bytes,
        position: u32 = 0,
        remaining: u32 = maximum_bytes,
        cluster: u32 = 7,
        cluster_offset: u32 = 0,
        steps: usize = 0,
        pub fn seekTo(self: *@This(), target: u32) !void {
            if (target > self.size) return error.InvalidSeek;
            const logical = if (target == self.size) (target - 1) / 512 else target / 512;
            const current = (self.position - self.cluster_offset) / 512;
            self.steps += logical - current;
            // Model a non-contiguous chain; no arithmetic on physical cluster
            // numbers is allowed in the production checkpoint implementation.
            self.cluster = logical *% 31337 +% self.first_cluster;
            self.position = target;
            self.cluster_offset = target - logical * 512;
            self.remaining = self.size - target;
        }
    };
    const Observer = struct {
        remaining: usize = std.math.maxInt(usize),
        pub fn cancelled(self: *@This()) bool {
            if (self.remaining == 0) return true;
            self.remaining -= 1;
            return false;
        }
    };
    var index: Index = .{};
    var reader: Reader = .{};
    var observer: Observer = .{ .remaining = 3 };
    try std.testing.expectError(error.Cancelled, index.seek(&reader, maximum_bytes - 1, 512, &observer));
    try std.testing.expectEqual(@as(usize, 4), index.count);
    observer.remaining = std.math.maxInt(usize);
    try index.seek(&reader, maximum_bytes, 512, &observer);
    try std.testing.expectEqual(@as(usize, capacity), index.count);
    var random = std.Random.DefaultPrng.init(0x5345454b);
    for (0..5000) |_| {
        const at = random.random().uintLessThan(u32, maximum_bytes);
        reader = .{};
        try index.seek(&reader, at, 512, &observer);
        try std.testing.expect(reader.steps < stride);
        try std.testing.expectEqual(at, reader.position);
        try std.testing.expectEqual(at / 512 *% 31337 +% reader.first_cluster, reader.cluster);
    }
    reader = .{ .first_cluster = 99, .size = 8192, .remaining = 8192 };
    try index.seek(&reader, 1024, 512, &observer);
    try std.testing.expectEqual(@as(usize, 1), index.count);
    try std.testing.expectEqual(@as(u32, 99), index.clusters[0]);
}

test "indexed random reads match a fragmented production FAT chain" {
    const fat = @import("fat32.zig");
    const Device = struct {
        links: [1026]u32 = @splat(0),
        logical: [1026]u32 = @splat(0),
        fat_reads: usize = 0,

        fn physical(index: u32) u32 {
            return 2 + (index * 617) % 1024;
        }

        pub fn readBlocks(self: *@This(), lba: u32, output: []u8) !void {
            if (output.len % 512 != 0) return error.InvalidRead;
            for (0..output.len / 512) |sector| {
                const block = lba + @as(u32, @intCast(sector));
                const row = output[sector * 512 ..][0..512];
                if (block < 9) {
                    self.fat_reads += 1;
                    for (0..128) |entry| {
                        const index = block * 128 + entry;
                        std.mem.writeInt(u32, row[entry * 4 ..][0..4], if (index < self.links.len) self.links[index] else 0, .little);
                    }
                } else {
                    if (block < 16 or block >= 1040) return error.InvalidRead;
                    const logical = self.logical[block - 16 + 2];
                    for (row, 0..) |*byte, at| byte.* = @truncate(logical * 31 + at);
                }
            }
        }
    };
    var device: Device = .{};
    for (0..1024) |i| {
        const logical: u32 = @intCast(i);
        const physical = Device.physical(logical);
        device.links[physical] = if (i + 1 == 1024) 0x0fffffff else Device.physical(logical + 1);
        device.logical[physical] = logical;
    }
    var scratch: [512]u8 = undefined;
    var volume = fat.Volume(Device){ .device = &device, .scratch = &scratch, .partition_lba = 0, .partition_sectors = 1040, .sectors_per_cluster = 1, .fat_lba = 0, .fat_sectors = 9, .data_lba = 16, .root_cluster = 2, .cluster_count = 1024 };
    const file = fat.File{ .first_cluster = 2, .size = 1024 * 512 };
    var index: Index = .{};
    const Observer = struct {
        pub fn cancelled(_: @This()) bool {
            return false;
        }
    };
    var reader = try volume.reader(file);
    try index.seek(&reader, file.size, 512, Observer{});
    var random = std.Random.DefaultPrng.init(0x464154);
    for (0..1000) |_| {
        const at = random.random().uintLessThan(u32, file.size);
        reader = try volume.reader(file);
        const before = device.fat_reads;
        try index.seek(&reader, at, 512, Observer{});
        try std.testing.expect(device.fat_reads - before < stride);
        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try reader.read(&byte));
        try std.testing.expectEqual(@as(u8, @truncate((at / 512) * 31 + at % 512)), byte[0]);
    }
}
