//! Bounded session persistence for the F20's overwrite-only filesystem. These
//! methods belong to the sole storage owner; no read or write runs from paint.
const session = @import("listening_session.zig");
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
    journal: session.Journal = .{},
    membership_key: ?u64 = null,
    disabled: bool = false,
    cancelled: bool = false,
    service: ?@import("f20_player.zig").StorageService = null,

    fn block() *[512]u8 {
        return @ptrCast(memory.storage_burst.uncachedSlice(u8).ptr);
    }

    fn scratch() []u8 {
        return memory.session_scratch.cachedSlice(u8);
    }

    pub fn load(self: *Store, volume: *Volume, source: u64) ?session.Record {
        self.* = .{ .service = self.service };
        self.file = managed.open(volume, ".gain/session.bin", .session, block()) catch return null;
        if (self.file.?.size != session.allocation_bytes) {
            self.file = null;
            return null;
        }
        var raw_reader = volume.reader(self.file.?) catch return null;
        var reader = @import("owned_io.zig").wrap(&raw_reader, self.service, &self.cancelled);
        const record = (self.journal.load(&reader, source, scratch(), block()) catch return null) orelse return null;
        self.membership_key = session.membershipKey(record.data);
        return record;
    }

    /// The caller observes revision, position and navigation together. Copy
    /// only the queue header under interrupt exclusion; serialize with IRQs on
    /// and discard a changed revision before any write. Later edits stay dirty.
    pub fn save(self: *Store, volume: *Volume, queue: *const Queue, expected_revision: u32, source: u64, position: session.Position, navigation: session.Navigation) void {
        self.cancelled = false;
        if (self.disabled) return;
        const file = self.file orelse return;
        const header = headerSnapshot(queue);
        if (header.revision != expected_revision) {
            self.cancelled = true;
            return;
        }
        const captured = session.capture(header, source, position, navigation, scratch());
        if (!unchanged(queue, expected_revision)) {
            self.cancelled = true;
            return;
        }
        const data = captured catch {
            self.disabled = true;
            return;
        };
        const key = session.membershipKey(data);
        var raw_writer = volume.overwrite(file) catch {
            self.disabled = true;
            return;
        };
        var writer = @import("owned_io.zig").wrap(&raw_writer, self.service, &self.cancelled);
        if (self.membership_key == null or self.membership_key.? != key) {
            self.journal.saveQueue(&writer, data, block()) catch {
                if (!self.cancelled) self.disabled = true;
                return;
            };
            self.membership_key = key;
        } else self.journal.savePosition(&writer, data, position, block()) catch {
            if (!self.cancelled) self.disabled = true;
        };
    }
};
