//! Portable catalogue and reconciliation policy. No filesystem, clock, decoder or UI dependency.
const std = @import("std");

const A = std.mem.Allocator;

pub const Mode = enum { quick, verify };

pub const Kind = enum { audio, directory, playlist, artwork };

pub const Stamp = struct {
    size: u64 = 0,
    modified: i64 = 0,
    device: u64 = 0,
    inode: u64 = 0,

    pub fn same(a: Stamp, b: Stamp) bool {
        return a.size == b.size and a.modified == b.modified and a.device == b.device and a.inode == b.inode;
    }

    pub fn identity(a: Stamp, b: Stamp) bool {
        return a.inode != 0 and a.device == b.device and a.inode == b.inode;
    }
};

pub const Entry = struct { path: []const u8, kind: Kind, stamp: Stamp = .{} };

pub const Enumeration = struct { source: u64, entries: []const Entry };

pub const Gain = struct { track_db: ?f64 = null, album_db: ?f64 = null, track_peak: ?f64 = null, album_peak: ?f64 = null };

pub const Metadata = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    album_artist: []const u8 = "",
    album: []const u8 = "",
    genre: []const u8 = "",
    date: []const u8 = "",
    sort_artist: []const u8 = "",
    sort_album_artist: []const u8 = "",
    release_id: []const u8 = "",
    release_track_id: []const u8 = "",
    codec: []const u8 = "",
    track: u32 = 0,
    disc: u32 = 0,
    compilation: bool = false,
    duration_ms: u64 = 0,
    sample_rate: u32 = 0,
    channels: u32 = 0,
    bits: u32 = 0,
    gain: Gain = .{},
    embedded_art: bool = false,
    tag_digest: []const u8 = "",
    title_from_file: bool = false,
    album_from_context: bool = false,
    artist_from_context: bool = false,
    album_artist_from_context: bool = false,
};

pub const Track = struct { id: u64, path: []const u8, stamp: Stamp, meta: Metadata, album_index: u32 = 0, error_name: []const u8 = "" };

pub const Artwork = struct {
    recipe: []const u8 = "",
    source: []const u8 = "",
    stamp: Stamp = .{},
    key: []const u8 = "",
    cache_path: []const u8 = "",
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 112,
    height: u16 = 112,
    error_name: []const u8 = "",
};

pub const Album = struct {
    id: u64,
    key: []const u8,
    title: []const u8,
    artist: []const u8,
    directory: []const u8,
    tracks: []const u32,
    art: Artwork = .{},
};

pub const Artist = struct { name: []const u8, albums: []const u32 };

pub const PlaylistItem = struct { track_id: u64 = 0, path: []const u8, missing: bool = false };

pub const Playlist = struct { path: []const u8, name: []const u8, items: []const PlaylistItem };

pub const Stats = struct {
    candidates: u32 = 0,
    visited: u32 = 0,
    parsed: u32 = 0,
    reused: u32 = 0,
    added: u32 = 0,
    changed: u32 = 0,
    renamed: u32 = 0,
    removed: u32 = 0,
    errors: u32 = 0,
    art_prepared: u32 = 0,
    art_reused: u32 = 0,
};

pub const Catalog = struct {
    version: u32 = 1,
    source: u64 = 0,
    generation: u64 = 0,
    entries: []const Entry = &.{},
    tracks: []const Track = &.{},
    albums: []const Album = &.{},
    artists: []const Artist = &.{},
    playlists: []const Playlist = &.{},
    stats: Stats = .{},

    pub fn trackById(self: *const Catalog, id: u64) ?usize {
        for (self.tracks, 0..) |track, i| if (track.id == id) return i;
        return null;
    }

    pub fn albumById(self: *const Catalog, id: u64) ?usize {
        for (self.albums, 0..) |album, i| if (album.id == id) return i;
        return null;
    }
};

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Catalog,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }

    pub fn bytes(self: *const Owned) usize {
        return self.arena.queryCapacity();
    }
};

pub fn hash(value: []const u8) u64 {
    return std.hash.Wyhash.hash(0x4741494e, value);
}

pub fn text(a: A, value: []const u8) ![]const u8 {
    return a.dupe(u8, value);
}

pub fn clone(a: A, value: anytype) !@TypeOf(value) {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) @compileError("Only slice ownership is cloned");
            const out = try a.alloc(p.child, value.len);
            for (out, value) |*destination, source| destination.* = try clone(a, source);
            return out;
        },
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.field_names) |name| @field(out, name) = try clone(a, @field(value, name));
            return out;
        },
        else => return value,
    }
}

fn equalMeta(left: Metadata, right: Metadata) bool {
    inline for (@typeInfo(Metadata).@"struct".field_names) |name| {
        const l = @field(left, name);
        const r = @field(right, name);
        if (@TypeOf(l) == []const u8) {
            if (!std.mem.eql(u8, l, r)) return false;
        } else if (!std.meta.eql(l, r)) return false;
    }
    return true;
}

fn fallback(a: A, path: []const u8, meta: *Metadata) !void {
    if (meta.title.len == 0 or meta.title_from_file) {
        meta.title = try text(a, std.fs.path.stem(path));
        meta.title_from_file = true;
    }
    meta.album_from_context = meta.album.len == 0 or meta.album_from_context;
    meta.artist_from_context = meta.artist.len == 0 or meta.artist_from_context;
    meta.album_artist_from_context = meta.album_artist.len == 0 or meta.album_artist_from_context;
    if (meta.album_from_context) meta.album = try text(a, std.fs.path.basename(editionRoot(path)));
    if (meta.artist_from_context) meta.artist = if (!meta.album_artist_from_context) meta.album_artist else "Unknown Artist";
    if (meta.album_artist_from_context) meta.album_artist = if (meta.compilation) "Various Artists" else meta.artist;
    if (meta.disc == 0) meta.disc = 1;
}

pub fn editionRoot(path: []const u8) []const u8 {
    const directory = std.fs.path.dirname(path) orelse "";
    const leaf = std.fs.path.basename(directory);
    const prefix = [_][]const u8{ "disc ", "disc", "disk ", "cd ", "cd" };
    for (prefix) |part| {
        if (leaf.len > part.len and std.ascii.eqlIgnoreCase(leaf[0..part.len], part)) {
            _ = std.fmt.parseInt(u32, leaf[part.len..], 10) catch continue;
            return std.fs.path.dirname(directory) orelse directory;
        }
    }
    return directory;
}

pub fn lessText(left: []const u8, right: []const u8) bool {
    var l: usize = 0;
    var r: usize = 0;
    while (l < left.len and r < right.len) {
        if (std.ascii.isDigit(left[l]) and std.ascii.isDigit(right[r])) {
            var le = l;
            var re = r;
            while (le < left.len and std.ascii.isDigit(left[le])) : (le += 1) {}
            while (re < right.len and std.ascii.isDigit(right[re])) : (re += 1) {}
            var ls = l;
            var rs = r;
            while (ls < le and left[ls] == '0') : (ls += 1) {}
            while (rs < re and right[rs] == '0') : (rs += 1) {}
            if (le - ls != re - rs) return le - ls < re - rs;
            const order = std.mem.order(u8, left[ls..le], right[rs..re]);
            if (order != .eq) return order == .lt;
            l = le;
            r = re;
            continue;
        }
        const lc = std.ascii.toLower(left[l]);
        const rc = std.ascii.toLower(right[r]);
        if (lc != rc) return lc < rc;
        l += 1;
        r += 1;
    }
    if (l != left.len or r != right.len) return l == left.len;
    return std.mem.order(u8, left, right) == .lt;
}

fn albumLess(_: void, left: Album, right: Album) bool {
    if (!std.ascii.eqlIgnoreCase(left.artist, right.artist)) return lessText(left.artist, right.artist);
    if (!std.ascii.eqlIgnoreCase(left.title, right.title)) return lessText(left.title, right.title);
    return std.mem.order(u8, left.key, right.key) == .lt;
}

fn trackLess(tracks: []const Track, left: u32, right: u32) bool {
    const a = tracks[left];
    const b = tracks[right];
    if (a.meta.disc != b.meta.disc) return a.meta.disc < b.meta.disc;
    if (a.meta.track != 0 and b.meta.track != 0 and a.meta.track != b.meta.track) return a.meta.track < b.meta.track;
    return lessText(a.path, b.path);
}

/// Backend owns enumeration, bounded metadata, artwork and playlist I/O. Observer
/// provides cancellation/progress. Only a complete successful pass returns a new catalogue.
pub fn scan(allocator: A, backend: anytype, previous: *const Catalog, mode: Mode, observer: anytype) !Owned {
    return scanWithScratch(allocator, allocator, backend, previous, mode, observer);
}

/// Temporary maps/arrays can use memory released before playback; retained
/// strings and records stay in the returned catalogue's owning arena.
pub fn scanWithScratch(allocator: A, scratch: A, backend: anytype, previous: *const Catalog, mode: Mode, observer: anytype) !Owned {
    if (previous.generation == std.math.maxInt(u64)) return error.CatalogueGeneration;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        // Withdraw borrowed progressive views before their arena is reclaimed.
        if (comptime @hasDecl(@typeInfo(@TypeOf(observer)).pointer.child, "aborted")) observer.aborted(previous);
        arena.deinit();
    }
    const a = arena.allocator();
    if (observer.cancelled()) return error.Cancelled;
    const enumeration = try backend.enumerate(a);
    if (observer.cancelled()) return error.Cancelled;
    const same_source = previous.source == enumeration.source;
    var result = Catalog{ .source = enumeration.source, .generation = previous.generation + 1, .entries = enumeration.entries };
    var old_paths = std.StringHashMap(usize).init(scratch);
    defer old_paths.deinit();
    if (same_source) for (previous.tracks, 0..) |track, index| try old_paths.put(track.path, index);

    const FileId = struct { device: u64, inode: u64 };

    const Match = struct { index: usize, ambiguous: bool = false };
    var old_files = std.AutoHashMap(FileId, Match).init(scratch);
    defer old_files.deinit();
    var reserved_ids = std.AutoHashMap(u64, void).init(scratch);
    defer reserved_ids.deinit();
    if (same_source) for (previous.tracks, 0..) |track, index| {
        try reserved_ids.put(track.id, {});
        if (track.stamp.inode != 0) {
            const match = try old_files.getOrPut(.{ .device = track.stamp.device, .inode = track.stamp.inode });
            if (match.found_existing) match.value_ptr.ambiguous = true else match.value_ptr.* = .{ .index = index };
        }
    };

    const seen = try a.alloc(bool, previous.tracks.len);
    @memset(seen, false);

    for (enumeration.entries) |entry| {
        if (entry.kind == .audio) result.stats.candidates += 1;
    }
    const track_storage = try a.alloc(Track, result.stats.candidates);
    var track_count: usize = 0;
    observer.progress("Reading tags", result.stats, 0);
    for (enumeration.entries) |entry| {
        if (entry.kind != .audio) continue;
        if (observer.cancelled()) return error.Cancelled;
        const old_index = old_paths.get(entry.path);
        var old: ?Track = if (old_index) |index| previous.tracks[index] else null;
        if (old_index) |index| seen[index] = true;
        // File IDs are optional backend evidence, never a FAT starting cluster.
        if (old == null and same_source and entry.stamp.inode != 0) {
            if (old_files.get(.{ .device = entry.stamp.device, .inode = entry.stamp.inode })) |match| {
                if (!match.ambiguous and !seen[match.index]) {
                    old = previous.tracks[match.index];
                    seen[match.index] = true;
                    result.stats.renamed += 1;
                }
            }
        }
        var track: Track = undefined;
        if (old != null and entry.stamp.same(old.?.stamp) and mode == .quick and old.?.error_name.len == 0) {
            track = old.?;
            track.path = entry.path;
            track.meta = try clone(a, old.?.meta);
            try fallback(a, entry.path, &track.meta);
            result.stats.reused += 1;
        } else {
            track = .{
                .id = if (old) |value| value.id else hash(entry.path) ^ enumeration.source,
                .path = entry.path,
                .stamp = entry.stamp,
                .meta = .{},
            };
            if (old == null) {
                while (track.id == 0 or reserved_ids.contains(track.id)) track.id = std.hash.Wyhash.hash(track.id +% 1, std.mem.asBytes(&result.generation));
                try reserved_ids.put(track.id, {});
            }
            track.meta = backend.metadata(a, entry) catch |err| failed: {
                if (err == error.Cancelled or err == error.OutOfMemory) return err;
                track.error_name = try text(a, @errorName(err));
                result.stats.errors += 1;
                // Preserve a previously valid record on a transient per-file failure.
                if (old) |value| break :failed try clone(a, value.meta);
                break :failed Metadata{};
            };
            try fallback(a, entry.path, &track.meta);
            result.stats.parsed += 1;
            if (old == null) result.stats.added += 1;
        }
        track.stamp = entry.stamp;
        track_storage[track_count] = track;
        track_count += 1;
        result.stats.visited += 1;
        if (result.stats.visited % 32 == 0) observer.progress("Reading tags", result.stats, 0);
        if (comptime @hasDecl(@typeInfo(@TypeOf(observer)).pointer.child, "checkpoint")) {
            if (result.stats.visited == 32 or result.stats.visited % 128 == 0)
                try observer.checkpoint(previous, track_storage[0..track_count], result.stats);
        }
    }
    if (same_source) for (seen) |found| {
        if (!found) result.stats.removed += 1;
    };
    result.tracks = track_storage[0..track_count];
    const mutable_tracks: []Track = @constCast(result.tracks);

    // One conservative context per directory, built in linear time. Missing tags
    // inherit only unanimous album fields; mixed folders keep explicit editions.
    const Hint = struct { meta: Metadata, ambiguous: bool = false };
    var hints = std.StringHashMap(Hint).init(scratch);
    defer hints.deinit();
    for (result.tracks) |peer| {
        if (peer.meta.album_from_context or peer.error_name.len != 0) continue;
        const hint = try hints.getOrPut(editionRoot(peer.path));
        if (!hint.found_existing) hint.value_ptr.* = .{ .meta = peer.meta } else {
            const known = hint.value_ptr.meta;
            if (!std.mem.eql(u8, known.album, peer.meta.album) or !std.mem.eql(u8, known.album_artist, peer.meta.album_artist) or !std.mem.eql(u8, known.release_id, peer.meta.release_id)) hint.value_ptr.ambiguous = true;
        }
    }
    for (mutable_tracks) |*track| {
        if (hints.get(editionRoot(track.path))) |hint| {
            if (hint.ambiguous) continue;
            if (track.meta.album_from_context) {
                if (comptime @hasDecl(@typeInfo(@TypeOf(observer)).pointer.child, "replaceText")) observer.replaceText(&track.meta.album, hint.meta.album) else track.meta.album = hint.meta.album;
            }
            if (track.meta.album_artist_from_context and std.mem.eql(u8, track.meta.album, hint.meta.album)) {
                if (comptime @hasDecl(@typeInfo(@TypeOf(observer)).pointer.child, "replaceText")) observer.replaceText(&track.meta.album_artist, hint.meta.album_artist) else track.meta.album_artist = hint.meta.album_artist;
            }
        }
    }
    if (same_source) {
        var old_ids = std.AutoHashMap(u64, usize).init(scratch);
        defer old_ids.deinit();
        for (previous.tracks, 0..) |track, i| try old_ids.put(track.id, i);
        for (result.tracks) |track| if (old_ids.get(track.id)) |old_meta| {
            if (!equalMeta(previous.tracks[old_meta].meta, track.meta)) result.stats.changed += 1;
        };
    }
    var groups = std.StringHashMap(usize).init(scratch);
    defer groups.deinit();
    var albums: std.ArrayList(Album) = .empty;
    defer albums.deinit(scratch);
    var members: std.ArrayList(std.ArrayList(u32)) = .empty;
    defer {
        for (members.items) |*list| list.deinit(scratch);
        members.deinit(scratch);
    }
    const key_buffer = try scratch.alloc(u8, 16 * 1024);
    defer scratch.free(key_buffer);
    for (result.tracks, 0..) |track, index| {
        const directory = editionRoot(track.path);
        const key = try std.fmt.bufPrint(key_buffer, "{s}\x1f{s}\x1f{s}\x1f{s}", .{
            track.meta.release_id,
            track.meta.album_artist,
            track.meta.album,
            directory,
        });
        const group = try groups.getOrPut(key);
        if (!group.found_existing) {
            const owned_key = try text(a, key);
            group.key_ptr.* = owned_key;
            group.value_ptr.* = albums.items.len;
            try albums.append(scratch, .{
                .id = hash(key) ^ result.source,
                .key = owned_key,
                .title = track.meta.album,
                .artist = track.meta.album_artist,
                .directory = directory,
                .tracks = &.{},
            });
            try members.append(scratch, .empty);
        }
        try members.items[group.value_ptr.*].append(scratch, @intCast(index));
    }
    for (albums.items, members.items) |*album, member| {
        const list = try a.dupe(u32, member.items);
        std.mem.sort(u32, list, result.tracks, trackLess);
        album.tracks = list;
    }
    std.mem.sort(Album, albums.items, {}, albumLess);
    var old_albums = std.StringHashMap(*const Album).init(scratch);
    defer old_albums.deinit();
    if (same_source) for (previous.albums) |*album| try old_albums.put(album.key, album);
    for (albums.items, 0..) |*album, index| {
        if (observer.cancelled()) return error.Cancelled;
        for (album.tracks) |track| mutable_tracks[track].album_index = @intCast(index);
        const old = old_albums.get(album.key);
        album.art = backend.artwork(a, album.*, result.tracks, result.entries, if (old) |value| value.art else null, mode) catch |err| failed: {
            if (err == error.Cancelled or err == error.OutOfMemory) return err;
            var fallback_art: Artwork = if (old) |value| try clone(a, value.art) else .{};
            fallback_art.error_name = try text(a, @errorName(err));
            break :failed fallback_art;
        };
        if (album.art.error_name.len != 0) result.stats.errors += 1;
        if (album.art.key.len != 0) {
            if (old != null and std.mem.eql(u8, old.?.art.key, album.art.key)) result.stats.art_reused += 1 else result.stats.art_prepared += 1;
        }
        observer.progress("Preparing covers", result.stats, @intCast(index + 1));
    }
    result.albums = try a.dupe(Album, albums.items);
    var artists: std.ArrayList(Artist) = .empty;
    defer artists.deinit(scratch);
    var artist_first: usize = 0;
    while (artist_first < result.albums.len) {
        const name = result.albums[artist_first].artist;
        var artist_end = artist_first + 1;
        while (artist_end < result.albums.len and std.mem.eql(u8, result.albums[artist_end].artist, name)) : (artist_end += 1) {}
        const items = try a.alloc(u32, artist_end - artist_first);
        for (items, artist_first..) |*item, index| item.* = @intCast(index);
        try artists.append(scratch, .{ .name = name, .albums = items });
        artist_first = artist_end;
    }
    result.artists = try a.dupe(Artist, artists.items);
    var playlists: std.ArrayList(Playlist) = .empty;
    defer playlists.deinit(scratch);
    for (result.entries) |entry| if (entry.kind == .playlist) {
        const playlist = backend.playlist(a, entry.path, result.tracks) catch |err| {
            if (err == error.Cancelled or err == error.OutOfMemory) return err;
            result.stats.errors += 1;
            continue;
        };
        try playlists.append(scratch, playlist);
    };
    result.playlists = try a.dupe(Playlist, playlists.items);
    if (observer.cancelled()) return error.Cancelled;
    observer.progress("Ready", result.stats, @intCast(result.albums.len));
    return .{ .arena = arena, .value = result };
}

/// Resolve playlist references within the virtual card root, without I/O.
pub fn playlistPath(a: A, playlist: []const u8, value: []const u8) !?[]const u8 {
    if (value.len == 0 or std.mem.indexOf(u8, value, "://") != null or (value.len >= 2 and value[1] == ':')) return null;
    const normalized = try a.dupe(u8, value);
    for (normalized) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };

    const resolved = try std.fs.path.resolvePosix(a, &.{ "/", std.fs.path.dirname(playlist) orelse "", normalized });
    return if (std.mem.startsWith(u8, resolved, "/")) resolved[1..] else resolved;
}
