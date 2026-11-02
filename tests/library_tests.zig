const std = @import("std");
const core = @import("library");
const Fake = struct {
    entries: []const core.Entry,
    fail: bool = false,
    title: []const u8 = "Track",
    album: []const u8 = "Album",
    cover: []const u8 = "image-a",
    calls: usize = 0,
    source: u64 = 1,
    metadata_error: bool = false,
    missing_leaf: []const u8 = "",
    other_leaf: []const u8 = "",
    pub fn enumerate(self: *@This(), a: std.mem.Allocator) !core.Enumeration {
        if (self.fail) return error.Disconnected;
        return .{ .source = self.source, .entries = try core.clone(a, self.entries) };
    }
    pub fn metadata(self: *@This(), a: std.mem.Allocator, entry: core.Entry) !core.Metadata {
        self.calls += 1;
        if (self.metadata_error) return error.CorruptTags;
        if (std.mem.eql(u8, std.fs.path.basename(entry.path), self.missing_leaf)) return .{};
        return .{ .title = try core.text(a, self.title), .artist = "Artist", .album_artist = "Artist", .album = try core.text(a, if (std.mem.eql(u8, std.fs.path.basename(entry.path), self.other_leaf)) "Other Album" else self.album) };
    }
    pub fn artwork(self: *@This(), a: std.mem.Allocator, _: core.Album, _: []const core.Track, _: []const core.Entry, _: ?core.Artwork, _: core.Mode) !core.Artwork {
        return .{ .key = try core.text(a, self.cover) };
    }
    pub fn playlist(_: *@This(), _: std.mem.Allocator, _: []const u8, _: []const core.Track) !core.Playlist {
        return error.NoPlaylist;
    }
};
test "an untagged neighbour follows unanimous retags but never guesses in an ambiguous folder" {
    var entries = [_]core.Entry{ .{ .path = "Folder/1.flac", .kind = .audio, .stamp = .{ .modified = 1 } }, .{ .path = "Folder/2.flac", .kind = .audio }, .{ .path = "Folder/3.flac", .kind = .audio } };
    var backend = Fake{ .entries = entries[0..2], .missing_leaf = "2.flac" };
    var observer = Observer{};
    var first = try core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.value.albums.len);
    try std.testing.expect(first.value.tracks[1].meta.title_from_file);
    entries[0].stamp.modified += 1;
    backend.album = "Retagged Album";
    var second = try core.scan(std.testing.allocator, &backend, &first.value, .quick, &observer);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.value.albums.len);
    try std.testing.expectEqualStrings("Retagged Album", second.value.tracks[1].meta.album);
    backend.entries = &entries;
    backend.other_leaf = "3.flac";
    var third = try core.scan(std.testing.allocator, &backend, &second.value, .quick, &observer);
    defer third.deinit();
    try std.testing.expectEqual(@as(usize, 3), third.value.albums.len);
    try std.testing.expectEqualStrings("Folder", third.value.tracks[1].meta.album);
}
test "reusing a renamed filename cannot produce duplicate stable track IDs" {
    var entries = [_]core.Entry{ .{ .path = "Album/A.flac", .kind = .audio, .stamp = .{ .device = 1, .inode = 10 } }, .{ .path = "Album/B.flac", .kind = .audio, .stamp = .{ .device = 1, .inode = 10 } } };
    var backend = Fake{ .entries = entries[0..1] };
    var observer = Observer{};
    var first = try core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer);
    defer first.deinit();
    backend.entries = entries[1..2];
    var renamed = try core.scan(std.testing.allocator, &backend, &first.value, .quick, &observer);
    defer renamed.deinit();
    entries[0].stamp.inode = 11;
    backend.entries = &entries;
    var recreated = try core.scan(std.testing.allocator, &backend, &renamed.value, .quick, &observer);
    defer recreated.deinit();
    try std.testing.expect(recreated.value.tracks[0].id != recreated.value.tracks[1].id);
    try std.testing.expectEqual(first.value.tracks[0].id, recreated.value.tracks[1].id);
}
test "rename retains identity, updates fallback title, and deletion is committed only after enumeration" {
    var entries = [_]core.Entry{.{ .path = "Album/2.m4a", .kind = .audio, .stamp = .{ .size = 10, .modified = 1, .device = 1, .inode = 22 } }};
    var backend = Fake{ .entries = &entries, .title = "" };
    var observer = Observer{};
    var first = try core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer);
    defer first.deinit();
    const id = first.value.tracks[0].id;
    entries[0].path = "Album/10.m4a";
    var second = try core.scan(std.testing.allocator, &backend, &first.value, .quick, &observer);
    defer second.deinit();
    try std.testing.expectEqual(id, second.value.tracks[0].id);
    try std.testing.expectEqualStrings("10", second.value.tracks[0].meta.title);
    try std.testing.expectEqual(@as(u32, 1), second.value.stats.renamed);
    backend.entries = &.{};
    var empty = try core.scan(std.testing.allocator, &backend, &second.value, .quick, &observer);
    defer empty.deinit();
    try std.testing.expectEqual(@as(u32, 1), empty.value.stats.removed);
    try std.testing.expectEqual(@as(usize, 0), empty.value.albums.len);
}
test "transient metadata failure preserves known tags and is retried on the next quick scan" {
    var entries = [_]core.Entry{.{ .path = "Album/1.m4a", .kind = .audio, .stamp = .{ .size = 10, .modified = 1 } }};
    var backend = Fake{ .entries = &entries };
    var observer = Observer{};
    var first = try core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer);
    defer first.deinit();
    entries[0].stamp.modified = 2;
    backend.metadata_error = true;
    var failed = try core.scan(std.testing.allocator, &backend, &first.value, .quick, &observer);
    defer failed.deinit();
    try std.testing.expectEqualStrings("Track", failed.value.tracks[0].meta.title);
    try std.testing.expectEqualStrings("CorruptTags", failed.value.tracks[0].error_name);
    backend.metadata_error = false;
    backend.title = "Recovered";
    var recovered = try core.scan(std.testing.allocator, &backend, &failed.value, .quick, &observer);
    defer recovered.deinit();
    try std.testing.expectEqualStrings("Recovered", recovered.value.tracks[0].meta.title);
    try std.testing.expectEqual(@as(u32, 1), recovered.value.stats.parsed);
}
test "different cards cannot inherit cached metadata even when paths and stamps match" {
    var backend = Fake{ .entries = &.{.{ .path = "Album/1.m4a", .kind = .audio, .stamp = .{ .size = 10 } }} };
    var observer = Observer{};
    var first = try core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer);
    defer first.deinit();
    backend.source = 2;
    backend.title = "Other card";
    backend.calls = 0;
    var second = try core.scan(std.testing.allocator, &backend, &first.value, .quick, &observer);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), backend.calls);
    try std.testing.expect(first.value.tracks[0].id != second.value.tracks[0].id);
}
test "disc folders merge while duplicate editions remain separate and unnumbered files sort naturally" {
    var backend = Fake{ .entries = &.{
        .{ .path = "Release/Disc 1/10.m4a", .kind = .audio }, .{ .path = "Release/Disc 1/2.m4a", .kind = .audio },
        .{ .path = "Release/CD2/1.m4a", .kind = .audio },     .{ .path = "Other Edition/1.m4a", .kind = .audio },
    } };
    var observer = Observer{};
    var result = try core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.value.albums.len);
    const release = if (result.value.albums[0].tracks.len == 3) result.value.albums[0] else result.value.albums[1];
    // CD2 precedes Disc 1 lexically when tags are absent; within a directory 2 precedes 10.
    try std.testing.expect(core.lessText("2.m4a", "10.m4a"));
    try std.testing.expectEqual(@as(usize, 3), release.tracks.len);
}
test "cancellation at every progress boundary never returns a partial generation" {
    const Cancel = struct {
        calls: u32 = 0,
        at: u32,
        pub fn cancelled(self: *@This()) bool {
            return self.calls >= self.at;
        }
        pub fn progress(self: *@This(), _: []const u8, _: core.Stats, _: u32) void {
            self.calls += 1;
        }
    };
    var backend = Fake{ .entries = &.{.{ .path = "Album/1.m4a", .kind = .audio }} };
    for (0..4) |step| {
        var observer = Cancel{ .at = @intCast(step) };
        if (step < 3) try std.testing.expectError(error.Cancelled, core.scan(std.testing.allocator, &backend, &.{}, .verify, &observer)) else {
            var result = try core.scan(std.testing.allocator, &backend, &.{}, .verify, &observer);
            defer result.deinit();
        }
    }
}

const Model = struct {
    const Node = struct { active: bool = false, revision: u32 = 1, renamed: bool = false };
    nodes: [16]Node = @splat(.{}),
    source: u64 = 7,
    cover: u32 = 0,
    pub fn enumerate(self: *@This(), a: std.mem.Allocator) !core.Enumeration {
        var list: std.ArrayList(core.Entry) = .empty;
        defer list.deinit(std.testing.allocator);
        for (self.nodes, 0..) |node, i| if (node.active) {
            const path = try std.fmt.allocPrint(a, "Artist/Album {d}/{s}{d}.flac", .{ i / 4, if (node.renamed) "renamed-" else "track-", i });
            try list.append(std.testing.allocator, .{ .path = path, .kind = .audio, .stamp = .{ .size = 100, .modified = node.revision, .device = 1, .inode = i + 1 } });
        };
        return .{ .source = self.source, .entries = try a.dupe(core.Entry, list.items) };
    }
    pub fn metadata(self: *@This(), a: std.mem.Allocator, entry: core.Entry) !core.Metadata {
        const i = entry.stamp.inode - 1;
        const node = self.nodes[i];
        return .{ .title = try std.fmt.allocPrint(a, "Title {d} revision {d}", .{ i, node.revision }), .album = try std.fmt.allocPrint(a, "Album {d}", .{i / 4}), .artist = "Artist", .album_artist = "Artist", .track = @intCast(i % 4 + 1), .disc = 1 };
    }
    pub fn artwork(self: *@This(), a: std.mem.Allocator, _: core.Album, _: []const core.Track, _: []const core.Entry, _: ?core.Artwork, _: core.Mode) !core.Artwork {
        return .{ .key = try std.fmt.allocPrint(a, "cover-{d}", .{self.cover}) };
    }
    pub fn playlist(_: *@This(), _: std.mem.Allocator, _: []const u8, _: []const core.Track) !core.Playlist {
        return error.Unused;
    }
};
test "deterministic stateful reconciliation matches a fresh rebuild after 512 mixed operations" {
    var model = Model{};
    var observer = Observer{};
    var previous = try core.scan(std.testing.allocator, &model, &.{}, .quick, &observer);
    defer previous.deinit();
    var seed: u64 = 0x4741494e;
    for (0..512) |step| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const index: usize = @intCast((seed >> 32) % 16);
        switch ((seed >> 16) % 6) {
            0 => model.nodes[index].active = !model.nodes[index].active,
            1 => model.nodes[index].revision += 1,
            2 => model.nodes[index].renamed = !model.nodes[index].renamed,
            3 => model.cover += 1,
            4 => {
                if (step % 13 == 0) model.source += 1;
            },
            else => {},
        }
        const incremental = try core.scan(std.testing.allocator, &model, &previous.value, if (step % 7 == 0) .verify else .quick, &observer);
        var reference = try core.scan(std.testing.allocator, &model, &.{}, .verify, &observer);
        defer reference.deinit();
        try std.testing.expectEqual(reference.value.tracks.len, incremental.value.tracks.len);
        try std.testing.expectEqual(reference.value.albums.len, incremental.value.albums.len);
        for (reference.value.tracks, incremental.value.tracks) |expected, actual| {
            try std.testing.expectEqualStrings(expected.path, actual.path);
            try std.testing.expectEqualStrings(expected.meta.title, actual.meta.title);
            try std.testing.expectEqual(expected.album_index, actual.album_index);
        }
        for (reference.value.albums, incremental.value.albums) |expected, actual| {
            try std.testing.expectEqualStrings(expected.key, actual.key);
            try std.testing.expectEqualSlices(u32, expected.tracks, actual.tracks);
            try std.testing.expectEqualStrings(expected.art.key, actual.art.key);
        }
        previous.deinit();
        previous = incremental;
    }
}
const Observer = struct {
    cancel: bool = false,
    pub fn cancelled(self: *@This()) bool {
        return self.cancel;
    }
    pub fn progress(_: *@This(), _: []const u8, _: core.Stats, _: u32) void {}
};
test "complete discovery groups tracks and quick reconciliation avoids metadata reads" {
    var backend = Fake{ .entries = &.{ .{ .path = "Artist/Album/01.m4a", .kind = .audio, .stamp = .{ .size = 10, .modified = 1 } }, .{ .path = "Artist/Album/02.m4a", .kind = .audio, .stamp = .{ .size = 10, .modified = 1 } } } };
    var observer = Observer{};
    var first = try core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.value.tracks.len);
    try std.testing.expectEqual(@as(usize, 1), first.value.albums.len);
    backend.calls = 0;
    var second = try core.scan(std.testing.allocator, &backend, &first.value, .quick, &observer);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
    try std.testing.expectEqual(@as(u32, 2), second.value.stats.reused);
}
test "preserved-stat retag is found by verification and cover is reused" {
    var backend = Fake{ .entries = &.{.{ .path = "Artist/Album/01.m4a", .kind = .audio, .stamp = .{ .size = 10, .modified = 1 } }} };
    var observer = Observer{};
    var first = try core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer);
    defer first.deinit();
    backend.title = "New title";
    var second = try core.scan(std.testing.allocator, &backend, &first.value, .verify, &observer);
    defer second.deinit();
    try std.testing.expectEqualStrings("New title", second.value.tracks[0].meta.title);
    try std.testing.expectEqual(@as(u32, 1), second.value.stats.changed);
    try std.testing.expectEqual(@as(u32, 1), second.value.stats.art_reused);
}
test "failed enumeration and cancellation cannot replace the last complete catalogue" {
    var backend = Fake{ .entries = &.{}, .fail = true };
    var observer = Observer{};
    try std.testing.expectError(error.Disconnected, core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer));
    backend.fail = false;
    observer.cancel = true;
    try std.testing.expectError(error.Cancelled, core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer));
}

test "a 4500-track cold scan and refresh fit the F20 catalogue memory budget" {
    const a = std.testing.allocator;
    var source_arena = std.heap.ArenaAllocator.init(a);
    defer source_arena.deinit();
    const source = source_arena.allocator();
    const entries = try source.alloc(core.Entry, 4500);
    for (entries, 0..) |*entry, i| entry.* = .{ .path = try std.fmt.allocPrint(source, "Music/Artist {d}/Album {d}/Track {d}.m4a", .{ i / 140, i / 14, i }), .kind = .audio, .stamp = .{ .size = 6000000, .modified = 123 } };
    const first_memory = try a.alloc(u8, 6 * 1024 * 1024);
    defer a.free(first_memory);
    const next_memory = try a.alloc(u8, first_memory.len);
    defer a.free(next_memory);
    var first_allocator = std.heap.FixedBufferAllocator.init(first_memory);
    var next_allocator = std.heap.FixedBufferAllocator.init(next_memory);
    var fake = Fake{ .entries = entries, .title = "A fairly long track title with Unicode 架空楽団", .album = "An album title, including an edition (2026)" };
    var observer: Observer = .{};
    const temporary = try a.alloc(u8, 4 * 1024 * 1024);
    defer a.free(temporary);
    var scratch = std.heap.FixedBufferAllocator.init(temporary);
    var first = try core.scanWithScratch(first_allocator.allocator(), scratch.allocator(), &fake, &.{}, .quick, &observer);
    defer first.deinit();
    scratch.reset();
    var next = try core.scanWithScratch(next_allocator.allocator(), scratch.allocator(), &fake, &first.value, .quick, &observer);
    defer next.deinit();
    try std.testing.expectEqual(4500, first.value.tracks.len);
    try std.testing.expectEqual(0, next.value.stats.parsed);
    try std.testing.expectEqual(4500, next.value.stats.reused);
    for (first.value.tracks, next.value.tracks) |before, after| try std.testing.expectEqual(before.id, after.id);
}

test "I/O cancellation is propagated even if a one-shot cancel signal was consumed" {
    const Backend = struct {
        pub fn enumerate(_: *@This(), _: std.mem.Allocator) !core.Enumeration {
            return .{ .source = 1, .entries = &.{.{ .path = "Album/1.m4a", .kind = .audio }} };
        }
        pub fn metadata(_: *@This(), _: std.mem.Allocator, _: core.Entry) !core.Metadata {
            return error.Cancelled;
        }
        pub fn artwork(_: *@This(), _: std.mem.Allocator, _: core.Album, _: []const core.Track, _: []const core.Entry, _: ?core.Artwork, _: core.Mode) !core.Artwork {
            return .{};
        }
        pub fn playlist(_: *@This(), _: std.mem.Allocator, _: []const u8, _: []const core.Track) !core.Playlist {
            return error.NoPlaylist;
        }
    };
    var backend: Backend = .{};
    var observer: Observer = .{};
    try std.testing.expectError(error.Cancelled, core.scan(std.testing.allocator, &backend, &.{}, .quick, &observer));
}

test "playlist paths use a virtual card root and preserve Unicode without opening URLs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Music/楽団/1.m4a", (try core.playlistPath(a, "Playlists/Favourites.m3u", "../Music/楽団/1.m4a")).?);
    try std.testing.expectEqualStrings("Music/A/1.flac", (try core.playlistPath(a, "Root.m3u", "Music\\A\\1.flac")).?);
    try std.testing.expectEqualStrings("Music/1.wav", (try core.playlistPath(a, "Playlists/List.m3u", "/Music/1.wav")).?);
    try std.testing.expect((try core.playlistPath(a, "List.m3u", "https://example.invalid/music")) == null);
    try std.testing.expect((try core.playlistPath(a, "List.m3u", "C:\\Music\\1.wav")) == null);
}
