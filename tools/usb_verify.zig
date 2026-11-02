//! Cooperative, bounded independent file readback for USB qualification.
//! Reader I/O uses uncached memory; checksum work uses a separate cached copy.
const std = @import("std");

pub const Result = struct { bytes: u32 = 0, checksum: u32 = 2166136261 };

pub fn verify(reader: anytype, io: []u8, cached: []u8, expected: u32, observer: anytype) !Result {
    if (io.len == 0 or cached.len < io.len) return error.InvalidVerifyBuffer;
    var result: Result = .{};
    while (true) {
        try observer.poll(result.bytes);
        const count = try reader.read(io);
        if (count > io.len or count > expected - result.bytes) return error.UnexpectedFileSize;
        if (count == 0) {
            if (result.bytes != expected) return error.TruncatedFile;
            return result;
        }
        @memcpy(cached[0..count], io[0..count]);
        for (cached[0..count]) |byte| result.checksum = (result.checksum ^ byte) *% 16777619;
        result.bytes += @intCast(count);
    }
}

test "large readback services progress throughout a deterministic slow reader" {
    const Reader = struct {
        position: u32 = 0,
        clock: u32 = 0,

        fn read(self: *@This(), out: []u8) !usize {
            const n = @min(out.len, 64 * 1024 * 1024 - self.position);
            for (out[0..n], self.position..) |*byte, i| byte.* = @truncate(i * 73 + i / 11);
            self.position += @intCast(n);
            self.clock += 30; // A whole verification exceeds the 20 s watchdog.
            return n;
        }
    };

    const Observer = struct {
        reader: *Reader,
        previous: u32 = 0,
        polls: usize = 0,

        fn poll(self: *@This(), progress: u32) !void {
            try std.testing.expectEqual(self.reader.position, progress);
            try std.testing.expect(self.reader.clock - self.previous <= 30);
            self.previous = self.reader.clock;
            self.polls += 1;
        }
    };

    var reader: Reader = .{};
    var observer = Observer{ .reader = &reader };
    var io: [32768]u8 = undefined;
    var cached: [32768]u8 = undefined;
    const result = try verify(&reader, &io, &cached, 64 * 1024 * 1024, &observer);
    try std.testing.expectEqual(64 * 1024 * 1024, result.bytes);
    try std.testing.expectEqual(2049, observer.polls);
    try std.testing.expect(reader.clock > 20_000);
}

test "verification propagates cancellation and rejects truncated or oversized input" {
    const Reader = struct {
        remaining: usize,

        fn read(self: *@This(), out: []u8) !usize {
            const n = @min(out.len, self.remaining);
            @memset(out[0..n], 'a');
            self.remaining -= n;
            return n;
        }
    };

    const Observer = struct {
        cancel: bool = false,

        fn poll(self: *@This(), _: u32) !void {
            if (self.cancel) return error.Cancelled;
        }
    };

    var io: [8]u8 = undefined;
    var cached: [8]u8 = undefined;
    var observer: Observer = .{};
    var reader = Reader{ .remaining = 1 };
    try std.testing.expectEqual(@as(u32, 0xe40c292c), (try verify(&reader, &io, &cached, 1, &observer)).checksum);
    reader.remaining = 1;
    try std.testing.expectError(error.TruncatedFile, verify(&reader, &io, &cached, 2, &observer));
    reader.remaining = 3;
    try std.testing.expectError(error.UnexpectedFileSize, verify(&reader, &io, &cached, 2, &observer));
    reader.remaining = 5;
    observer.cancel = true;
    try std.testing.expectError(error.Cancelled, verify(&reader, &io, &cached, 2, &observer));
    try std.testing.expectEqual(5, reader.remaining);
}
