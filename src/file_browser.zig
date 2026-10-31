//! Folder navigation shared by the F20 application and device qualification.
const fat32 = @import("fat32.zig");
const player_view = @import("player_view.zig");
const maximum_depth = 8;
const visible_rows = player_view.visible_rows;
pub fn Browser(comptime Volume: type) type {
    return struct {
        const Self = @This();
        directories: [maximum_depth]fat32.Directory = undefined,
        selections: [maximum_depth]usize = @splat(0),
        counts: [maximum_depth]usize = @splat(0),
        titles: [maximum_depth][fat32.maximum_name_bytes]u8 = @splat(@splat(0)),
        title_lengths: [maximum_depth]u8 = @splat(0),
        depth: usize = 0,

        pub fn init(volume: *Volume) !Self {
            var self = Self{};
            self.directories[0] = volume.rootDirectory();
            @memcpy(self.titles[0][0..7], "SD CARD");
            self.title_lengths[0] = 7;
            self.counts[0] = try countEntries(Volume, volume, self.directories[0]);
            return self;
        }

        pub fn directory(self: *const Self) fat32.Directory {
            return self.directories[self.depth];
        }

        pub fn selection(self: *const Self) usize {
            return self.selections[self.depth];
        }

        pub fn title(self: *const Self) []const u8 {
            return self.titles[self.depth][0..self.title_lengths[self.depth]];
        }

        pub fn move(self: *Self, direction: i2) void {
            const count = self.counts[self.depth];
            if (count == 0) return;
            var selected = self.selections[self.depth];
            if (direction > 0) {
                selected = (selected + 1) % count;
            } else if (selected == 0) {
                selected = count - 1;
            } else {
                selected -= 1;
            }
            self.selections[self.depth] = selected;
        }

        pub fn selectedEntry(self: *const Self, volume: *Volume) !?fat32.DirectoryEntry {
            var iterator = try volume.iterate(self.directory());
            var index: usize = 0;
            while (try iterator.next()) |entry| {
                if (!isVisibleEntry(&entry)) continue;
                if (index == self.selection()) return entry;
                index += 1;
            }
            return null;
        }

        pub fn enter(self: *Self, volume: *Volume, entry: fat32.DirectoryEntry) !void {
            if (self.depth + 1 == maximum_depth) return;
            const next = try entry.directory();
            const count = try countEntries(Volume, volume, next);
            self.depth += 1;
            self.directories[self.depth] = next;
            self.selections[self.depth] = 0;
            self.counts[self.depth] = count;
            const length = @min(entry.name().len, fat32.maximum_name_bytes);
            @memcpy(self.titles[self.depth][0..length], entry.name()[0..length]);
            self.title_lengths[self.depth] = @intCast(length);
        }

        pub fn back(self: *Self) void {
            if (self.depth != 0) self.depth -= 1;
        }

        pub fn home(self: *Self) void {
            self.depth = 0;
        }
        pub fn draw(browser: *const Self, volume: *Volume, scene: *@import("ui.zig").Ui, battery_mv: u32, attenuation: u8, theme: @import("ui.zig").Theme) !void {
            try player_view.browser(scene, browser.title(), browser.counts[browser.depth] == 0, battery_mv, attenuation, theme);

            const count = browser.counts[browser.depth];
            if (count == 0) {} else {
                const selected = browser.selection();
                const first = if (selected >= visible_rows) selected - (visible_rows - 1) else 0;
                var iterator = try volume.iterate(browser.directory());
                var index: usize = 0;
                var row: usize = 0;
                while (try iterator.next()) |entry| {
                    if (!isVisibleEntry(&entry)) continue;
                    if (index >= first and row < visible_rows) {
                        try player_view.browserRow(scene, row, entry.name(), entry.kind == .directory, index == selected, theme);
                        row += 1;
                    }
                    index += 1;
                    if (row == visible_rows) break;
                }
            }
        }
        pub fn adjacentTrack(
            browser: *Self,
            volume: *Volume,
            direction: i2,
        ) !?fat32.DirectoryEntry {
            const count = browser.counts[browser.depth];
            var attempts: usize = 0;
            while (attempts < count) : (attempts += 1) {
                browser.move(direction);
                const candidate = try browser.selectedEntry(volume) orelse return null;
                if (candidate.kind == .file) return candidate;
            }
            return null;
        }
    };
}
pub fn isVisibleEntry(entry: *const fat32.DirectoryEntry) bool {
    if (entry.attributes & 0x06 != 0) return false;
    const name = entry.name();
    if (name.len == 0 or (name.len == 1 and name[0] == '.') or
        (name.len == 2 and name[0] == '.' and name[1] == '.')) return false;
    if (entry.kind == .directory) return true;
    for (player_view.audio_extensions) |suffix| {
        if (endsWithIgnoreCase(name, suffix)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    const start = value.len - suffix.len;
    for (value[start..], suffix) |left, right| {
        const normalized = if (left >= 'A' and left <= 'Z') left + ('a' - 'A') else left;
        if (normalized != right) return false;
    }
    return true;
}

fn countEntries(comptime Volume: type, volume: *Volume, directory: fat32.Directory) !usize {
    var iterator = try volume.iterate(directory);
    var count: usize = 0;
    while (try iterator.next()) |entry| {
        if (isVisibleEntry(&entry)) count += 1;
    }
    return count;
}

const FakeVolume = struct {
    fail: bool = false,
    const Iterator = struct {
        entries: []const fat32.DirectoryEntry,
        position: usize = 0,
        pub fn next(self: *Iterator) !?fat32.DirectoryEntry {
            if (self.position == self.entries.len) return null;
            defer self.position += 1;
            return self.entries[self.position];
        }
    };
    pub fn rootDirectory(_: *FakeVolume) fat32.Directory {
        return .{ .first_cluster = 2 };
    }
    pub fn iterate(self: *FakeVolume, directory: fat32.Directory) !Iterator {
        if (self.fail) return error.CardRemoved;
        return .{ .entries = if (directory.first_cluster == 2) &root else &folder };
    }
    fn entry(comptime name: []const u8, kind: fat32.EntryKind, cluster: u32) fat32.DirectoryEntry {
        var result = fat32.DirectoryEntry{ .kind = kind, .first_cluster = cluster, .size = 32, .attributes = 0 };
        @memcpy(result.name_bytes[0..name.len], name);
        result.name_length = name.len;
        return result;
    }
    const root = [_]fat32.DirectoryEntry{ entry("Albums", .directory, 3), entry("notes.txt", .file, 4), entry("track.FLAC", .file, 5), entry("other.opus", .file, 6) };
    const folder = [_]fat32.DirectoryEntry{entry("song.m4a", .file, 7)};
};
test "real browser restores parent selection and skips unsupported files during navigation" {
    const testing = @import("std").testing;
    var volume = FakeVolume{};
    var browser = try Browser(FakeVolume).init(&volume);
    try testing.expectEqual(@as(usize, 3), browser.counts[0]);
    const directory = (try browser.selectedEntry(&volume)).?;
    try browser.enter(&volume, directory);
    try testing.expectEqualStrings("Albums", browser.title());
    try testing.expectEqualStrings("song.m4a", (try browser.selectedEntry(&volume)).?.name());
    browser.back();
    try testing.expectEqual(@as(usize, 0), browser.selection());
    try testing.expectEqualStrings("track.FLAC", (try browser.adjacentTrack(&volume, 1)).?.name());
    try testing.expectEqualStrings("other.opus", (try browser.adjacentTrack(&volume, 1)).?.name());
    try testing.expectEqualStrings("track.FLAC", (try browser.adjacentTrack(&volume, 1)).?.name());
}
test "directory read failure leaves browser position and title intact" {
    const testing = @import("std").testing;
    var volume = FakeVolume{};
    var browser = try Browser(FakeVolume).init(&volume);
    const entry = (try browser.selectedEntry(&volume)).?;
    volume.fail = true;
    try testing.expectError(error.CardRemoved, browser.enter(&volume, entry));
    try testing.expectEqual(@as(usize, 0), browser.depth);
    try testing.expectEqualStrings("SD CARD", browser.title());
    try testing.expectEqual(@as(usize, 0), browser.selection());
}
