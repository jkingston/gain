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
    var used: usize = 0;
    while (used < file.size) {
        const count = reader.read(source[used..@min(file.size, used + 4096)]) catch |cause| {
            failure(.read_failed, cause);
            return;
        };
        if (count == 0) {
            failure(.read_failed, error.TruncatedTheme);
            return;
        }
        used += count;
        health.snapshot.theme_source_bytes = @intCast(used);
    }
    controller.loadCustomTheme(source[0..used], memory.theme_scratch.cachedSlice(u8)) catch |cause| {
        failure(.invalid, cause);
        return;
    };
    health.snapshot.theme_state = @backingInt(Result.ready);
}
