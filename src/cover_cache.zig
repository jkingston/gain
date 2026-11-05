//! Portable prepared artwork cache and requests. Only its storage owner fills slots.
const std = @import("std");
const core = @import("library.zig");

pub const Cache = struct {
    pub const slots = 12;

    pub const Request = struct { id: u64 = 0, art: core.Artwork = .{} };
    tiles: [slots]@import("cover_flow.zig").Prepared = undefined,
    ids: [slots]u64 = @splat(0),
    identities: [slots]u64 = @splat(0),
    last_use: [slots]u32 = @splat(0),
    use_generation: u32 = 0,
    evictions: u32 = 0,
    failed_loads: u32 = 0,
    // One acquire observes readiness for the whole lookup. The storage owner
    // alone updates this mask; tile borrows still require serialized UI access.
    ready_mask: std.atomic.Value(u32) = .init(0),
    requested: [10]Request = @splat(.{}),
    published_requests: [10]RequestKey = @splat(.{}),
    request_revision: std.atomic.Value(u32) = .init(0),
    revision: std.atomic.Value(u32) = .init(0),

    pub fn request(self: *Cache, at: usize, id: u64, value: core.Artwork) void {
        self.requested[at] = .{ .id = id, .art = value };
    }

    const RequestKey = struct { id: u64 = 0, artwork: u64 = 0 };

    pub fn publishRequests(self: *Cache) void {
        var changed = false;
        for (self.requested, &self.published_requests) |request_value, *previous| {
            const next = RequestKey{ .id = request_value.id, .artwork = if (request_value.id != 0) identity(request_value.art) else 0 };
            changed = changed or previous.id != next.id or previous.artwork != next.artwork;
            previous.* = next;
        }
        if (changed) _ = self.request_revision.fetchAdd(1, .release);
    }

    pub fn clearRequests(self: *Cache) void {
        self.requested = @splat(.{});
        self.publishRequests();
    }

    /// The device storage owner snapshots/checks these keys with CPU interrupts
    /// masked. No artwork strings are read while making that bounded check.
    pub fn wants(self: *const Cache, id: u64, artwork: u64) bool {
        if (id == 0) return false;
        for (self.published_requests) |key| if (key.id == id and key.artwork == artwork) return true;
        return false;
    }

    pub const Load = struct { request: Request, slot: usize };

    pub fn nextLoad(self: *Cache, requests: [10]Request) ?Load {
        var keys: [requests.len]RequestKey = undefined;
        for (requests, &keys) |request_value, *key| key.* = .{ .id = request_value.id, .artwork = if (request_value.id != 0) identity(request_value.art) else 0 };
        const ready = self.ready_mask.load(.acquire);
        self.use_generation +%= 1;
        var protected: u32 = 0;
        for (self.ids, 0..) |id, slot| {
            if (id == 0 or ready & slotBit(slot) == 0) continue;
            for (keys) |key| if (key.id == id and key.artwork == self.identities[slot]) {
                protected |= slotBit(slot);
                self.last_use[slot] = self.use_generation;
                break;
            };
        }
        for (requests, keys) |requested, key| {
            if (requested.id == 0 or self.find(key, ready) != null or !std.mem.startsWith(u8, requested.art.cache_path, "atlas:")) continue;
            // An album's new artwork supersedes its old pixels, including a
            // negative entry. Do not retain both identities in separate slots.
            for (self.ids, 0..) |id, slot| if (id == requested.id and protected & slotBit(slot) == 0) return .{ .request = requested, .slot = slot };
            var victim: ?usize = null;
            var oldest_age: u32 = 0;
            for (self.ids, 0..) |id, slot| {
                if (protected & slotBit(slot) != 0) continue;
                // Consume every free slot before evicting history. First-fit
                // replacement otherwise uses only the visible seven slots.
                if (id == 0 or ready & slotBit(slot) == 0) return .{ .request = requested, .slot = slot };
                const age = self.use_generation -% self.last_use[slot];
                if (victim == null or age > oldest_age) {
                    victim = slot;
                    oldest_age = age;
                }
            }
            if (victim) |slot| return .{ .request = requested, .slot = slot };
        }
        return null;
    }

    fn slotBit(slot: usize) u32 {
        std.debug.assert(slot < slots and slots <= @bitSizeOf(u32));
        return @as(u32, 1) << @as(u5, @intCast(slot));
    }

    /// A single storage owner can remember a fully satisfied request revision.
    /// Failed/cancelled loads remain pending until published or superseded.
    pub const WorkQueue = struct {
        exhausted: ?u32 = null,

        pub fn pending(self: WorkQueue, revision: u32) bool {
            return self.exhausted == null or self.exhausted.? != revision;
        }

        pub fn next(self: *WorkQueue, cache: *Cache, requests: [10]Request, revision: u32) ?Load {
            if (!self.pending(revision)) return null;
            if (cache.nextLoad(requests)) |job| return job;
            self.exhausted = revision;
            return null;
        }
    };

    pub fn begin(self: *Cache, load: Load) void {
        const ready = self.ready_mask.load(.monotonic);
        if (ready & slotBit(load.slot) != 0 and self.ids[load.slot] != 0) self.evictions +|= 1;
        self.ready_mask.store(ready & ~slotBit(load.slot), .release);
        self.ids[load.slot] = 0;
    }

    pub fn publish(self: *Cache, load: Load) void {
        self.ids[load.slot] = load.request.id;
        self.identities[load.slot] = identity(load.request.art);
        self.last_use[load.slot] = self.use_generation;
        self.ready_mask.store(self.ready_mask.load(.monotonic) | slotBit(load.slot), .release);
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
        const ready = self.ready_mask.load(.acquire);
        const slot = self.find(.{ .id = id, .artwork = identity(art) }, ready) orelse return null;
        return &self.tiles[slot];
    }

    fn find(self: *const Cache, key: RequestKey, ready: u32) ?usize {
        for (self.ids, 0..) |found, i| if (ready & slotBit(i) != 0 and found != 0 and found == key.id and self.identities[i] == key.artwork) return i;
        return null;
    }
};

test "an incomplete replacement is invisible until its prepared tile is published" {
    const cache = try std.testing.allocator.create(Cache);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    cache.ids[0] = 1;
    cache.identities[0] = Cache.identity(.{});
    cache.ready_mask.store(1, .release);
    try std.testing.expect(cache.get(1, .{}) != null);
    cache.ready_mask.store(0, .release);
    cache.ids[0] = 2;
    try std.testing.expect(cache.get(1, .{}) == null);
    try std.testing.expect(cache.get(2, .{}) == null);
    cache.ready_mask.store(1, .release);
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

test "stationary cover requests coalesce by content while identity and order changes wake work" {
    const cache = try std.testing.allocator.create(Cache);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    cache.publishRequests();
    try std.testing.expectEqual(0, cache.request_revision.load(.acquire));
    const art = core.Artwork{ .key = "synthetic", .cache_path = "atlas:0" };
    cache.request(0, 1, art);
    cache.publishRequests();
    const revision = cache.request_revision.load(.acquire);
    var duplicate = "synthetic".*;
    for (0..100) |_| {
        cache.request(0, 1, .{ .key = &duplicate, .cache_path = "atlas:0" });
        cache.publishRequests();
        try std.testing.expectEqual(revision, cache.request_revision.load(.acquire));
    }
    cache.request(1, 2, art);
    cache.publishRequests();
    try std.testing.expectEqual(revision + 1, cache.request_revision.load(.acquire));
    std.mem.swap(Cache.Request, &cache.requested[0], &cache.requested[1]);
    cache.publishRequests();
    try std.testing.expectEqual(revision + 2, cache.request_revision.load(.acquire));
    cache.request(0, 2, .{ .key = "synthetic", .cache_path = "atlas:1" });
    cache.publishRequests();
    try std.testing.expectEqual(revision + 3, cache.request_revision.load(.acquire));
    cache.clearRequests();
    try std.testing.expectEqual(revision + 4, cache.request_revision.load(.acquire));
    cache.clearRequests();
    try std.testing.expectEqual(revision + 4, cache.request_revision.load(.acquire));
}

test "cover queue drains every request, retries cancellation and sleeps only when satisfied" {
    const cache = try std.testing.allocator.create(Cache);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    var queue = Cache.WorkQueue{};
    const art = core.Artwork{ .key = "synthetic", .cache_path = "atlas:0" };
    cache.request(0, 1, art);
    cache.request(1, 2, art);
    cache.publishRequests();
    const revision = cache.request_revision.load(.acquire);
    const cancelled = queue.next(cache, cache.requested, revision).?;
    cache.begin(cancelled);
    // No publication means the partial tile is still invisible and retried.
    try std.testing.expectEqual(cancelled.request.id, queue.next(cache, cache.requested, revision).?.request.id);
    cache.publishMissing(cancelled);
    const next = queue.next(cache, cache.requested, revision).?;
    try std.testing.expectEqual(2, next.request.id);
    cache.begin(next);
    cache.tiles[next.slot] = .{ .width = 128, .height = 128 };
    cache.publish(next);
    try std.testing.expect(queue.next(cache, cache.requested, revision) == null);
    try std.testing.expect(!queue.pending(revision));
    cache.request(0, 1, .{ .key = "changed", .cache_path = "atlas:0" });
    cache.publishRequests();
    const changed = cache.request_revision.load(.acquire);
    try std.testing.expect(queue.pending(changed));
    try std.testing.expectEqual(1, queue.next(cache, cache.requested, changed).?.request.id);
    // Clearing one ready bit must not hide another prepared slot.
    cache.begin(.{ .slot = cancelled.slot, .request = cancelled.request });
    try std.testing.expect(cache.get(2, art) != null);
}

test "long forward and reverse browsing uses every slot and retains the recent return path" {
    const a = std.testing.allocator;
    const cache = try a.create(Cache);
    defer a.destroy(cache);
    cache.* = .{};
    const albums = 64;
    var keys: [albums][12]u8 = @splat(@splat(0));
    for (&keys, 0..) |*key, i| _ = try std.fmt.bufPrint(key, "cover-{d}", .{i});
    var queue = Cache.WorkQueue{};
    var reads: usize = 0;
    var forward_reads: usize = 0;
    for (0..2 * albums) |step| {
        const center = if (step < albums) step else 2 * albums - step - 1;
        cache.requested = @splat(.{});
        var count: usize = 0;
        for ([_]i32{ 0, -1, 1, -2, 2, -3, 3 }) |offset| {
            const index = @as(i32, @intCast(center)) + offset;
            if (index < 0 or index >= albums) continue;
            const album: usize = @intCast(index);
            cache.request(count, album + 1, .{ .key = &keys[album], .cache_path = "atlas:0" });
            count += 1;
        }
        cache.publishRequests();
        while (queue.next(cache, cache.requested, cache.request_revision.load(.acquire))) |job| {
            cache.begin(job);
            cache.tiles[job.slot].width = 128;
            cache.tiles[job.slot].height = 128;
            cache.publish(job);
            reads += 1;
        }
        for (cache.requested) |request_value| if (request_value.id != 0) try std.testing.expect(cache.get(request_value.id, request_value.art) != null);
        if (step == albums - 1) {
            forward_reads = reads;
            try std.testing.expectEqual(albums, reads);
            try std.testing.expectEqual(Cache.slots, @popCount(cache.ready_mask.load(.acquire)));
            // Recent covers, including those no longer visible, survive the
            // turn around. A first-unprotected policy retains only seven.
            for (albums - Cache.slots..albums) |i| try std.testing.expect(cache.get(i + 1, .{ .key = &keys[i], .cache_path = "atlas:0" }) != null);
        }
        if (step == albums + Cache.slots - 4) try std.testing.expectEqual(forward_reads, reads);
    }
    try std.testing.expectEqual(albums - Cache.slots, reads - forward_reads);
    try std.testing.expectEqual(reads - Cache.slots, cache.evictions);
}

test "replacement protects requested covers and age comparisons survive a counter wrap" {
    const cache = try std.testing.allocator.create(Cache);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    const art = core.Artwork{ .key = "synthetic", .cache_path = "atlas:0" };
    cache.use_generation = std.math.maxInt(u32) - 3;
    for (0..Cache.slots) |slot| {
        cache.begin(.{ .slot = slot, .request = .{ .id = slot + 1, .art = art } });
        cache.publish(.{ .slot = slot, .request = .{ .id = slot + 1, .art = art } });
        cache.last_use[slot] = cache.use_generation -% @as(u32, @intCast(Cache.slots - slot));
    }
    cache.request(0, 1, art);
    cache.request(1, 100, art);
    cache.publishRequests();
    for (0..8) |_| {
        const job = cache.nextLoad(cache.requested).?;
        try std.testing.expectEqual(1, job.slot);
        try std.testing.expectEqual(100, job.request.id);
        try std.testing.expect(cache.wants(1, Cache.identity(art)));
        try std.testing.expect(cache.wants(100, Cache.identity(art)));
    }
    cache.clearRequests();
    try std.testing.expect(!cache.wants(100, Cache.identity(art)));
    cache.request(0, 100, .{ .key = "retagged", .cache_path = "atlas:0" });
    cache.publishRequests();
    try std.testing.expect(!cache.wants(100, Cache.identity(art)));
}

test "obsolete preparation is cancelled without publishing missing art or starving its replacement" {
    const cache = try std.testing.allocator.create(Cache);
    defer std.testing.allocator.destroy(cache);
    const Observer = struct {
        cache: *Cache,
        request: Cache.Request,
        replacement: Cache.Request,
        polls: usize = 0,

        pub fn cancelled(self: *@This()) bool {
            self.polls += 1;
            if (self.polls == 2) {
                self.cache.requested[0] = self.replacement;
                self.cache.publishRequests();
            }
            return !self.cache.wants(self.request.id, Cache.identity(self.request.art));
        }
    };
    const old = core.Artwork{ .key = "old", .cache_path = "atlas:0" };
    const changed = core.Artwork{ .key = "new", .cache_path = "atlas:1" };
    var pixels: [112 * 112]u16 = @splat(0x1234);
    for ([_]u64{ 1, 2 }) |replacement_id| {
        cache.* = .{};
        cache.request(0, 1, old);
        cache.publishRequests();
        var queue = Cache.WorkQueue{};
        const obsolete = queue.next(cache, cache.requested, cache.request_revision.load(.acquire)).?;
        cache.begin(obsolete);
        var observer = Observer{ .cache = cache, .request = obsolete.request, .replacement = .{ .id = replacement_id, .art = changed } };
        try std.testing.expect(!@import("cover_flow.zig").prepareCooperative(.{ .pixels = &pixels }, &cache.tiles[obsolete.slot], &observer));
        try std.testing.expectEqual(2, observer.polls);
        try std.testing.expect(cache.get(1, old) == null);
        try std.testing.expectEqual(0, cache.failed_loads);
        const replacement = queue.next(cache, cache.requested, cache.request_revision.load(.acquire)).?;
        try std.testing.expectEqual(replacement_id, replacement.request.id);
        cache.begin(replacement);
        @import("cover_flow.zig").prepare(.{ .pixels = &pixels }, &cache.tiles[replacement.slot]);
        cache.publish(replacement);
        try std.testing.expect(cache.get(replacement_id, changed) != null);
        try std.testing.expect(queue.next(cache, cache.requested, cache.request_revision.load(.acquire)) == null);
        try std.testing.expectEqual(0, cache.failed_loads);
    }
}
