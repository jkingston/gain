//! Persistence adapter for a host-provisioned settings journal. The player calls
//! save only from its sole storage owner, or after playback has stopped.
const preferences = @import("preferences.zig");
const managed = @import("managed_file.zig");
const memory = @import("f20_memory.zig");
const Volume = @import("f20_library.zig").Volume;

pub const Store = struct {
    file: ?@import("fat32.zig").File = null,
    journal: preferences.Journal = .{},
    disabled: bool = false,

    fn block() *[512]u8 {
        return @ptrCast(memory.storage_burst.uncachedSlice(u8).ptr);
    }

    pub fn load(self: *Store, volume: *Volume) preferences.Options {
        self.file = managed.open(volume, ".gain/settings.bin", .settings, block()) catch return .{};
        var reader = volume.reader(self.file.?) catch return .{};
        return self.journal.load(&reader, block()) catch .{};
    }

    pub fn save(self: *Store, volume: *Volume, options: preferences.Options) void {
        if (self.disabled) return;
        const file = self.file orelse return;
        var writer = volume.overwrite(file) catch {
            self.disabled = true;
            return;
        };
        self.journal.save(&writer, options, block()) catch {
            // Preserve the other bank and avoid retrying a failing card in the
            // playback loop. The next mount may retry normally.
            self.disabled = true;
        };
    }
};
