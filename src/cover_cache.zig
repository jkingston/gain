//! Portable prepared artwork cache and requests. Only its storage owner fills slots.
const std = @import("std");
const core = @import("library.zig");

pub const Cache = struct {
    pub const slots = 12;

    pub const Request = struct { id: u64 = 0, art: core.Artwork = .{} };
    tiles: [slots]@import("cover_flow.zig").Prepared = undefined,
    ids: [slots]u64 = @splat(0),
    identities: [slots]u64 = @splat(0),
    failed_loads: u32 = 0,
    ready: [slots]std.atomic.Value(bool) = @splat(.init(false)),
    requested: [10]Request = @splat(.{}),
    request_revision: std.atomic.Value(u32) = .init(0),
    revision: std.atomic.Value(u32) = .init(0),

    pub fn request(self: *Cache, at: usize, id: u64, value: core.Artwork) void {
        self.requested[at] = .{ .id = id, .art = value };
    }

    pub fn publishRequests(self: *Cache) void {
        _ = self.request_revision.fetchAdd(1, .release);
    }

    pub fn clearRequests(self: *Cache) void {
        self.requested = @splat(.{});
        self.publishRequests();
    }

    pub const Load = struct { request: Request, slot: usize };

    pub fn nextLoad(self: *const Cache, requests: [10]Request) ?Load {
        for (requests) |requested| {
            if (requested.id == 0 or self.get(requested.id, requested.art) != null or !std.mem.startsWith(u8, requested.art.cache_path, "atlas:")) continue;
            for (self.ids, 0..) |id, slot| {
                var visible = false;
                for (requests) |r| if (id != 0 and r.id == id and self.identities[slot] == identity(r.art)) {
                    visible = true;
                    break;
                };
                if (!visible) return .{ .request = requested, .slot = slot };
            }
        }
        return null;
    }

    pub fn begin(self: *Cache, load: Load) void {
        self.ready[load.slot].store(false, .release);
        self.ids[load.slot] = 0;
    }

    pub fn publish(self: *Cache, load: Load) void {
        self.ids[load.slot] = load.request.id;
        self.identities[load.slot] = identity(load.request.art);
        self.ready[load.slot].store(true, .release);
        _ = self.revision.fetchAdd(1, .release);
    }

    pub fn publishMissing(self: *Cache, load: Load) void {
        // A prepared fallback is also a negative cache entry. The same bad
        // identity is not read again until its artwork changes or remount.
        self.tiles[load.slot].width = 0;
        self.tiles[load.slot].height = 0;
        self.failed_loads +|= 1;
        self.publish(load);
    }

    pub fn identity(art: core.Artwork) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(art.key);
        hash.update("\x00");
        hash.update(art.cache_path);
        return hash.final();
    }

    pub fn get(self: *const Cache, id: u64, art: core.Artwork) ?*const @import("cover_flow.zig").Prepared {
        const key = identity(art);
        for (self.ids, 0..) |found, i| if (self.ready[i].load(.acquire) and found != 0 and found == id and self.identities[i] == key) return &self.tiles[i];
        return null;
    }
};

test "an incomplete replacement is invisible until its prepared tile is published" {
    const cache = try std.testing.allocator.create(Cache);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    cache.ids[0] = 1;
    cache.identities[0] = Cache.identity(.{});
    cache.ready[0].store(true, .release);
    try std.testing.expect(cache.get(1, .{}) != null);
    cache.ready[0].store(false, .release);
    cache.ids[0] = 2;
    try std.testing.expect(cache.get(1, .{}) == null);
    try std.testing.expect(cache.get(2, .{}) == null);
    cache.ready[0].store(true, .release);
    try std.testing.expect(cache.get(2, .{}) != null);
    cache.request(0, 2, .{});
    cache.publishRequests();
    cache.clearRequests();
    for (cache.requested) |request_value| try std.testing.expectEqual(0, request_value.id);
    try std.testing.expectEqual(2, cache.request_revision.load(.acquire));
}

/// Validate and decode a disk tile in bounded chunks. The F20 reads this input
/// uncached; hashing and unpacking a whole tile without yielding can stall UI.
pub fn decodeTile(bytes: []const u8, output: *@import("artwork_tile.zig").Tile, observer: anytype) !bool {
    const art = @import("artwork_tile.zig");
    const chunk_pixels = 256; // At most 512 uncached bytes between UI polls.
    if (bytes.len != 512 + art.pixel_count * 2 or !std.mem.eql(u8, bytes[0..4], "GART")) return error.InvalidArtwork;
    if (std.hash.Crc32.hash(bytes[0..508]) != std.mem.readInt(u32, bytes[508..512], .little)) return error.InvalidArtwork;
    var checksum = std.hash.Crc32.init();
    var first: usize = 0;
    while (first < art.pixel_count) {
        if (observer.cancelled()) return false;
        const count: usize = @min(chunk_pixels, art.pixel_count - first);
        const source = bytes[512 + first * 2 ..][0 .. count * 2];
        checksum.update(source);
        for (0..count) |n| output.pixels[first + n] = std.mem.readInt(u16, source[n * 2 ..][0..2], .little);
        first += count;
    }
    if (checksum.final() != std.mem.readInt(u32, bytes[48..52], .little)) return error.InvalidArtwork;
    output.x = std.mem.readInt(u16, bytes[40..42], .little);
    output.y = std.mem.readInt(u16, bytes[42..44], .little);
    output.width = std.mem.readInt(u16, bytes[44..46], .little);
    output.height = std.mem.readInt(u16, bytes[46..48], .little);
    return true;
}

test "cached tile validation yields between bounded chunks and refuses corrupt or cancelled input" {
    const art = @import("artwork_tile.zig");
    var bytes: [512 + art.pixel_count * 2]u8 = @splat(0);
    @memcpy(bytes[0..4], "GART");
    std.mem.writeInt(u16, bytes[44..46], 112, .little);
    std.mem.writeInt(u16, bytes[46..48], 112, .little);
    for (0..art.pixel_count) |i| std.mem.writeInt(u16, bytes[512 + i * 2 ..][0..2], @truncate(i * 197), .little);
    std.mem.writeInt(u32, bytes[48..52], std.hash.Crc32.hash(bytes[512..]), .little);
    std.mem.writeInt(u32, bytes[508..512], std.hash.Crc32.hash(bytes[0..508]), .little);
    const Observer = struct {
        polls: usize = 0,
        cancel_at: usize = 1000,
        pub fn cancelled(self: *@This()) bool {
            self.polls += 1;
            return self.polls == self.cancel_at;
        }
    };
    var observer: Observer = .{};
    var tile: art.Tile = .{};
    try std.testing.expect(try decodeTile(&bytes, &tile, &observer));
    try std.testing.expectEqual((art.pixel_count + 255) / 256, observer.polls);
    for (tile.pixels, 0..) |pixel, i| try std.testing.expectEqual(@as(u16, @truncate(i * 197)), pixel);
    observer = .{ .cancel_at = 2 };
    try std.testing.expect(!try decodeTile(&bytes, &tile, &observer));
    observer = .{};
    bytes[1000] ^= 1;
    try std.testing.expectError(error.InvalidArtwork, decodeTile(&bytes, &tile, &observer));
}

test "bad first artwork is negatively cached without starving a good second cover" {
    const cache = try std.testing.allocator.create(Cache);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    const old = core.Artwork{ .key = "old", .cache_path = "atlas:0" };
    const good = core.Artwork{ .key = "good", .cache_path = "atlas:1" };
    cache.request(0, 1, old);
    cache.request(1, 2, good);
    const first = cache.nextLoad(cache.requested).?;
    try std.testing.expectEqual(1, first.request.id);
    cache.begin(first);
    cache.publishMissing(first);
    const second = cache.nextLoad(cache.requested).?;
    try std.testing.expectEqual(2, second.request.id);
    cache.begin(second);
    cache.tiles[second.slot] = .{ .width = 128, .height = 128 };
    cache.publish(second);
    try std.testing.expect(cache.nextLoad(cache.requested) == null);
    try std.testing.expectEqual(1, cache.failed_loads);
    try std.testing.expectEqual(128, cache.get(2, good).?.width);

    // Album identity remains stable when its artwork changes. The new artwork
    // must not hit the old pixels or its negative cache entry.
    const changed = core.Artwork{ .key = "changed", .cache_path = "atlas:2" };
    cache.request(0, 1, changed);
    try std.testing.expect(cache.get(1, changed) == null);
    const replacement = cache.nextLoad(cache.requested).?;
    try std.testing.expectEqual(1, replacement.request.id);
    cache.begin(replacement);
    cache.tiles[replacement.slot] = .{ .width = 128, .height = 128 };
    cache.publish(replacement);
    try std.testing.expectEqual(128, cache.get(1, changed).?.width);
    try std.testing.expect(cache.get(1, old) == null);
}
