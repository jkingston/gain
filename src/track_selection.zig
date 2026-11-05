//! Now Playing and a pending selection own their strings independently of scan
//! arenas. Repeated selections may replace pending data, never the playing slot.
const std = @import("std");
const core = @import("library.zig");

pub const Store = struct {
    allocators: [2]std.heap.FixedBufferAllocator,
    order: @import("play_queue.zig").Queue,
    tracks: [2]core.Track = undefined,
    playing: u1 = 0,
    pending: bool = false,

    pub fn init(bytes: []u8) Store {
        const queue_bytes = @min(8192 * 8, bytes.len / 2) & ~@as(usize, 7);
        const metadata = bytes[queue_bytes..];
        const half = metadata.len / 2;
        return .{ .order = .init(bytes[0..queue_bytes]), .allocators = .{ std.heap.FixedBufferAllocator.init(metadata[0..half]), std.heap.FixedBufferAllocator.init(metadata[half..]) } };
    }

    pub fn queue(self: *Store, track: *const core.Track) !*const core.Track {
        const slot = self.playing ^ 1;
        self.pending = false;
        self.allocators[slot].reset();
        self.tracks[slot] = try core.clone(self.allocators[slot].allocator(), track.*);
        self.pending = true;
        return &self.tracks[slot];
    }

    pub fn begin(self: *Store) ?*const core.Track {
        if (!self.pending) return null;
        self.playing ^= 1;
        self.pending = false;
        return &self.tracks[self.playing];
    }
};

test "now playing survives catalogue reclamation and repeated pending replacements" {
    var memory: [8192]u8 = undefined;
    var store = Store.init(&memory);
    var title = [_]u8{ 'O', 'l', 'd' };
    var track = core.Track{ .id = 1, .path = "music/old.m4a", .stamp = .{}, .meta = .{ .title = &title } };
    _ = try store.queue(&track);
    const playing = store.begin().?;
    @memset(&title, 'x');
    track.id = 2;
    for (0..8) |_| _ = try store.queue(&track);
    try std.testing.expectEqualStrings("Old", playing.meta.title);
    try std.testing.expectEqual(1, playing.id);
    try std.testing.expectEqual(2, store.begin().?.id);
    try std.testing.expect(store.begin() == null);
}

test "oversized pending metadata cannot overwrite playing metadata" {
    var memory: [4096]u8 = undefined;
    var store = Store.init(&memory);
    const track = core.Track{ .id = 1, .path = "ok", .stamp = .{}, .meta = .{ .title = "Kept" } };
    _ = try store.queue(&track);
    const playing = store.begin().?;
    var too_long: [4096]u8 = @splat('a');
    var other = track;
    other.meta.title = &too_long;
    try std.testing.expectError(error.OutOfMemory, store.queue(&other));
    try std.testing.expectEqualStrings("Kept", playing.meta.title);
    try std.testing.expect(!store.pending);
}
