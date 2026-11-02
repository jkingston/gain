//! Explicit little-endian catalogue encoding. No native layouts or pointers are
//! persisted; callers supply bounded storage and allocation.
const std = @import("std");
const library = @import("library.zig");

pub const schema = 1;

pub const Limits = struct { remaining: usize = 12 * 1024 * 1024, elements: usize = 100_000 };

pub fn encode(writer: anytype, value: anytype) anyerror!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names) |field| try encode(writer, @field(value, field)),
        .pointer => |info| {
            if (info.size != .slice) @compileError("only slices are serializable");
            if (info.child == u8 and !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
            try encode(writer, @as(u32, @intCast(value.len)));
            if (info.child == u8) try writer.write(value) else for (value) |item| try encode(writer, item);
        },
        .@"enum" => try encode(writer, @as(u32, @backingInt(value))),
        .int => {
            var bytes: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, .little);
            try writer.write(&bytes);
        },
        .float => try encode(writer, @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(value))),
        .bool => try encode(writer, @as(u8, @intFromBool(value))),
        .optional => {
            try encode(writer, value != null);
            if (value) |item| try encode(writer, item);
        },
        else => @compileError("unsupported catalogue field"),
    }
}

pub fn decode(comptime T: type, reader: anytype, allocator: std.mem.Allocator, limits: *Limits) anyerror!T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.field_names) |field| @field(result, field) = try decode(@FieldType(T, field), reader, allocator, limits);
            return result;
        },
        .pointer => |info| {
            const count = try decode(u32, reader, allocator, limits);
            if (count > limits.elements or count > limits.remaining / @sizeOf(info.child)) return error.CatalogueLimit;
            limits.remaining -= @as(usize, count) * @sizeOf(info.child);
            const items = try allocator.alloc(info.child, count);
            if (info.child == u8) {
                try exact(reader, items);
                if (!std.unicode.utf8ValidateSlice(items)) return error.InvalidText;
            } else for (items) |*item| item.* = try decode(info.child, reader, allocator, limits);
            return items;
        },
        .@"enum" => return std.enums.fromInt(T, try decode(u32, reader, allocator, limits)) orelse error.InvalidEnum,
        .int => {
            var bytes: [@sizeOf(T)]u8 = undefined;
            try exact(reader, &bytes);
            return std.mem.readInt(T, &bytes, .little);
        },
        .float => {
            const value: T = @bitCast(try decode(@Int(.unsigned, @bitSizeOf(T)), reader, allocator, limits));
            if (!std.math.isFinite(value)) return error.InvalidNumber;
            return value;
        },
        .bool => return switch (try decode(u8, reader, allocator, limits)) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        },
        .optional => |info| return if (try decode(bool, reader, allocator, limits)) try decode(info.child, reader, allocator, limits) else null,
        else => @compileError("unsupported catalogue field"),
    }
}

fn exact(reader: anytype, output: []u8) !void {
    var done: usize = 0;
    while (done < output.len) {
        const n = try reader.read(output[done..]);
        if (n == 0 or n > output.len - done) return error.TruncatedCatalogue;
        done += n;
    }
}

pub fn validate(catalog: *const library.Catalog, allocator: std.mem.Allocator) !void {
    if (catalog.generation == std.math.maxInt(u64)) return error.CatalogueGeneration;
    if (catalog.version != 1) return error.CatalogueVersion;
    var ids = std.AutoHashMap(u64, void).init(allocator);
    defer ids.deinit();
    for (catalog.tracks) |track| {
        if (track.id == 0 or track.album_index >= catalog.albums.len) return error.CatalogueReference;
        const found = try ids.getOrPut(track.id);
        if (found.found_existing) return error.DuplicateTrack;
    }
    for (catalog.albums, 0..) |album, index| for (album.tracks) |track| {
        if (track >= catalog.tracks.len or catalog.tracks[track].album_index != index) return error.CatalogueReference;
    };
    for (catalog.artists) |artist| for (artist.albums) |album| {
        if (album >= catalog.albums.len) return error.CatalogueReference;
    };
    for (catalog.playlists) |playlist| for (playlist.items) |item| {
        if (!item.missing and !ids.contains(item.track_id)) return error.CatalogueReference;
    };
}

const TestBuffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    position: usize = 0,

    pub fn write(self: *@This(), bytes: []const u8) !void {
        try self.bytes.appendSlice(std.testing.allocator, bytes);
    }

    pub fn read(self: *@This(), out: []u8) !usize {
        const n = @min(out.len, self.bytes.items.len - self.position);
        @memcpy(out[0..n], self.bytes.items[self.position..][0..n]);
        self.position += n;
        return n;
    }
};

test "catalogue encoder refuses text that its decoder cannot reload" {
    var buffer: TestBuffer = .{};
    defer buffer.bytes.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidText, encode(&buffer, library.Metadata{ .title = "A Doc\xe2\x00\x19s Example" }));
}

test "catalogue codec roundtrips metadata and bounds malformed allocations" {
    var buffer: TestBuffer = .{};
    defer buffer.bytes.deinit(std.testing.allocator);
    const metadata = library.Metadata{ .title = "架空楽団", .gain = .{ .track_db = -6.4 } };
    try encode(&buffer, metadata);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var limits: Limits = .{};
    const actual = try decode(library.Metadata, &buffer, arena.allocator(), &limits);
    try std.testing.expectEqualStrings(metadata.title, actual.title);
    try std.testing.expectEqual(metadata.gain.track_db, actual.gain.track_db);
    buffer.position = 0;
    limits.remaining = 1;
    try std.testing.expectError(error.CatalogueLimit, decode(library.Metadata, &buffer, arena.allocator(), &limits));
}

test "complete catalogue roundtrip preserves references and rejects every truncation" {
    const member = [_]u32{0};
    const tracks = [_]library.Track{
        .{
            .id = 7,
            .path = "Music/楽団/1.m4a",
            .stamp = .{ .size = 12345, .modified = 13 },
            .meta = .{ .title = "A song", .artist = "楽団", .album = "Album", .gain = .{ .track_db = -3.5 } },
        },
    };

    const albums = [_]library.Album{.{ .id = 11, .key = "release", .title = "Album", .artist = "楽団", .directory = "Music/楽団", .tracks = &member }};
    const value = library.Catalog{ .generation = 2, .source = 1, .tracks = &tracks, .albums = &albums, .artists = &.{
        .{ .name = "楽団", .albums = &member },
    }, .playlists = &.{.{ .path = "List.m3u", .name = "List", .items = &.{.{ .track_id = 7, .path = tracks[0].path }} }} };
    var buffer: TestBuffer = .{};
    defer buffer.bytes.deinit(std.testing.allocator);
    try encode(&buffer, value);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var limits: Limits = .{};
    const decoded = try decode(library.Catalog, &buffer, arena.allocator(), &limits);
    try validate(&decoded, std.testing.allocator);
    try std.testing.expectEqualStrings(tracks[0].path, decoded.tracks[0].path);
    try std.testing.expectEqual(value.tracks[0].meta.gain.track_db, decoded.tracks[0].meta.gain.track_db);
    try std.testing.expectEqual(7, decoded.playlists[0].items[0].track_id);
    const all = buffer.bytes.items;
    for (0..all.len) |length| {
        var truncated: TestBuffer = .{};
        truncated.bytes.items = all[0..length];
        var attempt = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer attempt.deinit();
        limits = .{ .remaining = 64 * 1024 };
        if (decode(library.Catalog, &truncated, attempt.allocator(), &limits)) |_| return error.AcceptedTruncation else |_| {}
    }
    var random = std.Random.DefaultPrng.init(0x47434154);
    const mutated = try std.testing.allocator.dupe(u8, all);
    defer std.testing.allocator.free(mutated);
    for (0..2000) |_| {
        @memcpy(mutated, all);
        const offset = random.random().uintLessThan(usize, mutated.len);
        mutated[offset] ^= @as(u8, 1) << random.random().int(u3);
        var input: TestBuffer = .{};
        input.bytes.items = mutated;
        var attempt = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer attempt.deinit();
        limits = .{ .remaining = 64 * 1024 };
        if (decode(library.Catalog, &input, attempt.allocator(), &limits)) |candidate| validate(&candidate, attempt.allocator()) catch {} else |_| {}
    }
}
