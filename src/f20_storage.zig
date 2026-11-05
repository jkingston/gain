const x1000 = @import("x1000.zig");
const board = @import("f20_v27.zig");
const sd = @import("sd.zig");
const builtin = @import("builtin");

pub const Controller = sd.Controller(board.storage);
pub const Waiter = sd.Waiter;
pub const DmaDescriptor = x1000.Msc0.DmaDescriptor;
pub const filesystem = @import("filesystem.zig");
pub const fat32 = @import("fat32.zig");
pub const wav = @import("wav.zig");

pub const Error = error{
    InvalidBounceBuffer,
    InvalidReadAheadBuffer,
};

/// Reads a FAT32 file through caller-owned uncached DMA memory, then copies it
/// into CPU-friendly cached storage. Selecting the bounce offset from the file
/// position keeps every whole-sector transfer four-byte aligned even when a
/// codec's metadata ends at an odd address.
pub fn BufferedReader(comptime Inner: type) type {
    return struct {
        const Self = @This();

        inner: *Inner,
        bounce: []u8,

        pub fn init(inner: *Inner, bounce: []u8) Error!Self {
            const address = @intFromPtr(bounce.ptr);
            if (bounce.len < fat32.sector_bytes + 3 or address & 3 != 0 or
                (comptime builtin.cpu.arch == .mipsel) and !x1000.isUncachedAddress(address))
            {
                return error.InvalidBounceBuffer;
            }
            return .{ .inner = inner, .bounce = bounce };
        }

        pub fn read(self: *Self, output: []u8) !usize {
            var written: usize = 0;
            while (written < output.len) {
                const offset: usize = self.inner.position & 3;
                const wanted = @min(output.len - written, self.bounce.len - offset);
                const count = try self.inner.read(self.bounce[offset..][0..wanted]);
                if (count == 0) break;
                @memcpy(output[written..][0..count], self.bounce[offset..][0..count]);
                written += count;
                if (count != wanted) break;
            }
            return written;
        }
    };
}

/// Keeps two ordered chunks of a FAT32 file in caller-owned uncached memory.
/// `prefetch` performs SD work ahead of a real-time refill; `read` falls back
/// to filling the queue synchronously so parsing and startup remain simple.
pub fn ReadAheadReader(comptime Inner: type) type {
    return struct {
        const Self = @This();
        const slot_count = 2;

        inner: *Inner,
        buffers: [slot_count][]u8,
        starts: [slot_count]usize = @splat(0),
        ends: [slot_count]usize = @splat(0),
        head: u1 = 0,
        queued: u2 = 0,
        end_of_input: bool = false,

        pub fn init(inner: *Inner, buffers: [slot_count][]u8) Error!Self {
            for (buffers) |buffer| {
                const address = @intFromPtr(buffer.ptr);
                if (buffer.len < fat32.sector_bytes + 3 or address & 3 != 0 or
                    (comptime builtin.cpu.arch == .mipsel) and !x1000.isUncachedAddress(address))
                {
                    return error.InvalidReadAheadBuffer;
                }
            }
            const first_start = @intFromPtr(buffers[0].ptr);
            const first_end = first_start + buffers[0].len;
            const second_start = @intFromPtr(buffers[1].ptr);
            const second_end = second_start + buffers[1].len;
            if (first_start < second_end and second_start < first_end) {
                return error.InvalidReadAheadBuffer;
            }
            return .{ .inner = inner, .buffers = buffers };
        }

        pub fn prefetch(self: *Self) !void {
            while (self.queued < slot_count and !self.end_of_input) {
                const slot = (@as(usize, self.head) + self.queued) % slot_count;
                const offset: usize = self.inner.position & 3;
                const buffer = self.buffers[slot];
                const count = try self.inner.read(buffer[offset..]);
                if (count == 0) {
                    self.end_of_input = true;
                    break;
                }
                self.starts[slot] = offset;
                self.ends[slot] = offset + count;
                self.queued += 1;
            }
        }

        pub fn read(self: *Self, output: []u8) !usize {
            var written: usize = 0;
            while (written < output.len) {
                if (self.queued == 0) {
                    try self.prefetch();
                    if (self.queued == 0) break;
                }
                const slot: usize = self.head;
                const available = self.ends[slot] - self.starts[slot];
                const count = @min(output.len - written, available);
                @memcpy(
                    output[written..][0..count],
                    self.buffers[slot][self.starts[slot]..][0..count],
                );
                written += count;
                self.starts[slot] += count;
                if (self.starts[slot] == self.ends[slot]) {
                    self.starts[slot] = 0;
                    self.ends[slot] = 0;
                    self.head = @intCast((@as(usize, self.head) + 1) % slot_count);
                    self.queued -= 1;
                }
            }
            return written;
        }

        pub fn seekTo(self: *Self, position: u32) !void {
            try self.inner.seekTo(position);
            self.starts = @splat(0);
            self.ends = @splat(0);
            self.head = 0;
            self.queued = 0;
            self.end_of_input = false;
        }

        pub fn bufferedBytes(self: Self) usize {
            var bytes: usize = 0;
            for (0..self.queued) |queued_index| {
                const slot = (@as(usize, self.head) + queued_index) % slot_count;
                bytes += self.ends[slot] - self.starts[slot];
            }
            return bytes;
        }
    };
}

test "read-ahead separates source reads from consumer reads" {
    const std = @import("std");

    const Source = struct {
        bytes: []const u8,
        position: usize = 0,
        reads: usize = 0,

        pub fn read(self: *@This(), output: []u8) !usize {
            const count = @min(output.len, self.bytes.len - self.position);
            @memcpy(output[0..count], self.bytes[self.position..][0..count]);
            self.position += count;
            self.reads += 1;
            return count;
        }
    };

    var expected: [2_048]u8 = undefined;
    for (&expected, 0..) |*byte, index| byte.* = @truncate(index);
    var source = Source{ .bytes = &expected };
    var first: [515]u8 align(4) = undefined;
    var second: [515]u8 align(4) = undefined;
    var reader = try ReadAheadReader(Source).init(&source, .{ &first, &second });

    try reader.prefetch();
    try std.testing.expectEqual(@as(usize, 2), source.reads);
    var actual: [800]u8 = undefined;
    try std.testing.expectEqual(actual.len, try reader.read(&actual));
    try std.testing.expectEqual(@as(usize, 2), source.reads);
    try std.testing.expectEqualSlices(u8, expected[0..actual.len], &actual);

    try reader.prefetch();
    try std.testing.expect(source.reads > 2);
    try std.testing.expect(reader.bufferedBytes() != 0);

    var remaining: [expected.len - actual.len]u8 = undefined;
    try std.testing.expectEqual(remaining.len, try reader.read(&remaining));
    try std.testing.expectEqualSlices(u8, expected[actual.len..], &remaining);
    var end: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try reader.read(&end));
}

test "read-ahead rejects overlapping buffers" {
    const std = @import("std");

    const Source = struct {
        position: usize = 0,

        pub fn read(_: *@This(), _: []u8) !usize {
            return 0;
        }
    };

    var source = Source{};
    var storage: [1_028]u8 align(4) = undefined;
    try std.testing.expectError(
        error.InvalidReadAheadBuffer,
        ReadAheadReader(Source).init(&source, .{ storage[0..515], storage[512..1_027] }),
    );
}

test "catalogue scalar reads require bulk IO rather than one transaction per field" {
    const std = @import("std");

    const Source = struct {
        position: usize = 0,
        reads: usize = 0,

        pub fn read(self: *@This(), output: []u8) !usize {
            self.reads += 1;
            const count = @min(output.len, 1024 * 1024 - self.position);
            for (output[0..count], self.position..) |*byte, index| byte.* = @truncate(index);
            self.position += count;
            return count;
        }
    };

    var source: Source = .{};
    var first: [32 * 1024]u8 align(4) = undefined;
    var second: [32 * 1024]u8 align(4) = undefined;
    var reader = try ReadAheadReader(Source).init(&source, .{ &first, &second });
    var scalar: [4]u8 = undefined;
    for (0..1024 * 1024 / scalar.len) |index| {
        try std.testing.expectEqual(scalar.len, try reader.read(&scalar));
        for (scalar, 0..) |byte, offset| try std.testing.expectEqual(@as(u8, @truncate(index * scalar.len + offset)), byte);
    }
    try std.testing.expectEqual(32, source.reads);
    try std.testing.expectEqual(0, try reader.read(&scalar));
}

test "read-ahead seeking flushes stale prefetched bytes and reopens EOF" {
    const std = @import("std");

    const Source = struct {
        position: usize = 0,

        pub fn read(self: *@This(), output: []u8) !usize {
            const count = @min(output.len, 2000 - self.position);
            for (output[0..count], self.position..) |*byte, index| byte.* = @truncate(index);
            self.position += count;
            return count;
        }

        pub fn seekTo(self: *@This(), target: u32) !void {
            if (target > 2000) return error.InvalidSeek;
            self.position = target;
        }
    };

    var source = Source{};
    var first: [516]u8 align(4) = undefined;
    var second: [516]u8 align(4) = undefined;
    var reader = try ReadAheadReader(Source).init(&source, .{ &first, &second });
    try reader.prefetch();
    for ([_]u32{ 1600, 1998, 2000, 1, 1000, 0 }) |position| {
        try reader.seekTo(position);
        try std.testing.expectEqual(@as(usize, 0), reader.bufferedBytes());
        var output: [17]u8 = undefined;
        const count = try reader.read(&output);
        for (output[0..count], position..) |value, expected| try std.testing.expectEqual(@as(u8, @truncate(expected)), value);
    }
}
