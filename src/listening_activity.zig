//! Stable, typed music favourites and first-discovery sequence. This state owns
//! no metadata strings. Sorted ID columns provide bounded, allocation-free UI
//! lookups; discovery changes only after an authoritative complete library view.
const std = @import("std");
const views = @import("progressive_view.zig");

pub const Kind = enum { song, album };
pub const max_albums = 1536; // 1024 current albums plus retained missing records.
pub const max_songs = 8192;
const header_bytes = 64;
const album_bytes = 20;
const song_base = header_bytes + max_albums * album_bytes;
pub const state_bytes = song_base + max_songs * 8;
pub const Journal = @import("owned_journal.zig").Journal("GACT".*, 128 * 1024);
pub const allocation_bytes = Journal.allocation_bytes;
const favourite_bit = 0x80000000;
const sequence_mask = favourite_bit - 1;

pub const Album = struct { id: u64, anchor: u64, first_seen: u32, favourite: bool };

/// Keep a queued UI action attached to the same album across a cold retag.
/// A missing anchor retains the original tombstone rather than guessing.
pub fn resolveFavouriteId(view: *const views.Snapshot, kind: Kind, id: u64, anchor: u64) u64 {
    if (kind == .song or view.albumIndex(id) != null) return id;
    return if (view.albumForTrack(anchor)) |album| album.id else id;
}

pub const State = struct {
    bytes: []u8,
    source: u64 = 0,
    album_count: usize = 0,
    song_count: usize = 0,
    sequence: u32 = 0,
    initialized: bool = false,
    revision: u32 = 0,

    pub fn init(bytes: []u8, source: u64) !State {
        if (bytes.len < state_bytes) return error.ActivityCapacity;
        @memset(bytes[0..state_bytes], 0);
        return .{ .bytes = bytes[0..state_bytes], .source = source };
    }

    pub fn albumAt(self: State, i: usize) ?Album {
        if (i >= self.album_count) return null;
        const bytes = self.bytes[header_bytes + i * album_bytes ..][0..album_bytes];
        const flags = std.mem.readInt(u32, bytes[16..20], .little);
        return .{ .id = std.mem.readInt(u64, bytes[0..8], .little), .anchor = std.mem.readInt(u64, bytes[8..16], .little), .first_seen = flags & sequence_mask, .favourite = flags & favourite_bit != 0 };
    }

    fn setAlbum(self: *State, i: usize, value: Album) void {
        const bytes = self.bytes[header_bytes + i * album_bytes ..][0..album_bytes];
        std.mem.writeInt(u64, bytes[0..8], value.id, .little);
        std.mem.writeInt(u64, bytes[8..16], value.anchor, .little);
        std.mem.writeInt(u32, bytes[16..20], value.first_seen | (if (value.favourite) @as(u32, favourite_bit) else 0), .little);
    }

    pub fn songAt(self: State, i: usize) ?u64 {
        return if (i < self.song_count) std.mem.readInt(u64, self.bytes[song_base + i * 8 ..][0..8], .little) else null;
    }

    fn lowerAlbum(self: State, id: u64) usize {
        var first: usize = 0;
        var end = self.album_count;
        while (first < end) {
            const middle = first + (end - first) / 2;
            if (self.albumAt(middle).?.id < id) first = middle + 1 else end = middle;
        }
        return first;
    }

    fn lowerSong(self: State, id: u64) usize {
        var first: usize = 0;
        var end = self.song_count;
        while (first < end) {
            const middle = first + (end - first) / 2;
            if (self.songAt(middle).? < id) first = middle + 1 else end = middle;
        }
        return first;
    }

    pub fn isFavourite(self: State, kind: Kind, id: u64) bool {
        return switch (kind) {
            .song => self.songAt(self.lowerSong(id)) == id,
            .album => if (self.albumAt(self.lowerAlbum(id))) |album| album.id == id and album.favourite else false,
        };
    }

    pub fn firstSeen(self: State, id: u64) ?u32 {
        const album = self.albumAt(self.lowerAlbum(id)) orelse return null;
        return if (album.id == id) album.first_seen else null;
    }

    fn insertAlbum(self: *State, value: Album) !void {
        if (value.id == 0) return error.InvalidActivityIdentity;
        if (self.album_count == max_albums) return error.ActivityCapacity;
        const position = self.lowerAlbum(value.id);
        const from = header_bytes + position * album_bytes;
        const length = (self.album_count - position) * album_bytes;
        @memmove(self.bytes[from + album_bytes ..][0..length], self.bytes[from..][0..length]);
        self.setAlbum(position, value);
        self.album_count += 1;
    }

    fn removeAlbum(self: *State, position: usize) void {
        const from = header_bytes + position * album_bytes;
        const length = (self.album_count - position - 1) * album_bytes;
        @memmove(self.bytes[from..][0..length], self.bytes[from + album_bytes ..][0..length]);
        self.album_count -= 1;
    }

    pub fn toggle(self: *State, kind: Kind, id: u64) !void {
        try self.applyFavourite(kind, id, 0, !self.isFavourite(kind, id));
    }

    /// UI requests carry the intended state, not a delayed toggle. Reapplying
    /// one after cancellation cannot undo it, and absent albums keep an anchor
    /// so a later retag/reappearance can recover their favourite identity.
    pub fn applyFavourite(self: *State, kind: Kind, id: u64, anchor: u64, enabled: bool) !void {
        if (id == 0) return error.InvalidActivityIdentity;
        switch (kind) {
            .album => {
                const position = self.lowerAlbum(id);
                if (self.albumAt(position)) |value| {
                    if (value.id == id) {
                        var replacement = value;
                        replacement.favourite = enabled;
                        if (replacement.anchor == 0) replacement.anchor = anchor;
                        if (std.meta.eql(value, replacement)) return;
                        self.setAlbum(position, replacement);
                        self.revision +%= 1;
                        return;
                    }
                }
                if (!enabled) return;
                try self.insertAlbum(.{ .id = id, .anchor = anchor, .first_seen = 0, .favourite = true });
            },
            .song => {
                const position = self.lowerSong(id);
                const present = self.songAt(position) == id;
                if (present == enabled) return;
                const from = song_base + position * 8;
                if (present) {
                    const length = (self.song_count - position - 1) * 8;
                    @memmove(self.bytes[from..][0..length], self.bytes[from + 8 ..][0..length]);
                    self.song_count -= 1;
                } else {
                    if (self.song_count == max_songs) return error.ActivityCapacity;
                    const length = (self.song_count - position) * 8;
                    @memmove(self.bytes[from + 8 ..][0..length], self.bytes[from..][0..length]);
                    std.mem.writeInt(u64, self.bytes[from..][0..8], id, .little);
                    self.song_count += 1;
                }
            },
        }
        self.revision +%= 1;
    }

    /// Use the saved track anchor to retain album identity through title/artist
    /// retags and directory moves. Missing favourites remain as tombstones.
    pub fn reconcile(self: *State, view: *const views.Snapshot, scratch: []u8, observer: anytype) !void {
        if (!view.complete or view.source != self.source) return error.IncompleteActivitySource;
        if (scratch.len < state_bytes) return error.ActivityCapacity;
        @memcpy(scratch[0..state_bytes], self.bytes);
        var next = self.*;
        next.bytes = scratch[0..state_bytes];
        var i: usize = 0;
        while (i < next.album_count) {
            if (observer.cancelled()) return error.Cancelled;
            var record = next.albumAt(i).?;
            const destination = if (record.anchor != 0) view.albumForTrack(record.anchor) else null;
            if (view.albumIndex(record.id)) |rank| {
                if (destination == null or destination.?.id != record.id) {
                    record.anchor = view.albums[rank].representative.id;
                    next.setAlbum(i, record);
                }
            } else if (destination) |album| if (album.id != record.id) {
                next.removeAlbum(i);
                const existing = next.lowerAlbum(album.id);
                if (next.albumAt(existing)) |other| {
                    if (other.id == album.id) {
                        record.first_seen = @min(record.first_seen, other.first_seen);
                        record.favourite = record.favourite or other.favourite;
                        next.removeAlbum(existing);
                    }
                }
                record.id = album.id;
                try next.insertAlbum(record);
                continue;
            };
            i += 1;
        }
        var added = false;
        for (view.albums[0..view.album_count]) |album| {
            if (observer.cancelled()) return error.Cancelled;
            const position = next.lowerAlbum(album.id);
            if (next.albumAt(position)) |value| if (value.id == album.id) continue;
            if (!added and next.initialized) {
                if (next.sequence == sequence_mask) return error.ActivitySequenceExhausted;
                next.sequence += 1;
            }
            added = true;
            try next.insertAlbum(.{ .id = album.id, .anchor = album.representative.id, .first_seen = if (next.initialized) next.sequence else 0, .favourite = false });
        }
        next.initialized = true;
        if (observer.cancelled()) return error.Cancelled;
        if (next.album_count != self.album_count or next.sequence != self.sequence or next.initialized != self.initialized or !std.mem.eql(u8, next.bytes[header_bytes .. header_bytes + next.album_count * album_bytes], self.bytes[header_bytes .. header_bytes + self.album_count * album_bytes])) {
            @memcpy(self.bytes, next.bytes);
            self.album_count = next.album_count;
            self.sequence = next.sequence;
            self.initialized = true;
            self.revision +%= 1;
        }
    }

    pub fn capture(self: State, output: []u8) ![]const u8 {
        const length = header_bytes + self.album_count * album_bytes + self.song_count * 8;
        if (output.len < length) return error.ActivityCapacity;
        @memset(output[0..header_bytes], 0);
        @memcpy(output[0..4], "GAC1");
        std.mem.writeInt(u16, output[4..6], @intCast(self.album_count), .little);
        std.mem.writeInt(u16, output[6..8], @intCast(self.song_count), .little);
        std.mem.writeInt(u64, output[8..16], self.source, .little);
        std.mem.writeInt(u32, output[16..20], self.sequence, .little);
        output[20] = @intFromBool(self.initialized);
        @memcpy(output[header_bytes..][0 .. self.album_count * album_bytes], self.bytes[header_bytes..][0 .. self.album_count * album_bytes]);
        @memcpy(output[header_bytes + self.album_count * album_bytes ..][0 .. self.song_count * 8], self.bytes[song_base..][0 .. self.song_count * 8]);
        return output[0..length];
    }

    pub fn valid(bytes: []const u8, source: u64) bool {
        if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..4], "GAC1") or std.mem.readInt(u64, bytes[8..16], .little) != source or bytes[20] > 1) return false;
        const albums = std.mem.readInt(u16, bytes[4..6], .little);
        const songs = std.mem.readInt(u16, bytes[6..8], .little);
        const sequence = std.mem.readInt(u32, bytes[16..20], .little);
        if (albums > max_albums or songs > max_songs or sequence > sequence_mask or (bytes[20] == 0 and sequence != 0) or bytes.len != header_bytes + @as(usize, albums) * album_bytes + @as(usize, songs) * 8) return false;
        var previous: u64 = 0;
        for (0..albums) |i| {
            const record = bytes[header_bytes + i * album_bytes ..][0..album_bytes];
            const id = std.mem.readInt(u64, record[0..8], .little);
            if (id <= previous or std.mem.readInt(u32, record[16..20], .little) & sequence_mask > sequence) return false;
            previous = id;
        }
        previous = 0;
        for (0..songs) |i| {
            const id = std.mem.readInt(u64, bytes[header_bytes + @as(usize, albums) * album_bytes + i * 8 ..][0..8], .little);
            if (id <= previous) return false;
            previous = id;
        }
        return true;
    }

    pub fn load(self: *State, bytes: []const u8) !void {
        if (!valid(bytes, self.source)) return error.InvalidActivity;
        self.album_count = std.mem.readInt(u16, bytes[4..6], .little);
        self.song_count = std.mem.readInt(u16, bytes[6..8], .little);
        self.sequence = std.mem.readInt(u32, bytes[16..20], .little);
        self.initialized = bytes[20] != 0;
        @memcpy(self.bytes[header_bytes..][0 .. self.album_count * album_bytes], bytes[header_bytes..][0 .. self.album_count * album_bytes]);
        @memcpy(self.bytes[song_base..][0 .. self.song_count * 8], bytes[header_bytes + self.album_count * album_bytes ..][0 .. self.song_count * 8]);
        self.revision +%= 1;
    }
};

const Uninterrupted = struct {
    pub fn cancelled(_: @This()) bool {
        return false;
    }
};

test "quiet baseline, typed favourites and first discovery survive retags moves and missing music" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, state_bytes);
    defer a.free(bytes);
    const scratch = try a.alloc(u8, state_bytes);
    defer a.free(scratch);
    const view = try a.create(views.Snapshot);
    defer a.destroy(view);
    var state = try State.init(bytes, 7);
    var tracks = [_]@import("library.zig").Track{
        .{ .id = 11, .path = "A/1.flac", .stamp = .{}, .meta = .{ .title = "One", .album = "A", .artist = "Artist" } },
        .{ .id = 22, .path = "B/1.flac", .stamp = .{}, .meta = .{ .title = "Two", .album = "B", .artist = "Artist" } },
    };
    try view.build(&.{}, tracks[0..1], 7, true, 1);
    const original = view.albums[0].id;
    try state.reconcile(view, scratch, Uninterrupted{});
    try std.testing.expectEqual(0, state.firstSeen(original).?);
    try state.toggle(.album, original);
    try state.toggle(.song, original); // Hash collision across key kinds is safe.
    try state.toggle(.song, 11);
    try std.testing.expect(state.isFavourite(.album, original));
    try state.toggle(.song, original);
    try std.testing.expect(!state.isFavourite(.song, original));
    try std.testing.expect(state.isFavourite(.album, original));
    tracks[0].path = "Renamed/1.flac";
    tracks[0].meta.album = "Retagged";
    try view.build(&.{}, &tracks, 7, true, 2);
    const retagged = view.albumForTrack(11).?.id;
    const added = view.albumForTrack(22).?.id;
    try std.testing.expect(retagged != original);
    try state.reconcile(view, scratch, Uninterrupted{});
    try std.testing.expectEqual(0, state.firstSeen(retagged).?);
    try std.testing.expect(state.isFavourite(.album, retagged));
    try std.testing.expectEqual(1, state.firstSeen(added).?);
    try std.testing.expect(state.isFavourite(.song, 11));
    const revision = state.revision;
    try state.reconcile(view, scratch, Uninterrupted{});
    try std.testing.expectEqual(revision, state.revision);
    try view.build(&.{}, &.{}, 7, true, 3);
    try state.reconcile(view, scratch, Uninterrupted{});
    try std.testing.expect(state.isFavourite(.album, retagged));
    try std.testing.expect(state.isFavourite(.song, 11));
    const payload = try state.capture(scratch);
    var restored = try State.init(try a.alloc(u8, state_bytes), 7);
    defer a.free(restored.bytes);
    try restored.load(payload);
    try std.testing.expect(restored.isFavourite(.album, retagged));
    try std.testing.expect(restored.isFavourite(.song, 11));
    try std.testing.expectEqual(1, restored.firstSeen(added).?);
}

test "partial or cancelled discoveries never publish activity and capacity retains existing favourites" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, state_bytes);
    defer a.free(bytes);
    const scratch = try a.alloc(u8, state_bytes);
    defer a.free(scratch);
    const view = try a.create(views.Snapshot);
    defer a.destroy(view);
    var state = try State.init(bytes, 7);
    const tracks = [_]@import("library.zig").Track{.{ .id = 11, .path = "A/1.flac", .stamp = .{}, .meta = .{ .album = "A" } }};
    try view.build(&.{}, &tracks, 7, false, 1);
    try std.testing.expectError(error.IncompleteActivitySource, state.reconcile(view, scratch, Uninterrupted{}));
    try std.testing.expect(!state.initialized);
    try view.build(&.{}, &tracks, 7, true, 2);
    const Cancelled = struct {
        pub fn cancelled(_: @This()) bool {
            return true;
        }
    };
    try std.testing.expectError(error.Cancelled, state.reconcile(view, scratch, Cancelled{}));
    try std.testing.expect(!state.initialized);
    for (1..max_albums + 1) |id| try state.toggle(.album, id);
    const before = try a.dupe(u8, bytes);
    defer a.free(before);
    try std.testing.expectError(error.ActivityCapacity, state.reconcile(view, scratch, Uninterrupted{}));
    try std.testing.expectEqualSlices(u8, before, bytes);
    try std.testing.expect(state.isFavourite(.album, 1));
    for (1..max_songs + 1) |id| try state.toggle(.song, id);
    try std.testing.expectError(error.ActivityCapacity, state.toggle(.song, max_songs + 1));
    const payload = try state.capture(scratch);
    try std.testing.expectEqual(state_bytes, payload.len);
    try std.testing.expect(State.valid(payload, 7));
    try std.testing.expect(!State.valid(payload, 8));
    scratch[20] = 2;
    try std.testing.expect(!State.valid(payload, 7));
}

test "moving one track out of a surviving album does not move that album favourite" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, state_bytes);
    defer a.free(bytes);
    const scratch = try a.alloc(u8, state_bytes);
    defer a.free(scratch);
    const view = try a.create(views.Snapshot);
    defer a.destroy(view);
    var state = try State.init(bytes, 7);
    var tracks = [_]@import("library.zig").Track{
        .{ .id = 11, .path = "A/1.flac", .stamp = .{}, .meta = .{ .album = "A", .track = 1 } },
        .{ .id = 22, .path = "A/2.flac", .stamp = .{}, .meta = .{ .album = "A", .track = 2 } },
    };
    try view.build(&.{}, &tracks, 7, true, 1);
    const original = view.albumForTrack(11).?.id;
    try state.reconcile(view, scratch, Uninterrupted{});
    try state.toggle(.album, original);
    tracks[0].path = "B/1.flac";
    tracks[0].meta.album = "B";
    try view.build(&.{}, &tracks, 7, true, 2);
    try state.reconcile(view, scratch, Uninterrupted{});
    try std.testing.expect(state.isFavourite(.album, original));
    try std.testing.expect(!state.isFavourite(.album, view.albumForTrack(11).?.id));
    try std.testing.expectEqual(0, state.firstSeen(original).?);
}

test "desired favourite requests are idempotent and resolve a pending album retag by anchor" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, state_bytes);
    defer a.free(bytes);
    const scratch = try a.alloc(u8, state_bytes);
    defer a.free(scratch);
    const view = try a.create(views.Snapshot);
    defer a.destroy(view);
    var state = try State.init(bytes, 7);
    var track = @import("library.zig").Track{ .id = 11, .path = "A/1.flac", .stamp = .{}, .meta = .{ .album = "Before" } };
    try view.build(&.{}, &.{track}, 7, true, 1);
    const original = view.albumForTrack(track.id).?.id;
    try state.reconcile(view, scratch, Uninterrupted{});
    track.meta.album = "After";
    try view.build(&.{}, &.{track}, 7, true, 2);
    try state.reconcile(view, scratch, Uninterrupted{});
    const resolved = resolveFavouriteId(view, .album, original, track.id);
    try std.testing.expect(resolved != original);
    const age = state.firstSeen(resolved).?;
    try state.applyFavourite(.album, resolved, track.id, true);
    const revision = state.revision;
    try state.applyFavourite(.album, resolved, 99, true);
    try std.testing.expectEqual(revision, state.revision);
    try std.testing.expectEqual(age, state.firstSeen(resolved).?);
    try std.testing.expectEqual(track.id, state.albumAt(state.lowerAlbum(resolved)).?.anchor);
    try state.applyFavourite(.song, track.id, 0, true);
    const song_revision = state.revision;
    try state.applyFavourite(.song, track.id, 0, true);
    try std.testing.expectEqual(song_revision, state.revision);
    try state.applyFavourite(.song, track.id, 0, false);
    const removed_revision = state.revision;
    try state.applyFavourite(.song, track.id, 0, false);
    try std.testing.expectEqual(removed_revision, state.revision);
    try std.testing.expectEqual(original, resolveFavouriteId(view, .song, original, track.id));
    try std.testing.expectEqual(@as(u64, 99), resolveFavouriteId(view, .album, 99, 0));
}

test "absent album favourite keeps its anchor until the album returns with a new identity" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, state_bytes);
    defer a.free(bytes);
    const scratch = try a.alloc(u8, state_bytes);
    defer a.free(scratch);
    const view = try a.create(views.Snapshot);
    defer a.destroy(view);
    var state = try State.init(bytes, 7);
    try state.applyFavourite(.album, 99, 11, true);
    try view.build(&.{}, &.{}, 7, true, 1);
    try state.reconcile(view, scratch, Uninterrupted{});
    try std.testing.expect(state.isFavourite(.album, 99));
    const track = @import("library.zig").Track{ .id = 11, .path = "Moved/1.flac", .stamp = .{}, .meta = .{ .album = "New title" } };
    try view.build(&.{}, &.{track}, 7, true, 2);
    try state.reconcile(view, scratch, Uninterrupted{});
    const resolved = view.albumForTrack(11).?.id;
    try std.testing.expect(state.isFavourite(.album, resolved));
    try std.testing.expect(!state.isFavourite(.album, 99));
}
