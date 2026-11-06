//! Storage-owner adapter for internally saved listening queues.
const playlists = @import("saved_playlists.zig");
const memory = @import("f20_memory.zig");
const managed = @import("managed_file.zig");
const Queue = @import("play_queue.zig").Queue;
const interrupts = @import("x1000.zig").Interrupts;
const Volume = @import("f20_library.zig").Volume;

fn headerSnapshot(queue: *const Queue) Queue {
    const status = interrupts.disableCpu();
    defer interrupts.restoreCpu(status);
    return queue.*;
}

fn unchanged(queue: *const Queue, revision: u32) bool {
    const status = interrupts.disableCpu();
    defer interrupts.restoreCpu(status);
    return queue.revision == revision;
}

pub const Store = struct {
    file: ?@import("fat32.zig").File = null,
    value: playlists.Store = .{},
    disabled: bool = false,
    cancelled: bool = false,
    service: ?@import("f20_player.zig").StorageService = null,

    fn block() *[512]u8 {
        return @ptrCast(memory.storage_burst.uncachedSlice(u8).ptr);
    }

    pub fn open(self: *Store, volume: *Volume, source: u64) void {
        self.* = .{ .service = self.service };
        self.file = managed.open(volume, ".gain/playlists.bin", .playlists, block()) catch return;
        if (self.file.?.size != playlists.allocation_bytes) {
            self.file = null;
            return;
        }
        for (0..playlists.slots) |slot| {
            _ = self.load(volume, slot, source);
            if (self.cancelled) return;
        }
    }

    /// The returned IDs borrow shared scratch and must be consumed before
    /// another storage job. Loading a playlist never mutates the active queue.
    pub fn load(self: *Store, volume: *Volume, slot: usize, source: u64) ?playlists.Data {
        if (self.disabled) return null;
        const file = self.file orelse return null;
        self.cancelled = false;
        var raw_reader = volume.reader(file) catch return null;
        var reader = @import("owned_io.zig").wrap(&raw_reader, self.service, &self.cancelled);
        return self.value.load(&reader, slot, source, memory.session_scratch.cachedSlice(u8), block()) catch {
            if (!self.cancelled) self.disabled = true;
            return null;
        };
    }

    /// Validate an interruptible queue copy before writing. The returned
    /// summary count belongs to the saved snapshot, not a newer live queue.
    pub fn save(self: *Store, volume: *Volume, slot: usize, queue: *const Queue, expected_revision: u32, source: u64) bool {
        self.cancelled = false;
        if (self.disabled) return false;
        const file = self.file orelse return false;
        const header = headerSnapshot(queue);
        if (header.revision != expected_revision) {
            self.cancelled = true;
            return false;
        }
        const captured = playlists.capture(header, source, memory.session_scratch.cachedSlice(u8));
        if (!unchanged(queue, expected_revision)) {
            self.cancelled = true;
            return false;
        }
        const data = captured catch return false;
        var raw_writer = volume.overwrite(file) catch {
            self.disabled = true;
            return false;
        };
        var writer = @import("owned_io.zig").wrap(&raw_writer, self.service, &self.cancelled);
        self.value.save(&writer, slot, data, block()) catch {
            if (!self.cancelled) self.disabled = true;
            return false;
        };
        return true;
    }
};
