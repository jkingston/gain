//! Filesystem names from the scanner's directory snapshot, independent of tags.
//! No filesystem access occurs while navigating or painting. Catalogue-only
//! fixtures can derive the same tree from track paths without private fixtures.
const std = @import("std");
const core = @import("library.zig");

pub const Source = struct {
    entries: []const core.Entry,
    tracks: []const *const core.Track,

    fn count(self: Source) usize {
        return self.entries.len + self.tracks.len;
    }

    fn entryPath(self: Source, i: usize) []const u8 {
        return if (i < self.entries.len) self.entries[i].path else self.tracks[i - self.entries.len].path;
    }

    fn child(self: Source, i: usize, directory: []const u8) ?Row {
        const path = self.entryPath(i);
        var relative = path;
        if (directory.len != 0) {
            if (!std.mem.startsWith(u8, path, directory) or path.len <= directory.len or path[directory.len] != '/') return null;
            relative = path[directory.len + 1 ..];
        }
        if (relative.len == 0 or relative[0] == '.') return null;
        if (i < self.entries.len) {
            const kind = self.entries[i].kind;
            if ((kind != .audio and kind != .directory) or std.mem.indexOfScalar(u8, relative, '/') != null) return null;
            return .{ .name = relative, .path = path, .directory = kind == .directory };
        }
        const row: Row = if (std.mem.indexOfScalar(u8, relative, '/')) |end| .{ .name = relative[0..end], .path = path[0 .. path.len - relative.len + end], .directory = true } else .{ .name = relative, .path = path, .directory = false };
        // Scanner entries are bytewise path-sorted. Avoid adding the same raw
        // entry again, while still discovering new folders in a scan preview.
        var first: usize = 0;
        var end = self.entries.len;
        while (first < end) {
            const middle = first + (end - first) / 2;
            switch (std.mem.order(u8, self.entries[middle].path, row.path)) {
                .lt => first = middle + 1,
                .gt => end = middle,
                .eq => return null,
            }
        }
        return row;
    }
};

pub const Row = struct { name: []const u8, path: []const u8, directory: bool };

pub const View = struct {
    order: [8192]u32 = undefined,
    count: usize = 0,

    pub fn build(self: *View, source: Source, directory: []const u8) !void {
        self.count = 0;
        for (0..source.count()) |i| {
            if (source.child(i, directory) == null) continue;
            if (self.count == self.order.len) return error.DirectoryTooLarge;
            self.order[self.count] = @intCast(i);
            self.count += 1;
        }
        const Sort = struct {
            source: Source,
            directory: []const u8,
            fn less(ctx: @This(), a: u32, b: u32) bool {
                const left = ctx.source.child(a, ctx.directory).?;
                const right = ctx.source.child(b, ctx.directory).?;
                if (left.directory != right.directory) return left.directory;
                return core.lessText(left.name, right.name);
            }
        };
        std.mem.sort(u32, self.order[0..self.count], Sort{ .source = source, .directory = directory }, Sort.less);
        var unique: usize = 0;
        for (self.order[0..self.count]) |i| {
            const item = source.child(i, directory).?;
            if (unique != 0 and std.mem.eql(u8, source.child(self.order[unique - 1], directory).?.name, item.name)) continue;
            self.order[unique] = i;
            unique += 1;
        }
        self.count = unique;
    }

    pub fn row(self: *const View, source: Source, directory: []const u8, position: usize) ?Row {
        if (position >= self.count) return null;
        return source.child(self.order[position], directory);
    }
};

test "filesystem folders retain empty directories, natural filenames and component boundaries" {
    const entries = [_]core.Entry{
        .{ .path = "Music", .kind = .directory },
        .{ .path = "Music/Empty", .kind = .directory },
        .{ .path = "Music/10.flac", .kind = .audio },
        .{ .path = "Music/2.flac", .kind = .audio },
        .{ .path = "Music/.hidden.flac", .kind = .audio },
        .{ .path = "Music/Cover.jpg", .kind = .artwork },
        .{ .path = "Music-old/1.flac", .kind = .audio },
    };
    const source = Source{ .entries = &entries, .tracks = &.{} };
    var view = View{};
    try view.build(source, "Music");
    try std.testing.expectEqual(3, view.count);
    try std.testing.expect(view.row(source, "Music", 0).?.directory);
    try std.testing.expectEqualStrings("2.flac", view.row(source, "Music", 1).?.name);
    try std.testing.expectEqualStrings("10.flac", view.row(source, "Music", 2).?.name);
    try view.build(source, "Music/Empty");
    try std.testing.expectEqual(0, view.count);
}

test "catalogue-only mounts derive unique directory children" {
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "Music/A/1.flac", .stamp = .{}, .meta = .{} },
        .{ .id = 2, .path = "Music/A/2.flac", .stamp = .{}, .meta = .{} },
        .{ .id = 3, .path = "Music/B/1.flac", .stamp = .{}, .meta = .{} },
    };
    const pointers = [_]*const core.Track{ &tracks[0], &tracks[1], &tracks[2] };
    const source = Source{ .entries = &.{}, .tracks = &pointers };
    var view = View{};
    try view.build(source, "");
    try std.testing.expectEqual(1, view.count);
    try view.build(source, "Music");
    try std.testing.expectEqual(2, view.count);
    try std.testing.expectEqualStrings("A", view.row(source, "Music", 0).?.name);
}

test "preview paths introduce new children beside the retained filesystem snapshot" {
    const entries = [_]core.Entry{.{ .path = "Old", .kind = .directory }};
    const track = core.Track{ .id = 1, .path = "New/1.flac", .stamp = .{}, .meta = .{} };
    const source = Source{ .entries = &entries, .tracks = &.{&track} };
    var view = View{};
    try view.build(source, "");
    try std.testing.expectEqual(2, view.count);
    try std.testing.expectEqualStrings("New", view.row(source, "", 0).?.name);
    try std.testing.expectEqualStrings("Old", view.row(source, "", 1).?.name);
}
