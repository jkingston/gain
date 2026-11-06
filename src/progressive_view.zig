//! Bounded borrowed projections. Track strings stay in one of the two catalogue
//! arenas. A final ref-only snapshot and withdrawal of cached artwork requests
//! release the prior arena without stopping a persistent playback executive.
const std = @import("std");
const core = @import("library.zig");

pub const max_tracks = 8192;
pub const max_albums = 1024;
pub const max_artists = max_albums;

/// Bound the cost of rebuilding progressive views while keeping the first
/// useful batch immediate. The clock may wrap; intervals must be below 2^31.
pub const PublicationCadence = struct {
    last: ?u32 = null,

    pub fn due(self: PublicationCadence, now: u32, interval: u31) bool {
        return if (self.last) |previous| now -% previous >= interval else true;
    }

    pub fn published(self: *PublicationCadence, now: u32) void {
        self.last = now;
    }
};

test "progressive publication work is bounded across clock zero, wrap and scan restart" {
    var cadence = PublicationCadence{};
    try std.testing.expect(cadence.due(0, 300));
    cadence.published(0);
    for (1..300) |tick| try std.testing.expect(!cadence.due(@intCast(tick), 300));
    try std.testing.expect(cadence.due(300, 300));
    cadence.published(0xffffff80);
    try std.testing.expect(!cadence.due(0xab, 300));
    try std.testing.expect(cadence.due(0xac, 300));
    cadence = .{};
    try std.testing.expect(cadence.due(0xad, 300));
}

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

/// A verification pass re-reads metadata; it does not make unvisited music
/// disappear. Borrow old membership until authoritative completion, but never
/// project another card's tracks, playlists or artwork onto this source.
pub fn previewBaseline(previous: *const core.Catalog, source: u64) core.Catalog {
    return if (previous.source == source) previous.* else .{ .source = source };
}

/// Unchanged records add no information to a borrowed preview. Removals still
/// require the final authoritative publication, which is never suppressed.
pub fn previewNeeded(previous_source: u64, source: u64, visited: usize, stats: core.Stats) bool {
    return previous_source != source or stats.reused != visited or stats.parsed != 0 or stats.renamed != 0 or stats.added != 0 or stats.errors != 0;
}

test "preview suppression requires every observed record to be unchanged on the same source" {
    try std.testing.expect(!previewNeeded(42, 42, 32, .{ .reused = 32 }));
    try std.testing.expect(previewNeeded(42, 43, 32, .{ .reused = 32 }));
    try std.testing.expect(previewNeeded(42, 42, 32, .{ .reused = 31, .parsed = 1 }));
    try std.testing.expect(previewNeeded(42, 42, 32, .{ .reused = 32, .renamed = 1 }));
    try std.testing.expect(previewNeeded(42, 42, 32, .{ .reused = 31 }));
}

// Work-unit cadence, not a device wall-clock guarantee. Adapters measure the
// elapsed service gap on target; the ordinary non-cooperative path erases it.
const tracks_between_service = 128;
const comparisons_between_service = 512;

const Uninterrupted = struct {
    pub fn cancelled(_: @This()) bool {
        return false;
    }
};

pub const max_playlists = 256;

pub const Snapshot = struct {
    tracks: [max_tracks]*const core.Track = undefined,
    albums: [max_albums]Album = undefined,
    track_groups: [max_tracks]u16 = undefined,
    track_order: [max_tracks]u16 = undefined,
    group_ranks: [max_albums]u16 = undefined,
    artists: [max_artists]Artist = undefined,
    title_order: [max_tracks]u16 = undefined,
    id_order: [max_tracks]u16 = undefined,
    artist_track_order: [max_tracks]u16 = undefined,
    table: [2048]u16 = @splat(0),
    playlists: []const core.Playlist = &.{},
    playlist_order: [max_playlists]u16 = undefined,
    favourite_song_order: [max_tracks]u16 = undefined,
    favourite_album_order: [max_albums]u16 = undefined,
    recent_album_order: [max_albums]u16 = undefined,
    favourite_songs: std.StaticBitSet(max_tracks) = .empty,
    favourite_albums: std.StaticBitSet(max_albums) = .empty,
    favourite_song_count: usize = 0,
    favourite_album_count: usize = 0,
    recent_album_count: usize = 0,
    activity_revision: u32 = 0,
    track_count: usize = 0,
    album_count: usize = 0,
    artist_count: usize = 0,
    source: u64 = 0,
    revision: u32 = 0,
    complete: bool = false,

    pub fn build(self: *Snapshot, baseline: *const core.Catalog, visited: []const core.Track, source: u64, complete: bool, revision: u32) !void {
        return self.buildCooperative(baseline, visited, source, complete, revision, Uninterrupted{});
    }

    /// The observer may service the published view while this inactive view is
    /// rebuilt. It must not start another build or change either input arena.
    pub fn buildCooperative(self: *Snapshot, baseline: *const core.Catalog, visited: []const core.Track, source: u64, complete: bool, revision: u32, observer: anytype) !void {
        const Work = BuildWork(@TypeOf(observer));
        var work = Work{ .observer = observer };
        try work.check();
        self.playlists = baseline.playlists;
        if (self.playlists.len > max_playlists) return error.LibraryLimit;
        self.favourite_song_count = 0;
        self.favourite_album_count = 0;
        self.recent_album_count = 0;
        self.favourite_songs = .empty;
        self.favourite_albums = .empty;
        self.activity_revision = 0;
        for (self.playlists, 0..) |_, i| self.playlist_order[i] = @intCast(i);
        const PlaylistSort = struct {
            values: []const core.Playlist,
            fn less(ctx: @This(), a: u16, b: u16) bool {
                if (!std.mem.eql(u8, ctx.values[a].name, ctx.values[b].name)) return core.lessText(ctx.values[a].name, ctx.values[b].name);
                return core.lessText(ctx.values[a].path, ctx.values[b].path);
            }
        };
        std.mem.sort(u16, self.playlist_order[0..self.playlists.len], PlaylistSort{ .values = self.playlists }, PlaylistSort.less);
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
            if (self.track_count != 0 and self.track_count % tracks_between_service == 0) try work.check();
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
                work.step();
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
                for (baseline.albums) |album| {
                    work.step();
                    if (album.id == id) {
                        art = album.art;
                        break;
                    }
                }
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
        try work.check();
        if (comptime @TypeOf(observer) == Uninterrupted) std.mem.sort(Album, self.albums[0..self.album_count], {}, albumLess) else std.mem.sort(Album, self.albums[0..self.album_count], &work, Work.lessAlbum);
        try work.check();
        for (self.albums[0..self.album_count], 0..) |album, i| self.group_ranks[album.group] = @intCast(i);
        for (self.track_groups[0..self.track_count]) |*group| group.* = self.group_ranks[group.*];
        // Stable counting buckets avoid comparing album identities for every
        // track comparison. Reuse the now-dead group map as per-album cursors.
        var track_start: u16 = 0;
        for (self.albums[0..self.album_count], 0..) |*album, rank| {
            album.first_track = track_start;
            self.group_ranks[rank] = track_start;
            track_start += @intCast(album.count);
        }
        for (self.track_groups[0..self.track_count], 0..) |group, track| {
            self.track_order[self.group_ranks[group]] = @intCast(track);
            self.group_ranks[group] += 1;
        }
        var sort = Work.Sort{ .work = &work, .base = .{ .view = self, .order = .album } };
        for (self.albums[0..self.album_count]) |album| {
            const first: usize = album.first_track;
            if (comptime @TypeOf(observer) == Uninterrupted) std.mem.sort(u16, self.track_order[first..][0..album.count], sort.base, sortedLess) else std.mem.sort(u16, self.track_order[first..][0..album.count], &sort, Work.lessTrack);
        }
        try work.check();
        for (self.albums[0..self.album_count], 0..) |*album, rank| {
            if (self.artist_count == 0 or !std.ascii.eqlIgnoreCase(self.artists[self.artist_count - 1].name, album.artist)) {
                self.artists[self.artist_count] = .{ .name = album.artist, .first_album = @intCast(rank) };
                self.artist_count += 1;
            }
            album.artist_index = @intCast(self.artist_count - 1);
            self.artists[self.artist_count - 1].album_count += 1;
            self.artists[self.artist_count - 1].track_count += @intCast(album.count);
        }
        for (self.id_order[0..self.track_count], 0..) |*rank, i| rank.* = @intCast(i);
        sort.base.order = .identity;
        if (comptime @TypeOf(observer) == Uninterrupted) std.mem.sort(u16, self.id_order[0..self.track_count], sort.base, sortedLess) else std.mem.sort(u16, self.id_order[0..self.track_count], &sort, Work.lessTrack);
        try work.check();
        for (self.title_order[0..self.track_count], 0..) |*rank, i| rank.* = @intCast(i);
        sort.base.order = .title;
        if (comptime @TypeOf(observer) == Uninterrupted) std.mem.sort(u16, self.title_order[0..self.track_count], sort.base, sortedLess) else std.mem.sort(u16, self.title_order[0..self.track_count], &sort, Work.lessTrack);
        try work.check();
        // title_order is already sorted within each artist. Stable partitioning
        // it into artist buckets gives the same order in linear time.
        var first: u16 = 0;
        for (self.artists[0..self.artist_count], 0..) |*artist, i| {
            artist.first_track = first;
            self.group_ranks[i] = first;
            first += artist.track_count;
        }
        for (self.title_order[0..self.track_count]) |track| {
            const artist = self.albums[self.track_groups[track]].artist_index;
            self.artist_track_order[self.group_ranks[artist]] = track;
            self.group_ranks[artist] += 1;
        }
        try work.check();
    }

    pub fn playlistAt(self: *const Snapshot, i: usize) ?*const core.Playlist {
        return if (i < self.playlists.len) &self.playlists[self.playlist_order[i]] else null;
    }

    pub fn playlistIndex(self: *const Snapshot, id: u64) ?usize {
        for (0..self.playlists.len) |i| if (core.hash(self.playlistAt(i).?.path) == id) return i;
        return null;
    }

    pub fn prepareActivity(self: *Snapshot, activity: ?*const @import("listening_activity.zig").State, observer: anytype) !void {
        self.favourite_song_count = 0;
        self.favourite_album_count = 0;
        self.recent_album_count = 0;
        self.favourite_songs = .empty;
        self.favourite_albums = .empty;
        self.activity_revision = 0;
        const state = activity orelse return;
        if (state.source != self.source) return;
        self.activity_revision = state.revision;
        for (self.title_order[0..self.track_count], 0..) |rank, i| {
            if (i % 32 == 0 and observer.cancelled()) return error.Cancelled;
            if (state.isFavourite(.song, self.tracks[rank].id)) {
                self.favourite_songs.set(rank);
                self.favourite_song_order[self.favourite_song_count] = rank;
                self.favourite_song_count += 1;
            }
        }
        for (self.albums[0..self.album_count], 0..) |album, rank| {
            if (rank % 32 == 0 and observer.cancelled()) return error.Cancelled;
            if (state.isFavourite(.album, album.id)) {
                self.favourite_albums.set(rank);
                self.favourite_album_order[self.favourite_album_count] = @intCast(rank);
                self.favourite_album_count += 1;
            }
            if (state.firstSeen(album.id)) |sequence| if (sequence != 0) {
                self.recent_album_order[self.recent_album_count] = @intCast(rank);
                self.recent_album_count += 1;
            };
        }
        const RecentSort = struct {
            view: *const Snapshot,
            activity: *const @import("listening_activity.zig").State,
            fn less(ctx: @This(), a: u16, b: u16) bool {
                const left = ctx.activity.firstSeen(ctx.view.albums[a].id).?;
                const right = ctx.activity.firstSeen(ctx.view.albums[b].id).?;
                return if (left != right) left > right else a < b;
            }
        };
        std.mem.sort(u16, self.recent_album_order[0..self.recent_album_count], RecentSort{ .view = self, .activity = state }, RecentSort.less);
        if (observer.cancelled()) return error.Cancelled;
    }

    fn albumLess(_: void, a: Album, b: Album) bool {
        if (!std.ascii.eqlIgnoreCase(a.artist, b.artist)) return core.lessText(a.artist, b.artist);
        if (!std.ascii.eqlIgnoreCase(a.title, b.title)) return core.lessText(a.title, b.title);
        return a.id < b.id;
    }

    const SortContext = struct { view: *const Snapshot, order: enum { album, title, identity } };

    fn sortedLess(context: SortContext, a: u16, b: u16) bool {
        const view = context.view;
        switch (context.order) {
            .identity => return view.tracks[a].id < view.tracks[b].id,
            .title => return titleLess(view, a, b),
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

    pub fn trackByPath(self: *const Snapshot, path: []const u8) ?*const core.Track {
        // The scanner and progressive merge retain bytewise path order.
        var first: usize = 0;
        var end = self.track_count;
        while (first < end) {
            const middle = first + (end - first) / 2;
            switch (std.mem.order(u8, self.tracks[middle].path, path)) {
                .lt => first = middle + 1,
                .gt => end = middle,
                .eq => return self.tracks[middle],
            }
        }
        return null;
    }

    pub fn trackIndexById(self: *const Snapshot, id: u64) ?usize {
        var first: usize = 0;
        var end = self.track_count;
        while (first < end) {
            const middle = first + (end - first) / 2;
            const track = self.tracks[self.id_order[middle]];
            if (track.id < id) first = middle + 1 else end = middle;
        }
        if (first == self.track_count) return null;
        const found = self.tracks[self.id_order[first]];
        return if (found.id == id) self.id_order[first] else null;
    }

    pub fn trackById(self: *const Snapshot, id: u64) ?*const core.Track {
        return self.tracks[self.trackIndexById(id) orelse return null];
    }

    pub fn albumForTrack(self: *const Snapshot, id: u64) ?*const Album {
        return &self.albums[self.track_groups[self.trackIndexById(id) orelse return null]];
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

/// Comparators always retain their ordering, even after cancellation. Finish
/// the bounded sort, then reject the inactive view at the next check. Polling
/// never exposes partially sorted membership or requires unwinding a sort.
fn BuildWork(comptime Observer: type) type {
    return struct {
        const Self = @This();
        const Sort = struct { work: *Self, base: Snapshot.SortContext };
        observer: Observer,
        comparisons: usize = 0,
        cancelled: bool = false,

        fn check(self: *Self) !void {
            if (comptime Observer == Uninterrupted) return;
            if (self.cancelled) return error.Cancelled;
            self.poll();
            if (self.cancelled) return error.Cancelled;
        }

        // A callback can contain the board's storage/UI service. Keep one copy
        // out of sort comparators instead of cloning it into every sort path.
        noinline fn poll(self: *Self) void {
            const cancelled = self.observer.cancelled();
            self.cancelled = self.cancelled or cancelled;
        }

        fn step(self: *Self) void {
            if (comptime Observer == Uninterrupted) return;
            self.comparisons += 1;
            if (self.comparisons == comparisons_between_service) {
                self.comparisons = 0;
                self.poll();
            }
        }

        noinline fn lessAlbum(self: *Self, a: Album, b: Album) bool {
            self.step();
            return Snapshot.albumLess({}, a, b);
        }

        noinline fn lessTrack(context: *const Sort, a: u16, b: u16) bool {
            context.work.step();
            return Snapshot.sortedLess(context.base, a, b);
        }
    };
}

pub const Pair = struct {
    slots: [2]Snapshot = undefined,
    published: std.atomic.Value(u32) = .init(0),
    activity: ?*const @import("listening_activity.zig").State = null,

    pub fn publish(self: *Pair, baseline: *const core.Catalog, visited: []const core.Track, source: u64, complete: bool) !void {
        self.commit(try self.prepare(baseline, visited, source, complete));
    }

    pub fn publishCatalogue(self: *Pair, catalogue: *const core.Catalog, source: u64) !void {
        self.commit(try self.prepareCatalogueCooperative(catalogue, source, Uninterrupted{}));
    }

    /// A final view borrows both tracks and artwork from its new owner. Mixing
    /// new tracks with old artwork would retain the arena retired at handoff.
    pub fn prepareCatalogueCooperative(self: *Pair, catalogue: *const core.Catalog, source: u64, observer: anytype) !u32 {
        return self.prepareCooperative(catalogue, catalogue.tracks, source, true, observer);
    }

    /// One storage writer may prepare while UI reads the published slot.
    pub fn prepare(self: *Pair, baseline: *const core.Catalog, visited: []const core.Track, source: u64, complete: bool) !u32 {
        return self.prepareCooperative(baseline, visited, source, complete, Uninterrupted{});
    }

    pub fn prepareCooperative(self: *Pair, baseline: *const core.Catalog, visited: []const core.Track, source: u64, complete: bool, observer: anytype) !u32 {
        const revision = self.published.load(.acquire) +% 1;
        const next: u1 = @truncate(revision);
        try self.slots[next].buildCooperative(baseline, visited, source, complete, revision, observer);
        try self.slots[next].prepareActivity(self.activity, observer);
        return revision;
    }

    /// Refresh only prepared discovery columns after a favourite change. The
    /// active view remains immutable while the storage owner builds its peer.
    pub fn prepareActivity(self: *Pair, observer: anytype) !u32 {
        const revision = self.published.load(.acquire) +% 1;
        const next: u1 = @truncate(revision);
        self.slots[next] = self.current().*;
        self.slots[next].revision = revision;
        try self.slots[next].prepareActivity(self.activity, observer);
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

test "authoritative publication survives retiring the old arena with changed artwork and removed tracks" {
    const a = std.testing.allocator;
    const pair = try a.create(Pair);
    defer a.destroy(pair);
    pair.* = .{};
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1.flac", .stamp = .{}, .meta = .{ .title = "Before", .album = "Album", .album_artist = "Artist" } },
        .{ .id = 2, .path = "B/1.flac", .stamp = .{}, .meta = .{ .title = "Removed", .album = "Other", .album_artist = "Artist" } },
    };
    try pair.publish(&.{}, &tracks, 42, true);
    const album_id = pair.current().albums[pair.current().track_groups[0]].id;
    const album = core.Album{
        .id = album_id,
        .key = "album identity",
        .title = "Album",
        .artist = "Artist",
        .directory = "A",
        .tracks = &.{0},
        .art = .{ .recipe = "rgb565", .source = "A/cover.jpg", .key = "old art", .cache_path = "atlas:1" },
    };
    var old_storage: [16 * 1024]u8 = undefined;
    var old_allocator = std.heap.FixedBufferAllocator.init(&old_storage);
    var old = core.Owned{ .arena = .init(old_allocator.allocator()), .value = .{} };
    var old_live = true;
    defer if (old_live) old.deinit();
    old.value = try core.clone(old.arena.allocator(), core.Catalog{ .source = 42, .tracks = &tracks, .albums = &.{album} });
    try pair.publishCatalogue(&old.value, 42);
    const previous = pair.current();
    var next = core.Owned{ .arena = .init(a), .value = .{} };
    defer next.deinit();
    var changed_track = tracks[0];
    changed_track.meta.title = "After";
    var changed_album = album;
    changed_album.art.key = "new art";
    changed_album.art.source = "A/cover.png";
    changed_album.art.cache_path = "atlas:9";
    next.value = try core.clone(next.arena.allocator(), core.Catalog{ .source = 42, .tracks = &.{changed_track}, .albums = &.{changed_album} });
    const Observer = struct {
        pair: *Pair,
        previous: *const Snapshot,

        pub fn cancelled(self: @This()) bool {
            std.debug.assert(self.pair.current() == self.previous);
            std.debug.assert(self.previous.trackById(2) != null);
            return false;
        }
    };
    const revision = try pair.prepareCatalogueCooperative(&next.value, 42, Observer{ .pair = pair, .previous = previous });
    try std.testing.expect(pair.current() == previous);
    pair.commit(revision);
    // Model the fixed native arena being reused after authoritative publication.
    // Any accidentally borrowed old text now reads poison rather than valid art.
    old.deinit();
    old_live = false;
    @memset(&old_storage, 0xa5);
    const view = pair.current();
    try std.testing.expectEqual(1, view.track_count);
    try std.testing.expect(view.trackById(2) == null);
    try std.testing.expectEqualStrings("After", view.trackById(1).?.meta.title);
    try std.testing.expectEqualStrings("A/1.flac", view.trackById(1).?.path);
    try std.testing.expectEqual(album_id, view.albums[0].id);
    try std.testing.expectEqualStrings("Artist", view.albums[0].artist);
    try std.testing.expectEqualStrings("Album", view.albums[0].title);
    try std.testing.expectEqualStrings("rgb565", view.albums[0].art.recipe);
    try std.testing.expectEqualStrings("A/cover.png", view.albums[0].art.source);
    try std.testing.expectEqualStrings("new art", view.albums[0].art.key);
    try std.testing.expectEqualStrings("atlas:9", view.albums[0].art.cache_path);
}

test "bucketed track orders match full comparison sorts for mixed and skewed libraries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tracks = try a.alloc(core.Track, 1024);
    const view = try a.create(Snapshot);
    var random = std.Random.DefaultPrng.init(0x4741494e);
    const rng = random.random();
    for ([_]usize{ 1, 7, 64, 1024 }) |album_count| {
        for (tracks, 0..) |*track, i| {
            const album = rng.uintLessThan(usize, album_count);
            track.* = .{
                .id = i + 1,
                .path = try std.fmt.allocPrint(a, "Edition {d}/Track {d}.flac", .{ album, i }),
                .stamp = .{},
                .meta = .{
                    .title = try std.fmt.allocPrint(a, "Title {d}", .{rng.uintLessThan(u32, 20)}),
                    .album_artist = try std.fmt.allocPrint(a, "Artist {d}", .{album % 8}),
                    .album = try std.fmt.allocPrint(a, "Album {d}", .{album}),
                    .disc = rng.uintLessThan(u32, 4),
                    .track = rng.uintLessThan(u32, 20),
                },
            };
        }
        std.mem.sort(core.Track, tracks, {}, struct {
            fn less(_: void, left: core.Track, right: core.Track) bool {
                return std.mem.order(u8, left.path, right.path) == .lt;
            }
        }.less);
        try view.build(&.{}, tracks, 1, true, 1);
        var reference: [1024]u16 = undefined;
        for (&reference, 0..) |*track, i| track.* = @intCast(i);
        std.mem.sort(u16, &reference, Snapshot.SortContext{ .view = view, .order = .album }, Snapshot.sortedLess);
        try std.testing.expectEqualSlices(u16, &reference, view.track_order[0..tracks.len]);
        std.mem.sort(u16, &reference, view, struct {
            fn less(v: *const Snapshot, left: u16, right: u16) bool {
                const left_artist = v.albums[v.track_groups[left]].artist_index;
                const right_artist = v.albums[v.track_groups[right]].artist_index;
                if (left_artist != right_artist) return left_artist < right_artist;
                return v.titleLess(left, right);
            }
        }.less);
        try std.testing.expectEqualSlices(u16, &reference, view.artist_track_order[0..tracks.len]);
    }
}

test "cooperative rebuilds service readers without publishing partial sorts or cancelled arenas" {
    const a = std.testing.allocator;
    const pair = try a.create(Pair);
    defer a.destroy(pair);
    pair.* = .{};
    const tracks = try a.alloc(core.Track, max_tracks);
    defer a.free(tracks);
    for (tracks, 0..) |*track, i| track.* = .{ .id = i + 1, .path = "Album/track.flac", .stamp = .{}, .meta = .{ .title = "Synthetic", .album = "Album", .track = @intCast(max_tracks - i) } };
    try pair.publish(&.{}, tracks[0..1], 42, true);
    const old = pair.current();
    const Observer = struct {
        pair: *Pair,
        old: *const Snapshot,
        calls: usize = 0,
        cancel_at: usize = std.math.maxInt(usize),

        pub fn cancelled(self: *@This()) bool {
            std.debug.assert(self.pair.current() == self.old and self.old.track_count == 1);
            self.calls += 1;
            return self.calls == self.cancel_at;
        }
    };
    var observer = Observer{ .pair = pair, .old = old };
    const catalogue = core.Catalog{ .tracks = tracks };
    const revision = try pair.prepareCatalogueCooperative(&catalogue, 42, &observer);
    const calls = observer.calls;
    try std.testing.expect(calls > max_tracks / tracks_between_service);
    const expected = try a.create(Snapshot);
    defer a.destroy(expected);
    try expected.build(&.{}, tracks, 42, true, revision);
    const prepared = &pair.slots[@as(u1, @truncate(revision))];
    try std.testing.expectEqualSlices(u16, expected.track_order[0..max_tracks], prepared.track_order[0..max_tracks]);
    try std.testing.expectEqualSlices(u16, expected.title_order[0..max_tracks], prepared.title_order[0..max_tracks]);
    try std.testing.expectEqualSlices(u16, expected.artist_track_order[0..max_tracks], prepared.artist_track_order[0..max_tracks]);
    try std.testing.expectEqualSlices(u16, expected.id_order[0..max_tracks], prepared.id_order[0..max_tracks]);
    for ([_]usize{ 1, 2, calls / 4, calls / 2, calls - 1 }) |cancel_at| {
        observer = .{ .pair = pair, .old = old, .cancel_at = cancel_at };
        try std.testing.expectError(error.Cancelled, pair.prepareCatalogueCooperative(&catalogue, 42, &observer));
        try std.testing.expect(pair.current() == old);
    }
    observer = .{ .pair = pair, .old = old };
    pair.commit(try pair.prepareCatalogueCooperative(&catalogue, 42, &observer));
    try std.testing.expectEqual(max_tracks, pair.current().track_count);
}

test "ID lookup survives independent display orders and authoritative removal" {
    const a = std.testing.allocator;
    const pair = try a.create(Pair);
    defer a.destroy(pair);
    pair.* = .{};
    const tracks = [_]core.Track{
        .{ .id = 91, .path = "A/1", .stamp = .{}, .meta = .{ .title = "Zulu", .album = "First" } },
        .{ .id = 3, .path = "B/1", .stamp = .{}, .meta = .{ .title = "Alpha", .album = "Last" } },
        .{ .id = 50, .path = "C/1", .stamp = .{}, .meta = .{ .title = "Beta", .album = "Middle" } },
    };
    try pair.publish(&.{}, &tracks, 42, true);
    for (tracks) |track| try std.testing.expectEqualStrings(track.path, pair.current().trackById(track.id).?.path);
    for ([_]u64{ 0, 2, 4, 49, 51, 92, std.math.maxInt(u64) }) |id| try std.testing.expectEqual(null, pair.current().trackById(id));
    try pair.publish(&.{}, tracks[1..], 42, true);
    try std.testing.expectEqual(null, pair.current().trackById(91));
    try std.testing.expectEqualStrings("B/1", pair.current().trackById(3).?.path);
}

test "verification previews retain unvisited queue occurrences until final removals and reject foreign membership" {
    const old = [_]core.Track{
        .{ .id = 1, .path = "A/1.flac", .stamp = .{}, .meta = .{ .title = "Old A", .album = "A" } },
        .{ .id = 2, .path = "B/1.flac", .stamp = .{}, .meta = .{ .title = "B", .album = "B" } },
        .{ .id = 3, .path = "C/1.flac", .stamp = .{}, .meta = .{ .title = "C", .album = "C" } },
    };
    const visited = [_]core.Track{
        .{ .id = 1, .path = "A/1.flac", .stamp = .{}, .meta = .{ .title = "Verified A", .album = "A" } },
        .{ .id = 4, .path = "D/1.flac", .stamp = .{}, .meta = .{ .title = "New D", .album = "D" } },
    };
    const catalog = core.Catalog{ .source = 42, .tracks = &old, .playlists = &.{.{ .name = "Old mix", .path = "Old.m3u8", .items = &.{} }} };
    const pair = try std.testing.allocator.create(Pair);
    defer std.testing.allocator.destroy(pair);
    pair.* = .{};
    const baseline = previewBaseline(&catalog, 42);
    try pair.publish(&baseline, &visited, 42, false);
    try std.testing.expectEqualStrings("Verified A", pair.current().trackById(1).?.meta.title);
    try std.testing.expectEqual(4, pair.current().track_count);
    try std.testing.expectEqual(1, pair.current().playlists.len);
    var bytes: [8 * 16]u8 = undefined;
    var queue = @import("play_queue.zig").Queue.init(&bytes);
    try queue.insert(&.{ 1, 2, 3 }, false);
    const Resolver = struct {
        view: *const Snapshot,
        pub fn contains(resolver: @This(), id: u64) bool {
            return resolver.view.trackById(id) != null;
        }
    };
    try std.testing.expectEqual(2, queue.adjacent(1, Resolver{ .view = pair.current() }).?);
    try std.testing.expectEqual(3, queue.adjacent(1, Resolver{ .view = pair.current() }).?);
    try std.testing.expectEqual(3, queue.count); // A scan never extends the queue.
    try pair.publish(&baseline, &visited, 42, true);
    try std.testing.expect(queue.select(1));
    try std.testing.expectEqual(null, queue.adjacent(1, Resolver{ .view = pair.current() }));
    const foreign = previewBaseline(&catalog, 43);
    try std.testing.expectEqual(0, foreign.tracks.len);
    try std.testing.expectEqual(0, foreign.playlists.len);
    try std.testing.expectEqual(0, foreign.albums.len);
    try pair.publish(&foreign, &visited, 43, false);
    try std.testing.expectEqual(2, pair.current().track_count);
    try std.testing.expectEqual(null, pair.current().trackById(2));
}

test "two complete verification scans retire alternating arenas during one uninterrupted PCM stream" {
    const pcm = @import("pcm_reservoir.zig");
    const store = @import("catalog_store.zig");
    const Harness = struct {
        pair: *Pair,
        ring: pcm.Ring,
        produced: i32 = 64,
        played: i32 = 0,
        checkpoints: usize = 0,
        card: []u8,
        position: usize = 0,
        writes: usize = 0,

        pub fn cancelled(self: *@This()) bool {
            var frames: [16]pcm.StereoFrame = undefined;
            for (&frames) |*frame| {
                const audible = self.ring.pop() orelse @panic("indexing starved PCM");
                std.debug.assert(audible.left == self.played and audible.right == -self.played);
                self.played += 1;
                frame.* = .{ .left = self.produced, .right = -self.produced };
                self.produced += 1;
            }
            std.debug.assert(self.ring.write(&frames) == frames.len);
            return false;
        }

        pub fn progress(self: *@This(), _: []const u8, _: core.Stats, _: u32) void {
            _ = self.cancelled();
        }

        pub fn checkpoint(self: *@This(), previous: *const core.Catalog, tracks: []const core.Track, _: core.Stats) !void {
            const baseline = previewBaseline(previous, 42);
            const revision = try self.pair.prepareCooperative(&baseline, tracks, 42, false, self);
            self.pair.commit(revision);
            self.checkpoints += 1;
        }

        pub fn seekTo(self: *@This(), offset: u32) !void {
            if (offset > self.card.len) return error.OutOfBounds;
            self.position = offset;
        }

        pub fn write(self: *@This(), bytes: []const u8) !void {
            if (bytes.len > self.card.len - self.position) return error.OutOfBounds;
            @memcpy(self.card[self.position..][0..bytes.len], bytes);
            self.position += bytes.len;
            self.writes += 1;
        }

        pub fn sync(_: *@This()) !void {}

        fn poll(context: *anyopaque) bool {
            return @as(*@This(), @ptrCast(@alignCast(context))).cancelled();
        }
    };
    const Backend = struct {
        entries: []const core.Entry,
        title: []const u8 = "Original",
        art: []const u8 = "original artwork",

        pub fn enumerate(self: *@This(), a: std.mem.Allocator) !core.Enumeration {
            return .{ .source = 42, .entries = try core.clone(a, self.entries) };
        }

        pub fn metadata(self: *@This(), a: std.mem.Allocator, _: core.Entry) !core.Metadata {
            return .{ .title = try core.text(a, self.title), .album = "Album", .album_artist = "Artist" };
        }

        pub fn artwork(self: *@This(), a: std.mem.Allocator, _: core.Album, _: []const core.Track, _: []const core.Entry, _: ?core.Artwork, _: core.Mode) !core.Artwork {
            return .{ .key = try core.text(a, self.art), .cache_path = try core.text(a, "atlas:1") };
        }

        pub fn playlist(_: *@This(), _: std.mem.Allocator, _: []const u8, _: []const core.Track) !core.Playlist {
            return error.NoPlaylist;
        }
    };
    const a = std.testing.allocator;
    const pair = try a.create(Pair);
    defer a.destroy(pair);
    pair.* = .{};
    const storage = try a.alloc(u8, 2 * 256 * 1024);
    defer a.free(storage);
    const card = try a.alloc(u8, 4096 + 2 * 64 * 1024);
    defer a.free(card);
    @memset(card, 0);
    var allocators = [_]std.heap.FixedBufferAllocator{
        .init(storage[0 .. 256 * 1024]),
        .init(storage[256 * 1024 ..]),
    };
    var frames: [128]pcm.StereoFrame = undefined;
    for (frames[0..64], 0..) |*frame, i| frame.* = .{ .left = @intCast(i), .right = -@as(i32, @intCast(i)) };
    var harness = Harness{ .pair = pair, .ring = try pcm.Ring.initFilled(&frames, 64), .card = card };
    var names: [65][32]u8 = undefined;
    var entries: [65]core.Entry = undefined;
    for (&names, &entries, 0..) |*name, *entry, i| entry.* = .{
        .path = try std.fmt.bufPrint(name, "Music/Album/{d:0>2}.flac", .{i}),
        .kind = .audio,
        .stamp = .{ .size = 100, .modified = 1 },
    };
    var backend = Backend{ .entries = entries[0..64] };
    var current = try core.scanWithScratch(allocators[0].allocator(), a, &backend, &.{}, .verify, &harness);
    defer current.deinit();
    try pair.publishCatalogue(&current.value, 42);
    var selected_bytes: [8192]u8 = undefined;
    var selected = @import("track_selection.zig").Store.init(&selected_bytes);
    _ = try selected.queue(&current.value.tracks[0]);
    const now_playing = selected.begin().?;
    const playing_id = now_playing.id;
    var current_slot: usize = 0;
    var committed: ?store.Header = null;
    var buffer: [4096]u8 = undefined;
    var writes_before: usize = 0;
    var played_before = harness.played;
    const Service = struct { context: *anyopaque, poll: *const fn (*anyopaque) bool };
    const service: ?Service = .{ .context = &harness, .poll = Harness.poll };
    for (0..2) |pass| {
        backend.title = if (pass == 0) "Retag one" else "Retag two";
        backend.art = if (pass == 0) "new artwork one" else "new artwork two";
        backend.entries = entries[0 .. 65 - pass];
        const target = current_slot ^ 1;
        allocators[target].reset();
        var next = try core.scanWithScratch(allocators[target].allocator(), a, &backend, &current.value, .verify, &harness);
        errdefer next.deinit();
        const revision = try pair.prepareCatalogueCooperative(&next.value, 42, &harness);
        pair.commit(revision);
        var cancelled = false;
        var writer = @import("owned_io.zig").wrap(&harness, service, &cancelled);
        committed = try store.save(&writer, &next.value, committed, 64 * 1024, &buffer);
        current.deinit();
        @memset(storage[current_slot * 256 * 1024 ..][0 .. 256 * 1024], 0xa5);
        current = next;
        current_slot = target;
        try std.testing.expectEqual(pass + 2, current.value.generation);
        try std.testing.expectEqual(65 - pass, pair.current().track_count);
        try std.testing.expectEqualStrings(backend.title, pair.current().trackById(playing_id).?.meta.title);
        try std.testing.expectEqualStrings(backend.art, pair.current().albums[0].art.key);
        try std.testing.expectEqualStrings("Original", now_playing.meta.title);
        const base = 4096 + @as(usize, committed.?.bank) * 64 * 1024;
        const header = store.parseHeader(card[base..][0..512], committed.?.bank, 64 * 1024).?;
        try std.testing.expectEqual(current.value.generation, header.generation);
        try std.testing.expectEqual(header.checksum, std.hash.Crc32.hash(card[base + 512 ..][0..header.length]));
        try std.testing.expect(harness.writes > writes_before and harness.played > played_before);
        try std.testing.expectEqual(64, harness.ring.available());
        writes_before = harness.writes;
        played_before = harness.played;
    }
    try std.testing.expect(harness.checkpoints >= 3);
    try std.testing.expect(harness.ring.read_sequence.load(.acquire) > 0);
    try std.testing.expectEqual(harness.produced - 64, harness.played);
}
