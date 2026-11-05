//! Read-only directory adapter for the production library scanner. The caller
//! chooses any mock directory, mounted card or folder of real media.
const std = @import("std");
const gain = @import("gain_ui");
const core = gain.library;
const A = std.mem.Allocator;

pub const Hooks = struct {
    context: *anyopaque,
    cancelled: *const fn (*anyopaque) bool,
    progress: *const fn (*anyopaque, []const u8, core.Stats, u32) void,
    checkpoint: *const fn (*anyopaque, *const core.Catalog, []const core.Track, core.Stats) anyerror!void,
    aborted: *const fn (*anyopaque, *const core.Catalog) void,
    replace_text: *const fn (*anyopaque, *[]const u8, []const u8) void,
};

pub const Backend = struct {
    root: std.Io.Dir,
    io: std.Io,
    source: u64,
    hooks: Hooks,

    pub fn cancelled(self: *Backend) bool {
        return self.hooks.cancelled(self.hooks.context);
    }

    pub fn progress(self: *Backend, phase: []const u8, stats: core.Stats, count: u32) void {
        self.hooks.progress(self.hooks.context, phase, stats, count);
    }

    pub fn checkpoint(self: *Backend, old: *const core.Catalog, tracks: []const core.Track, stats: core.Stats) !void {
        try self.hooks.checkpoint(self.hooks.context, old, tracks, stats);
    }

    pub fn aborted(self: *Backend, old: *const core.Catalog) void {
        self.hooks.aborted(self.hooks.context, old);
    }

    pub fn replaceText(self: *Backend, destination: *[]const u8, text: []const u8) void {
        self.hooks.replace_text(self.hooks.context, destination, text);
    }

    pub fn enumerate(self: *Backend, a: A) !core.Enumeration {
        var entries: std.ArrayList(core.Entry) = .empty;
        try self.walk(a, self.root, "", 0, &entries);
        std.mem.sort(core.Entry, entries.items, {}, struct {
            fn less(_: void, left: core.Entry, right: core.Entry) bool {
                return std.mem.order(u8, left.path, right.path) == .lt;
            }
        }.less);
        return .{ .source = self.source, .entries = try entries.toOwnedSlice(a) };
    }

    fn walk(self: *Backend, a: A, directory: std.Io.Dir, parent: []const u8, depth: usize, entries: *std.ArrayList(core.Entry)) anyerror!void {
        if (depth >= 16) return error.LibraryLimit;
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (self.cancelled()) return error.Cancelled;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (entries.items.len >= 100_000) return error.LibraryLimit;
            const path = if (parent.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, entry.name });
            // A mount may be represented by a directory symlink in a mock card.
            // Files are always opened read-only; no cache writes target this root.
            if (entry.kind == .directory or entry.kind == .sym_link) {
                if (directory.openDir(self.io, entry.name, .{ .iterate = true })) |child| {
                    defer child.close(self.io);
                    try entries.append(a, .{ .path = path, .kind = .directory });
                    try self.walk(a, child, path, depth + 1, entries);
                    continue;
                } else |failure| if (entry.kind == .directory) return failure;
            }
            const kind = classify(entry.name) orelse continue;
            const stat = try self.root.statFile(self.io, path, .{});
            if (stat.kind != .file) continue;
            try entries.append(a, .{
                .path = path,
                .kind = kind,
                .stamp = .{ .size = stat.size, .modified = std.math.cast(i64, stat.mtime.nanoseconds) orelse return error.TimestampOutOfRange, .inode = stat.inode, .device = self.source },
            });
        }
    }

    fn classify(name: []const u8) ?core.Kind {
        const extension = std.fs.path.extension(name);
        for (gain.player_view.audio_extensions) |suffix| if (std.ascii.eqlIgnoreCase(extension, suffix)) return .audio;
        for ([_][]const u8{ ".jpg", ".jpeg", ".png" }) |suffix| if (std.ascii.eqlIgnoreCase(extension, suffix)) return .artwork;
        if (std.ascii.eqlIgnoreCase(extension, ".m3u") or std.ascii.eqlIgnoreCase(extension, ".m3u8")) return .playlist;
        return null;
    }

    const Reader = struct {
        file: std.Io.File,
        io: std.Io,
        at: u64 = 0,
        backend: *Backend,

        pub fn seekTo(self: *Reader, at: u32) !void {
            self.at = at;
        }

        pub fn read(self: *Reader, bytes: []u8) !usize {
            if (self.backend.cancelled()) return error.Cancelled;
            const count = try self.file.readPositional(self.io, &.{bytes}, self.at);
            self.at += count;
            return count;
        }
    };

    pub fn metadata(self: *Backend, a: A, entry: core.Entry) !core.Metadata {
        const file = try self.root.openFile(self.io, entry.path, .{});
        defer file.close(self.io);
        var reader = Reader{ .file = file, .io = self.io, .backend = self };
        var cache: [64 * 1024]u8 = undefined;
        var source = try gain.media_source.Source(Reader).init(&reader, entry.stamp.size, &cache);
        const result = try gain.library_metadata.extract(a, &source, std.fs.path.extension(entry.path));
        const after = try file.stat(self.io);
        if (after.size != entry.stamp.size or after.mtime.nanoseconds != entry.stamp.modified) return error.ChangedDuringScan;
        return result;
    }

    pub fn artwork(_: *Backend, a: A, album: core.Album, tracks: []const core.Track, entries: []const core.Entry, previous: ?core.Artwork, mode: core.Mode) !core.Artwork {
        var selected = core.sidecarArtwork(entries, album.directory);
        if (selected == null) for (album.tracks) |rank| {
            const track = tracks[rank];
            if (track.meta.embedded_art) {
                selected = .{ .path = track.path, .kind = .audio, .stamp = track.stamp };
                break;
            }
        };
        const chosen = selected orelse return .{};
        if (previous) |old| if (mode == .quick and std.mem.eql(u8, old.source, chosen.path) and old.stamp.same(chosen.stamp) and std.mem.eql(u8, old.recipe, "host-source-v1")) return core.clone(a, old);
        return .{
            .source = chosen.path,
            .recipe = "host-source-v1",
            .stamp = chosen.stamp,
            .cache_path = if (chosen.kind == .artwork) "image" else "embedded",
            .key = try std.fmt.allocPrint(a, "{x}:{d}:{d}", .{ core.hash(chosen.path), chosen.stamp.size, chosen.stamp.modified }),
        };
    }

    pub fn playlist(self: *Backend, a: A, path: []const u8, tracks: []const core.Track) !core.Playlist {
        const bytes = try self.root.readFileAlloc(self.io, path, a, .limited(1024 * 1024));
        var items: std.ArrayList(core.PlaylistItem) = .empty;
        var lines = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes, '\n');
        while (lines.next()) |line| {
            const text = std.mem.trim(u8, line, " \r\t");
            if (text.len == 0 or text[0] == '#') continue;
            const resolved = (try core.playlistPath(a, path, text)) orelse continue;
            var item = core.PlaylistItem{ .path = resolved, .missing = true };
            for (tracks) |track| if (std.mem.eql(u8, track.path, resolved)) {
                item.track_id = track.id;
                item.missing = false;
                break;
            };
            try items.append(a, item);
        }
        return .{ .path = path, .name = std.fs.path.stem(path), .items = try items.toOwnedSlice(a) };
    }
};
