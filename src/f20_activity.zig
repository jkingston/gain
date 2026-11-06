//! Sole-storage-owner adapter for typed favourites and discovery history.
const activity = @import("listening_activity.zig");
const memory = @import("f20_memory.zig");
const managed = @import("managed_file.zig");
const Volume = @import("f20_library.zig").Volume;

pub const Store = struct {
    file: ?@import("fat32.zig").File = null,
    journal: activity.Journal = .{},
    saved_revision: ?u32 = null,
    disabled: bool = false,
    cancelled: bool = false,
    service: ?@import("f20_player.zig").StorageService = null,

    fn block() *[512]u8 {
        return @ptrCast(memory.storage_burst.uncachedSlice(u8).ptr);
    }

    pub fn load(self: *Store, volume: *Volume, state: *activity.State) void {
        self.* = .{ .service = self.service };
        self.file = managed.open(volume, ".gain/activity.bin", .activity, block()) catch return;
        if (self.file.?.size != activity.allocation_bytes) {
            self.file = null;
            return;
        }
        var raw_reader = volume.reader(self.file.?) catch return;
        var reader = @import("owned_io.zig").wrap(&raw_reader, self.service, &self.cancelled);
        const payload = (self.journal.load(&reader, state.source, memory.session_scratch.cachedSlice(u8), block(), activity.State) catch return) orelse return;
        state.load(payload) catch return;
        self.saved_revision = state.revision;
    }

    pub fn save(self: *Store, volume: *Volume, state: *const activity.State) void {
        self.cancelled = false;
        if (self.disabled or self.saved_revision == state.revision) return;
        const file = self.file orelse return;
        const revision = state.revision;
        const payload = state.capture(memory.session_scratch.cachedSlice(u8)) catch {
            self.disabled = true;
            return;
        };
        var raw_writer = volume.overwrite(file) catch {
            self.disabled = true;
            return;
        };
        var writer = @import("owned_io.zig").wrap(&raw_writer, self.service, &self.cancelled);
        self.journal.save(&writer, state.source, payload, block()) catch {
            if (!self.cancelled) self.disabled = true;
            return;
        };
        self.saved_revision = revision;
    }
};
