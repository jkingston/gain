//! F20 adapters for the portable catalogue. All locators belong to this mount;
//! persistent identity uses paths/stamps, never starting clusters or POSIX IDs.
const std = @import("std");
const core = @import("library.zig");
const media = @import("library_metadata.zig");
const fat = @import("filesystem.zig");
const storage = @import("f20_storage.zig");
const memory = @import("f20_memory.zig");
const x = @import("x1000.zig");
const art = @import("artwork.zig");

const A = std.mem.Allocator;
pub const Volume = fat.Volume(storage.Controller);

pub const Hooks = struct {
    context: *anyopaque,
    poll: *const fn (*anyopaque) bool,
    progress: *const fn (*anyopaque, []const u8, core.Stats, u32) void,
    checkpoint: ?*const fn (*anyopaque, *const core.Catalog, []const core.Track, core.Stats) anyerror!void = null,
    aborted: ?*const fn (*anyopaque, *const core.Catalog) void = null,
};

pub const Metrics = struct {
    source_bytes: u64 = 0,
    metadata_ticks: u64 = 0,
    artwork_ticks: u64 = 0,
    enumeration_ticks: u64 = 0,
    metadata_max: u32 = 0,
    artwork_max: u32 = 0,
    art_prepared: u32 = 0,
    art_reused: u32 = 0,
};

pub const Backend = struct {
    volume: *Volume,
    hooks: Hooks,
    allocator: A,
    files: std.StringHashMap(fat.File),
    metrics: Metrics = .{},
    artpack: ?ArtPack = null,
    concurrent: bool = false,

    pub fn replaceText(_: *Backend, destination: *[]const u8, value: []const u8) void {
        // A slice is two words on MIPS. Do not expose a torn pointer/length to
        // the preemptive UI when final folder-context inheritance refines it.
        const masks = x.Interrupts.disableCpu();
        destination.* = value;
        x.Interrupts.restoreCpu(masks);
    }

    pub fn checkpoint(self: *Backend, previous: *const core.Catalog, tracks: []const core.Track, stats: core.Stats) !void {
        if (self.hooks.checkpoint) |callback| try callback(self.hooks.context, previous, tracks, stats);
    }

    pub fn aborted(self: *Backend, previous: *const core.Catalog) void {
        if (self.hooks.aborted) |callback| callback(self.hooks.context, previous);
    }

    fn bounce(self: *Backend) []u8 {
        return if (self.concurrent) memory.scan_io.uncachedSlice(u8)[0..65536] else memory.storage_burst.uncachedSlice(u8);
    }

    fn cache(self: *Backend) []u8 {
        return if (self.concurrent) memory.scan_io.cachedSlice(u8)[65536..] else memory.decoder_cache.cachedSlice(u8);
    }

    pub fn init(volume: *Volume, hooks: Hooks, allocator: A) Backend {
        return .{ .volume = volume, .hooks = hooks, .allocator = allocator, .files = std.StringHashMap(fat.File).init(allocator) };
    }

    pub fn deinit(self: *Backend) void {
        if (self.artpack) |*pack| pack.entries.deinit();
        self.files.deinit();
    }

    pub fn cancelled(self: *Backend) bool {
        return self.hooks.poll(self.hooks.context);
    }

    pub fn progress(self: *Backend, phase: []const u8, stats: core.Stats, covers: u32) void {
        self.hooks.progress(self.hooks.context, phase, stats, covers);
    }

    pub fn enumerate(self: *Backend, a: A) !core.Enumeration {
        const began = x.Timer.now();
        defer self.metrics.enumeration_ticks += x.Timer.elapsed(began);
        // Reserve locator buckets before the growing entry vector. With the
        // fixed allocator its last allocation can then grow in place, instead
        // of retaining interleaved old vector/map allocations during discovery.
        try self.reserveEnumeration();
        var entries: std.ArrayList(core.Entry) = .empty;
        defer entries.deinit(self.allocator);
        try self.walk(a, self.volume.rootDirectory(), "", 0, &entries);
        std.mem.sort(core.Entry, entries.items, {}, struct {
            fn less(_: void, left: core.Entry, right: core.Entry) bool {
                return std.mem.order(u8, left.path, right.path) == .lt;
            }
        }.less);
        return .{ .source = self.volume.serial, .entries = try a.dupe(core.Entry, entries.items) };
    }

    fn reserveEnumeration(self: *Backend) !void {
        try self.files.ensureTotalCapacity(8192);
    }

    fn walk(self: *Backend, a: A, directory: fat.Directory, parent: []const u8, depth: usize, entries: *std.ArrayList(core.Entry)) anyerror!void {
        if (depth >= 16 or entries.items.len > 100_000) return error.LibraryLimit;
        var iterator = try self.volume.iterate(directory);
        while (try iterator.next()) |entry| {
            if (self.cancelled()) return error.Cancelled;
            const name = entry.name();
            if (name.len == 0 or name[0] == '.' or entry.attributes & 6 != 0) continue;
            const path = if (parent.len == 0) try core.text(a, name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, name });
            if (entry.kind == .directory) {
                try self.walk(a, try entry.directory(), path, depth + 1, entries);
                continue;
            }
            const extension = std.fs.path.extension(name);
            var kind: ?core.Kind = null;
            for (@import("player_view.zig").audio_extensions) |suffix| if (std.ascii.eqlIgnoreCase(extension, suffix)) {
                kind = .audio;
                break;
            };
            for ([_][]const u8{ ".jpg", ".jpeg", ".png" }) |suffix| if (std.ascii.eqlIgnoreCase(extension, suffix)) {
                kind = .artwork;
                break;
            };
            if (std.ascii.eqlIgnoreCase(extension, ".m3u") or std.ascii.eqlIgnoreCase(extension, ".m3u8")) kind = .playlist;
            if (kind) |value| {
                try entries.append(self.allocator, .{
                    .path = path,
                    .kind = value,
                    .stamp = .{ .size = entry.size, .modified = entry.modified, .device = self.volume.serial },
                });
                try self.files.put(path, try entry.file());
            }
        }
    }

    const Reader = struct {
        raw: Volume.Reader,
        backend: *Backend,

        pub fn seekTo(self: *Reader, at: u32) !void {
            try self.raw.seekTo(at);
        }

        pub fn read(self: *Reader, out: []u8) !usize {
            if (self.backend.cancelled()) return error.Cancelled;
            var buffered = try storage.BufferedReader(Volume.Reader).init(&self.raw, self.backend.bounce());
            const n = try buffered.read(out);
            self.backend.metrics.source_bytes += n;
            return n;
        }
    };

    pub fn metadata(self: *Backend, a: A, entry: core.Entry) !core.Metadata {
        const began = x.Timer.now();
        defer {
            const elapsed = x.Timer.elapsed(began);
            self.metrics.metadata_ticks += elapsed;
            self.metrics.metadata_max = @max(self.metrics.metadata_max, elapsed);
        }
        const file = self.files.get(entry.path) orelse return error.NotFound;
        var reader = Reader{ .raw = try self.volume.reader(file), .backend = self };
        var source = try @import("media_source.zig").Source(Reader).init(&reader, file.size, self.cache());
        return media.extract(a, &source, std.fs.path.extension(entry.path));
    }

    pub fn playlist(self: *Backend, a: A, path: []const u8, tracks: []const core.Track) !core.Playlist {
        const file = self.files.get(path) orelse return error.NotFound;
        if (file.size > 1024 * 1024) return error.PlaylistLimit;
        var raw = Reader{ .raw = try self.volume.reader(file), .backend = self };
        const data = try a.alloc(u8, file.size);
        var used: usize = 0;
        while (used < data.len) {
            const n = try raw.read(data[used..]);
            if (n == 0) return error.Truncated;
            used += n;
        }
        var items: std.ArrayList(core.PlaylistItem) = .empty;
        var lines = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, data, "\xef\xbb\xbf")) data[3..] else data, '\n');
        while (lines.next()) |line| {
            const value = std.mem.trim(u8, line, " \r\t");
            if (value.len == 0 or value[0] == '#') continue;
            const resolved = (try core.playlistPath(a, path, value)) orelse continue;
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

    pub fn artwork(self: *Backend, a: A, album: core.Album, tracks: []const core.Track, entries: []const core.Entry, previous: ?core.Artwork, mode: core.Mode) !core.Artwork {
        if (self.concurrent) {
            // Retain a known cover or a deliberate fallback; image preparation
            // and cache writes resume only after playback workers have joined.
            return if (previous) |old| core.clone(a, old) else .{};
        }
        const began = x.Timer.now();
        defer {
            const elapsed = x.Timer.elapsed(began);
            self.metrics.artwork_ticks += elapsed;
            self.metrics.artwork_max = @max(self.metrics.artwork_max, elapsed);
        }
        var selected = core.sidecarArtwork(entries, album.directory);
        if (selected == null) for (album.tracks) |index| {
            const track = tracks[index];
            if (track.meta.embedded_art) {
                selected = .{ .path = track.path, .kind = .audio, .stamp = track.stamp };
                break;
            }
        };

        const chosen = selected orelse return .{};
        if (self.artpack == null) self.artpack = try ArtPack.init(self.volume, self.allocator, self);
        if (previous) |old| if (mode == .quick and old.error_name.len == 0 and std.mem.eql(u8, old.recipe, recipe) and std.mem.eql(u8, old.source, chosen.path) and old.stamp.same(chosen.stamp) and old.key.len == 64) {
            var previous_key: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&previous_key, old.key) catch return error.BadArtworkKey;
            if (self.artpack.?.entries.contains(previous_key)) {
                self.metrics.art_reused += 1;
                return core.clone(a, old);
            }
        };

        const pack = &self.artpack.?;
        const file = self.files.get(chosen.path) orelse return error.NotFound;
        var reader = Reader{ .raw = try self.volume.reader(file), .backend = self };
        var source = try @import("media_source.zig").Source(Reader).init(&reader, file.size, self.cache());

        const Range = struct { offset: u64, length: u32 };
        const range: Range = if (chosen.kind == .artwork) .{ .offset = 0, .length = file.size } else embedded: {
            const found = try media.embeddedPicture(&source) orelse return error.MissingArtwork;
            break :embedded .{ .offset = found.offset, .length = found.length };
        };
        if (range.length > 16 * 1024 * 1024) return error.ArtworkLimit;
        var hash = std.crypto.hash.Blake3.init(.{});
        hash.update(recipe);
        try media.hashRange(&source, range.offset, range.length, &hash);
        var key: [32]u8 = undefined;
        hash.final(&key);
        const slot = if (pack.entries.get(key)) |found| reuse: {
            self.metrics.art_reused += 1;
            break :reuse found;
        } else prepare: {
            // Keep the 25 KiB tile and accumulators in the idle decoder arena;
            // returning/passing tiles by value exhausted the firmware stack.
            comptime {
                if (art.sum_words * 4 + @sizeOf(art.Tile) > memory.decoder_arena.bytes) @compileError("artwork workspace exceeds the decoder arena");
            }
            const workspace = memory.decoder_arena.cachedSlice(u32);
            const tile: *art.Tile = @ptrCast(@alignCast(workspace[art.sum_words..].ptr));
            try art.decode(&source, range.offset, range.length, workspace[0..art.sum_words], tile, self);
            const slot = try pack.append(key, tile);
            self.metrics.art_prepared += 1;
            break :prepare slot;
        };
        return .{
            .recipe = recipe,
            .source = chosen.path,
            .stamp = chosen.stamp,
            .key = try core.text(a, &std.fmt.bytesToHex(&key, .lower)),
            .cache_path = try std.fmt.allocPrint(a, "atlas:{d}", .{slot}),
            .width = art.edge,
            .height = art.edge,
        };
    }
};

const recipe = "gain-rgb565-stream-area112-v1";
const art_slot_bytes = 512 + art.pixel_count * 2;

const ArtPack = struct {
    volume: *Volume,
    file: fat.File,
    entries: std.AutoHashMap([32]u8, u32),
    next: u32 = 0,

    fn init(volume: *Volume, allocator: A, backend: *Backend) !ArtPack {
        const prefix: *[512]u8 = @ptrCast(memory.storage_burst.uncachedSlice(u8).ptr);
        const file = try @import("managed_file.zig").open(volume, ".gain/artwork.bin", .artwork, prefix);
        var result = ArtPack{ .volume = volume, .file = file, .entries = std.AutoHashMap([32]u8, u32).init(allocator) };
        errdefer result.entries.deinit();
        var reader = try volume.reader(file);
        const buffer = memory.storage_burst.uncachedSlice(u8)[0..512];
        const count = (file.size - 4096) / art_slot_bytes;
        for (0..count) |slot| {
            if (backend.cancelled()) return error.Cancelled;
            try reader.seekTo(@intCast(4096 + slot * art_slot_bytes));
            if (try reader.read(buffer) != 512) return error.TruncatedArtwork;
            const valid = std.mem.eql(u8, buffer[0..4], "GART") and std.hash.Crc32.hash(buffer[0..508]) == std.mem.readInt(u32, buffer[508..512], .little);
            if (valid) {
                try result.entries.put(buffer[8..40].*, @intCast(slot));
                result.next = @intCast(slot + 1);
            }
        }
        return result;
    }

    fn append(self: *ArtPack, key: [32]u8, tile: *const art.Tile) !u32 {
        const slot = self.next;
        const at = 4096 + slot * art_slot_bytes;
        if (at > self.file.size or art_slot_bytes > self.file.size - at) return error.ArtworkCacheFull;
        const bytes = memory.storage_burst.uncachedSlice(u8)[0..art_slot_bytes];
        @memset(bytes, 0);
        @memcpy(bytes[0..4], "GART");
        std.mem.writeInt(u32, bytes[4..8], 1, .little);
        @memcpy(bytes[8..40], &key);
        for ([_]u16{ tile.x, tile.y, tile.width, tile.height }, 0..) |v, i| std.mem.writeInt(u16, bytes[40 + i * 2 ..][0..2], v, .little);
        for (tile.pixels, 0..) |pixel, i| std.mem.writeInt(u16, bytes[512 + i * 2 ..][0..2], pixel, .little);
        std.mem.writeInt(u32, bytes[48..52], std.hash.Crc32.hash(bytes[512..]), .little);
        std.mem.writeInt(u32, bytes[508..512], std.hash.Crc32.hash(bytes[0..508]), .little);
        var writer = try self.volume.overwrite(self.file);
        try writer.seekTo(at + 512);
        try writer.write(bytes[512..]);
        try writer.sync();
        try writer.seekTo(at);
        try writer.write(bytes[0..512]);
        try writer.sync();
        try self.entries.put(key, slot);
        self.next += 1;
        return slot;
    }
};

test "idle and playing discovery reserve map buckets before growing the entry vector" {
    const Model = struct {
        fn run(reserved: bool) !usize {
            const bytes = try std.testing.allocator.alloc(u8, memory.scan_maps.bytes);
            defer std.testing.allocator.free(bytes);
            const names = try std.testing.allocator.alloc([24]u8, 5000);
            defer std.testing.allocator.free(names);
            var fixed = std.heap.FixedBufferAllocator.init(bytes);
            const allocator = fixed.allocator();
            var backend = Backend.init(undefined, undefined, allocator);
            defer backend.deinit();
            if (reserved) try backend.reserveEnumeration();
            var entries: std.ArrayList(core.Entry) = .empty;
            defer entries.deinit(allocator);
            for (names, 0..) |*name, i| {
                const path = try std.fmt.bufPrint(name, "music/{d:0>4}.m4a", .{i});
                try entries.append(allocator, .{ .path = path, .kind = .audio });
                try backend.files.put(path, .{ .first_cluster = @intCast(i + 2), .size = 4096 });
            }
            return fixed.end_index;
        }
    };
    try std.testing.expectError(error.OutOfMemory, Model.run(false));
    try std.testing.expect(try Model.run(true) <= memory.scan_maps.bytes);
}
