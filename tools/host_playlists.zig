//! Saved-queue adapter owned by the player app, independent of gain-sim.
const std = @import("std");
const gain = @import("gain_ui");
const playlists = gain.saved_playlists;

pub const Store = struct {
    file: @import("host_owned_file.zig").File = .{},
    value: playlists.Store = .{},
    disabled: bool = false,
    block: [512]u8 align(4) = undefined,

    pub fn open(self: *Store, root: ?[]const u8, io: std.Io, source: u64, read_only: bool, scratch: []u8) void {
        self.* = .{};
        if (!self.file.open(root, io, read_only, "playlists.bin", .playlists, playlists.allocation_bytes, &self.block)) return;
        for (0..playlists.slots) |slot| _ = self.load(slot, source, scratch);
    }

    pub fn load(self: *Store, slot: usize, source: u64, scratch: []u8) ?playlists.Data {
        if (self.disabled) return null;
        var reader = self.file.cursor() orelse return null;
        return self.value.load(&reader, slot, source, scratch, &self.block) catch {
            self.disabled = true;
            return null;
        };
    }

    pub fn save(self: *Store, slot: usize, queue: anytype, source: u64, scratch: []u8) bool {
        if (self.disabled or self.file.read_only) return false;
        var writer = self.file.cursor() orelse return false;
        const data = playlists.capture(queue, source, scratch) catch return false;
        self.value.save(&writer, slot, data, &self.block) catch {
            self.disabled = true;
            return false;
        };
        return true;
    }

    pub fn close(self: *Store) void {
        self.file.close();
    }
};
