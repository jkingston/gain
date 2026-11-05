//! Read-only theme source loading, serviced by the storage owner between UI
//! frames. A failed parse never replaces an already validated rendering plan.
const theme = @import("runtime_theme.zig");
const memory = @import("f20_memory.zig");
const Volume = @import("f20_library.zig").Volume;
var source: [theme.max_source]u8 align(4) = undefined;

pub fn load(volume: *Volume, controller: anytype) void {
    const entry = volume.findPath(".gain/theme.json") catch return;
    const file = entry.file() catch return;
    if (file.size == 0 or file.size > source.len) return;
    var reader = volume.reader(file) catch return;
    var used: usize = 0;
    while (used < file.size) {
        const count = reader.read(source[used..@min(file.size, used + 4096)]) catch return;
        if (count == 0) return;
        used += count;
    }
    controller.loadCustomTheme(source[0..used], memory.theme_scratch.cachedSlice(u8)) catch return;
}
