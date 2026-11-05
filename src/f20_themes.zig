//! Read-only theme source loading, serviced by the storage owner between UI
//! frames. A failed parse never replaces an already validated rendering plan.
const theme = @import("runtime_theme.zig");
const memory = @import("f20_memory.zig");
const Volume = @import("f20_library.zig").Volume;
const health = @import("health.zig");

pub const Result = enum(u32) { not_attempted, missing, read_failed, invalid, ready };

// One summary per mount: no per-frame logging. The error-name CRC remains
// stable across builds whose internal Zig error numbers may differ.
fn failure(stage: Result, cause: anyerror) void {
    health.snapshot.theme_state = @backingInt(stage);
    health.snapshot.theme_error_crc = @import("std").hash.Crc32.hash(@errorName(cause));
}

var source: [theme.max_source]u8 align(4) = undefined;

pub fn load(volume: *Volume, controller: anytype) void {
    health.snapshot.theme_state = @backingInt(Result.not_attempted);
    health.snapshot.theme_source_bytes = 0;
    health.snapshot.theme_error_crc = 0;
    const entry = volume.findPath(".gain/theme.json") catch |cause| {
        failure(.missing, cause);
        return;
    };
    const file = entry.file() catch |cause| {
        failure(.read_failed, cause);
        return;
    };
    if (file.size == 0 or file.size > source.len) {
        failure(.read_failed, error.ThemeTooLarge);
        return;
    }
    var reader = volume.reader(file) catch |cause| {
        failure(.read_failed, cause);
        return;
    };
    const bytes = source[0..file.size];
    readSource(&reader, memory.storage_burst.uncachedSlice(u8)[0..4096], bytes) catch |cause| {
        failure(.read_failed, cause);
        return;
    };
    health.snapshot.theme_source_bytes = @intCast(bytes.len);
    controller.loadCustomTheme(bytes, memory.theme_scratch.cachedSlice(u8)) catch |cause| {
        failure(.invalid, cause);
        return;
    };
    health.snapshot.theme_state = @backingInt(Result.ready);
}

/// Card DMA accepts uncached memory only. Parse from a cached copy after each
/// bounded transfer; the parser never borrows the reusable storage bounce.
fn readSource(reader: anytype, bounce: []u8, output: []u8) !void {
    var used: usize = 0;
    while (used < output.len) {
        const count = try reader.read(bounce[0..@min(bounce.len, output.len - used)]);
        if (count == 0) return error.TruncatedTheme;
        @memcpy(output[used..][0..count], bounce[0..count]);
        used += count;
    }
}

test "theme source reads respect the DMA buffer contract across partial reads" {
    const std = @import("std");
    const Reader = struct {
        dma: [4096]u8 = undefined,
        source: [6000]u8 = undefined,
        at: usize = 0,
        limit: usize = 6000,
        pub fn read(self: *@This(), output: []u8) !usize {
            const first = @intFromPtr(&self.dma);
            const start = @intFromPtr(output.ptr);
            if (start < first or start + output.len > first + self.dma.len) return error.CachedDmaBuffer;
            const count = @min(output.len, 512, self.limit - self.at);
            @memcpy(output[0..count], self.source[self.at..][0..count]);
            self.at += count;
            return count;
        }
    };
    var reader = Reader{};
    for (&reader.source, 0..) |*byte, i| byte.* = @truncate(i);
    var output: [6000]u8 = undefined;
    try std.testing.expectError(error.CachedDmaBuffer, reader.read(&output));
    try readSource(&reader, &reader.dma, &output);
    try std.testing.expectEqualSlices(u8, &reader.source, &output);
    reader.at = 0;
    reader.limit = 5000;
    try std.testing.expectError(error.TruncatedTheme, readSource(&reader, &reader.dma, &output));
}
