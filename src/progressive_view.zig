//! Bounded borrowed projections. Track strings stay in one of the two catalogue
//! arenas; neither arena is reclaimed until the playback executive has joined.
const std = @import("std");
const core = @import("library.zig");

pub const max_tracks = 8192;
pub const max_albums = 1024;
pub const max_artists = max_albums;

pub const Album = struct {
    id: u64,
    title: []const u8,
    artist: []const u8,
    directory: []const u8,
    release_id: []const u8,
    representative: *const core.Track,
    count: u32 = 0,
    art: core.Artwork = .{},
    group: u16 = 0,
    first_track: u16 = 0,
    artist_index: u16 = 0,
};

pub const Artist = struct {
    name: []const u8,
    first_album: u16,
    album_count: u16 = 0,
    first_track: u16 = 0,
    track_count: u16 = 0,
};

pub const Snapshot = struct {
    tracks: [max_tracks]*const core.Track = undefined,
    albums: [max_albums]Album = undefined,
    track_groups: [max_tracks]u16 = undefined,
    track_order: [max_tracks]u16 = undefined,
    group_ranks: [max_albums]u16 = undefined,
    artists: [max_artists]Artist = undefined,
    title_order: [max_tracks]u16 = undefined,
    artist_track_order: [max_tracks]u16 = undefined,
    table: [2048]u16 = @splat(0),
    track_count: usize = 0,
    album_count: usize = 0,
    artist_count: usize = 0,
    source: u64 = 0,
    revision: u32 = 0,
    complete: bool = false,

    pub fn build(self: *Snapshot, baseline: *const core.Catalog, visited: []const core.Track, source: u64, complete: bool, revision: u32) !void {
        self.track_count = 0;
        self.album_count = 0;
        self.artist_count = 0;
        self.source = source;
        self.complete = complete;
        self.revision = revision;
        @memset(&self.table, 0);
        // Both inputs are in path order. A linear merge retains unvisited old
        // records until a complete scan makes removals authoritative.
        var old: usize = 0;
        var next: usize = 0;
        while (next < visited.len or (!complete and old < baseline.tracks.len)) {
            const track = if (next == visited.len) keep: {
                defer old += 1;
                break :keep &baseline.tracks[old];
            } else if (complete or old == baseline.tracks.len) new: {
                defer next += 1;
                break :new &visited[next];
            } else switch (std.mem.order(u8, baseline.tracks[old].path, visited[next].path)) {
                .lt => keep: {
                    defer old += 1;
                    break :keep &baseline.tracks[old];
                },
                .eq => replace: {
                    old += 1;
                    defer next += 1;
                    break :replace &visited[next];
                },
                .gt => new: {
                    defer next += 1;
                    break :new &visited[next];
                },
            };
            if (self.track_count == max_tracks) return error.LibraryLimit;
            self.tracks[self.track_count] = track;
            self.track_count += 1;
            const directory = core.editionRoot(track.path);
            var key_buffer: [16 * 1024]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "{s}\x1f{s}\x1f{s}\x1f{s}", .{
                track.meta.release_id,
                track.meta.album_artist,
                track.meta.album,
                directory,
            });
            const id = core.hash(key) ^ source;
            var slot: usize = @intCast(id & (self.table.len - 1));
            while (self.table[slot] != 0) : (slot = (slot + 1) % self.table.len) {
                const index = self.table[slot] - 1;
                const album = &self.albums[index];
                if (album.id == id and std.mem.eql(u8, album.title, track.meta.album) and std.mem.eql(u8, album.artist, track.meta.album_artist) and std.mem.eql(u8, album.directory, directory) and std.mem.eql(u8, album.release_id, track.meta.release_id)) {
                    self.track_groups[self.track_count - 1] = index;
                    album.count += 1;
                    break;
                }
            } else {
                if (self.album_count == max_albums) return error.LibraryLimit;
                var art: core.Artwork = .{};
                for (baseline.albums) |album| if (album.id == id) {
                    art = album.art;
                    break;
                };
                self.track_groups[self.track_count - 1] = @intCast(self.album_count);
                self.albums[self.album_count] = .{
                    .group = @intCast(self.album_count),
                    .id = id,
                    .title = track.meta.album,
                    .artist = track.meta.album_artist,
                    .directory = directory,
                    .release_id = track.meta.release_id,
                    .representative = track,
                    .count = 1,
                    .art = art,
                };
                self.table[slot] = @intCast(self.album_count + 1);
                self.album_count += 1;
            }
        }
        std.mem.sort(Album, self.albums[0..self.album_count], {}, struct {
            fn less(_: void, a: Album, b: Album) bool {
                if (!std.ascii.eqlIgnoreCase(a.artist, b.artist)) return core.lessText(a.artist, b.artist);
                if (!std.ascii.eqlIgnoreCase(a.title, b.title)) return core.lessText(a.title, b.title);
                return a.id < b.id;
            }
        }.less);
        for (self.albums[0..self.album_count], 0..) |album, i| self.group_ranks[album.group] = @intCast(i);
        for (self.track_groups[0..self.track_count]) |*group| group.* = self.group_ranks[group.*];
        for (self.track_order[0..self.track_count], 0..) |*rank, i| rank.* = @intCast(i);
        std.mem.sort(u16, self.track_order[0..self.track_count], SortContext{ .view = self, .order = .album }, sortedLess);
        for (self.track_order[0..self.track_count], 0..) |track, rank| {
            const group = self.track_groups[track];
            if (rank == 0 or self.track_groups[self.track_order[rank - 1]] != group) self.albums[group].first_track = @intCast(rank);
        }
        for (self.albums[0..self.album_count], 0..) |*album, rank| {
            if (self.artist_count == 0 or !std.ascii.eqlIgnoreCase(self.artists[self.artist_count - 1].name, album.artist)) {
                self.artists[self.artist_count] = .{ .name = album.artist, .first_album = @intCast(rank) };
                self.artist_count += 1;
            }
            album.artist_index = @intCast(self.artist_count - 1);
            self.artists[self.artist_count - 1].album_count += 1;
            self.artists[self.artist_count - 1].track_count += @intCast(album.count);
        }
        for (self.title_order[0..self.track_count], 0..) |*rank, i| rank.* = @intCast(i);
        std.mem.sort(u16, self.title_order[0..self.track_count], SortContext{ .view = self, .order = .title }, sortedLess);
        @memcpy(self.artist_track_order[0..self.track_count], self.title_order[0..self.track_count]);
        std.mem.sort(u16, self.artist_track_order[0..self.track_count], SortContext{ .view = self, .order = .artist_title }, sortedLess);
        var first: u16 = 0;
        for (self.artists[0..self.artist_count]) |*artist| {
            artist.first_track = first;
            first += artist.track_count;
        }
    }

    const SortContext = struct { view: *const Snapshot, order: enum { album, title, artist_title } };

    fn sortedLess(context: SortContext, a: u16, b: u16) bool {
        const view = context.view;
        switch (context.order) {
            .title => return titleLess(view, a, b),
            .artist_title => {
                const left = view.albums[view.track_groups[a]].artist_index;
                const right = view.albums[view.track_groups[b]].artist_index;
                return if (left != right) left < right else titleLess(view, a, b);
            },
            .album => {
                if (view.track_groups[a] != view.track_groups[b]) return view.track_groups[a] < view.track_groups[b];
                const left = view.tracks[a];
                const right = view.tracks[b];
                if (left.meta.disc != right.meta.disc) return left.meta.disc < right.meta.disc;
                const left_number = if (left.meta.track == 0) std.math.maxInt(u32) else left.meta.track;
                const right_number = if (right.meta.track == 0) std.math.maxInt(u32) else right.meta.track;
                if (left_number != right_number) return left_number < right_number;
                return core.lessText(left.path, right.path);
            },
        }
    }

    fn titleLess(self: *const Snapshot, a: u16, b: u16) bool {
        const left = self.tracks[a];
        const right = self.tracks[b];
        if (!std.mem.eql(u8, left.meta.title, right.meta.title)) return core.lessText(left.meta.title, right.meta.title);
        if (self.track_groups[a] != self.track_groups[b]) return self.track_groups[a] < self.track_groups[b];
        if (left.meta.disc != right.meta.disc) return left.meta.disc < right.meta.disc;
        if (left.meta.track != right.meta.track) return left.meta.track < right.meta.track;
        if (!std.mem.eql(u8, left.path, right.path)) return core.lessText(left.path, right.path);
        return left.id < right.id;
    }

    pub fn albumTrack(self: *const Snapshot, album: usize, row: usize) ?*const core.Track {
        if (album >= self.album_count or row >= self.albums[album].count) return null;
        return self.tracks[self.track_order[@as(usize, self.albums[album].first_track) + row]];
    }

    pub fn artistTrack(self: *const Snapshot, artist: usize, row: usize) ?*const core.Track {
        if (artist >= self.artist_count or row >= self.artists[artist].track_count) return null;
        return self.tracks[self.artist_track_order[@as(usize, self.artists[artist].first_track) + row]];
    }

    pub fn artistIndex(self: *const Snapshot, id: u64) ?usize {
        for (0..self.artist_count) |i| if (self.artistId(i) == id) return i;
        return null;
    }

    pub fn artistId(self: *const Snapshot, index: usize) u64 {
        var identity = std.hash.Wyhash.init(self.source ^ 0x415254495354);
        for (self.artists[index].name) |byte| identity.update(&.{std.ascii.toLower(byte)});
        return identity.final();
    }

    pub fn albumIndex(self: *const Snapshot, id: u64) ?usize {
        for (self.albums[0..self.album_count], 0..) |album, i| if (album.id == id) return i;
        return null;
    }
};

pub const Pair = struct {
    slots: [2]Snapshot = undefined,
    published: std.atomic.Value(u32) = .init(0),

    pub fn publish(self: *Pair, baseline: *const core.Catalog, visited: []const core.Track, source: u64, complete: bool) !void {
        self.commit(try self.prepare(baseline, visited, source, complete));
    }

    /// One storage writer may prepare while UI reads the published slot.
    pub fn prepare(self: *Pair, baseline: *const core.Catalog, visited: []const core.Track, source: u64, complete: bool) !u32 {
        const revision = self.published.load(.acquire) +% 1;
        const next: u1 = @truncate(revision);
        try self.slots[next].build(baseline, visited, source, complete, revision);
        return revision;
    }

    /// Call once for the latest prepare; callers may combine this store with
    /// withdrawal of other borrowed references in a tiny interrupt-masked step.
    pub fn commit(self: *Pair, revision: u32) void {
        std.debug.assert(revision == self.published.load(.acquire) +% 1);
        // Single CPU: no yields/interruptible consumers retain an inactive slot.
        // Interrupts may read the old slot; only this store publishes the new.
        self.published.store(revision, .release);
    }

    pub fn current(self: *const Pair) *const Snapshot {
        return &self.slots[@as(u1, @truncate(self.published.load(.acquire)))];
    }
};

test "direct album and artist rows preserve disc order, title order and compilation grouping" {
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .title = "Part 10", .album = "First", .album_artist = "Artist", .artist = "Guest", .track = 10, .disc = 1 } },
        .{ .id = 2, .path = "A/2", .stamp = .{}, .meta = .{ .title = "Part 2", .album = "First", .album_artist = "Artist", .artist = "Solo", .track = 2, .disc = 1 } },
        .{ .id = 3, .path = "B/1", .stamp = .{}, .meta = .{ .title = "Another", .album = "Second", .album_artist = "artist", .track = 1, .disc = 1 } },
        .{ .id = 4, .path = "C/1", .stamp = .{}, .meta = .{ .title = "Part 1", .album = "Compilation", .album_artist = "Various Artists", .artist = "Artist", .track = 1 } },
    };
    const view = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(view);
    try view.build(&.{}, &tracks, 42, true, 1);
    try std.testing.expectEqual(2, view.artist_count);
    const album = view.track_groups[0];
    try std.testing.expectEqual(2, view.albumTrack(album, 0).?.id);
    try std.testing.expectEqual(1, view.albumTrack(album, 1).?.id);
    try std.testing.expect(view.albumTrack(album, 2) == null);
    const artist = view.albums[album].artist_index;
    for ([_]u64{ 3, 2, 1 }, 0..) |id, row| try std.testing.expectEqual(id, view.artistTrack(artist, row).?.id);
    try std.testing.expect(view.artistTrack(artist, 3) == null);
    for ([_]u64{ 3, 4, 2, 1 }, 0..) |id, row| try std.testing.expectEqual(id, view.tracks[view.title_order[row]].id);
    const identity = view.artistId(artist);
    try view.build(&.{}, tracks[2..], 42, true, 2);
    const retained = view.artistIndex(identity).?;
    try std.testing.expectEqual(3, view.artistTrack(retained, 0).?.id);
}

test "indexed ranges cover every published track once and reject out of range rows" {
    var tracks: [max_tracks]core.Track = undefined;
    for (&tracks, 0..) |*track, i| track.* = .{
        .id = i + 1,
        .path = "Album/track.flac",
        .stamp = .{},
        .meta = .{ .title = "Track", .album = "Album", .album_artist = "Artist", .track = @intCast(tracks.len - i) },
    };
    const view = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(view);
    try view.build(&.{}, &tracks, 42, true, 1);
    for (0..tracks.len) |i| {
        try std.testing.expectEqual(tracks.len - i, view.albumTrack(0, i).?.id);
        try std.testing.expectEqual(tracks.len - i, view.artistTrack(0, i).?.id);
    }
    try std.testing.expect(view.albumTrack(1, 0) == null);
    try std.testing.expect(view.artistTrack(1, 0) == null);
    try std.testing.expect(view.artistTrack(0, tracks.len) == null);
    try view.build(&.{}, &.{}, 42, true, 2);
    try std.testing.expectEqual(0, view.artist_count);
    try std.testing.expect(view.albumTrack(0, 0) == null);
}

test "borrowed progressive projection merges updates, preserves old paths and confirms removals only at completion" {
    const old = [_]core.Track{
        .{ .id = 1, .path = "B/1.m4a", .stamp = .{}, .meta = .{ .album = "B", .album_artist = "B" } },
        .{ .id = 2, .path = "C/1.m4a", .stamp = .{}, .meta = .{ .album = "C", .album_artist = "C" } },
    };

    const visited = [_]core.Track{.{ .id = 3, .path = "A/1.m4a", .stamp = .{}, .meta = .{ .album = "A", .album_artist = "A" } }};
    const p = try std.testing.allocator.create(Pair);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    const baseline = core.Catalog{ .tracks = &old };
    try p.publish(&baseline, &.{}, 42, false);
    const selected = p.current().albums[0].id;
    try p.publish(&baseline, &visited, 42, false);
    try std.testing.expectEqual(3, p.current().track_count);
    try std.testing.expectEqual(3, p.current().album_count);
    try std.testing.expectEqual(1, p.current().albumIndex(selected).?);
    try std.testing.expect(p.current().tracks[1] == &old[0]);
    try p.publish(&baseline, &visited, 42, true);
    try std.testing.expectEqual(1, p.current().track_count);
    try std.testing.expect(p.current().albumIndex(selected) == null);
}

test "duplicate album names stay distinct and multiple tracks group coherently" {
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .album = "Same", .album_artist = "Artist" } },
        .{ .id = 2, .path = "A/2", .stamp = .{}, .meta = .{ .album = "Same", .album_artist = "Artist" } },
        .{ .id = 3, .path = "B/1", .stamp = .{}, .meta = .{ .album = "Same", .album_artist = "Artist" } },
    };

    const s = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(s);
    try s.build(&.{}, &tracks, 1, true, 1);
    try std.testing.expectEqual(2, s.album_count);
    try std.testing.expectEqual(3, s.albums[0].count + s.albums[1].count);
}

test "published membership stays coherent when final folder inheritance refines source metadata" {
    var tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .album = "First", .album_artist = "Artist" } },
        .{ .id = 2, .path = "B/1", .stamp = .{}, .meta = .{ .album = "Second", .album_artist = "Artist" } },
    };

    const projection = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(projection);
    try projection.build(&.{}, &tracks, 1, true, 1);
    const group = projection.track_groups[0];
    tracks[0].meta.album = "Refined from folder context";
    try std.testing.expectEqualStrings("First", projection.albums[group].title);
    try std.testing.expectEqual(1, projection.albums[group].representative.id);
    try std.testing.expectEqual(group, projection.track_groups[0]);
}

test "bounded projection failure never publishes a partial replacement" {
    const projection = try std.testing.allocator.create(Pair);
    defer std.testing.allocator.destroy(projection);
    projection.* = .{};
    const track = core.Track{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .album = "Album", .album_artist = "Artist" } };
    try projection.publish(&.{}, &.{track}, 1, true);
    const previous = projection.current();
    const oversized = try std.testing.allocator.alloc(core.Track, max_tracks + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, track);
    try std.testing.expectError(error.LibraryLimit, projection.publish(&.{}, oversized, 1, true));
    try std.testing.expect(previous == projection.current());
    try std.testing.expectEqual(1, projection.current().track_count);
}

test "prepared replacement is invisible until its single commit" {
    const pair = try std.testing.allocator.create(Pair);
    defer std.testing.allocator.destroy(pair);
    pair.* = .{};
    const old = [_]core.Track{.{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .album = "Old" } }};
    const new = [_]core.Track{.{ .id = 2, .path = "B/1", .stamp = .{}, .meta = .{ .album = "New" } }};
    try pair.publish(&.{}, &old, 42, true);
    const published = pair.current();
    const revision = try pair.prepare(&.{}, &new, 42, true);
    try std.testing.expect(pair.current() == published);
    try std.testing.expectEqual(1, pair.current().tracks[0].id);
    pair.commit(revision);
    try std.testing.expectEqual(2, pair.current().tracks[0].id);
}
