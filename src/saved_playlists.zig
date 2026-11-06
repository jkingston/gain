//! Eight internally named saved queues. Each slot has independent payload banks
//! inside one host-provisioned file; firmware never allocates or renames files.
const std = @import("std");
const managed = @import("managed_file.zig");

pub const slots = 8;
pub const max_tracks = 8192;
const header_bytes = 64;
pub const max_payload_bytes = header_bytes + max_tracks * 8;
pub const bank_bytes = 80 * 1024;
pub const allocation_bytes = managed.prefix_bytes + slots * bank_bytes * 2;
pub const Journal = @import("owned_journal.zig").Journal("GPLS".*, bank_bytes);

pub const Data = struct {
    bytes: []const u8,
    source: u64,
    count: u16,

    pub fn len(self: Data) usize {
        return self.count;
    }

    pub fn id(self: Data, i: usize) u64 {
        std.debug.assert(i < self.count);
        return std.mem.readInt(u64, self.bytes[header_bytes + i * 8 ..][0..8], .little);
    }

    pub fn canonical(self: Data, i: usize) u64 {
        return self.id(i);
    }

    pub fn ordinal(_: Data, i: usize) u16 {
        return @intCast(i);
    }

    pub fn restore(self: Data, queue: *@import("play_queue.zig").Queue) !void {
        try queue.restoreFrom(self, 0, .off, .off, 0);
    }
};

pub fn capture(queue: anytype, source: u64, scratch: []u8) !Data {
    if (queue.count > max_tracks or scratch.len < header_bytes + queue.count * 8) return error.PlaylistCapacity;
    const payload = scratch[0 .. header_bytes + queue.count * 8];
    @memset(payload[0..header_bytes], 0);
    @memcpy(payload[0..4], "GPS1");
    std.mem.writeInt(u16, payload[4..6], @intCast(queue.count), .little);
    std.mem.writeInt(u64, payload[8..16], source, .little);
    for (0..queue.count) |i| std.mem.writeInt(u64, payload[header_bytes + i * 8 ..][0..8], queue.at(i).?, .little);
    return decode(payload, source) orelse error.InvalidPlaylist;
}

pub fn decode(bytes: []const u8, source: u64) ?Data {
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..4], "GPS1") or std.mem.readInt(u64, bytes[8..16], .little) != source) return null;
    const count = std.mem.readInt(u16, bytes[4..6], .little);
    if (count > max_tracks or bytes.len != header_bytes + @as(usize, count) * 8) return null;
    const data = Data{ .bytes = bytes, .source = source, .count = count };
    for (0..count) |i| if (data.id(i) == 0) return null;
    return data;
}

pub const Validator = struct {
    pub fn valid(_: @This(), bytes: []const u8, source: u64) bool {
        return decode(bytes, source) != null;
    }
};

pub const Summary = struct { present: bool = false, count: u16 = 0 };
pub const Store = struct {
    journals: [slots]Journal = block: {
        var result: [slots]Journal = undefined;
        for (&result, 0..) |*journal, i| journal.* = .{ .origin = managed.prefix_bytes + i * bank_bytes * 2 };
        break :block result;
    },
    summary: [slots]Summary = @splat(.{}),

    pub fn load(self: *Store, reader: anytype, slot: usize, source: u64, scratch: []u8, block: *[512]u8) !?Data {
        if (slot >= slots) return error.InvalidPlaylistSlot;
        const payload = (try self.journals[slot].load(reader, source, scratch, block, Validator{})) orelse {
            self.summary[slot] = .{};
            return null;
        };
        const data = decode(payload, source) orelse return error.InvalidPlaylist;
        self.summary[slot] = .{ .present = true, .count = data.count };
        return data;
    }

    pub fn save(self: *Store, writer: anytype, slot: usize, data: Data, block: *[512]u8) !void {
        if (slot >= slots or decode(data.bytes, data.source) == null) return error.InvalidPlaylistSlot;
        try self.journals[slot].save(writer, data.source, data.bytes, block);
        self.summary[slot] = .{ .present = true, .count = data.count };
    }
};

/// Write paths relative to a playlist placed at the card root. Missing tracks
/// are omitted and counted, never replaced by a similarly named song. Validate
/// the whole export before writing so malformed paths cannot partially export.
pub fn exportM3u(writer: anytype, data: Data, resolver: anytype) !usize {
    var missing: usize = 0;
    for (0..data.count) |i| {
        const path = resolver.path(data.id(i)) orelse {
            missing += 1;
            continue;
        };
        if (path.len == 0 or path.len > 4096 or path[0] == '/' or (path.len >= 2 and path[1] == ':') or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfAny(u8, path, "\r\n\x00\\") != null) return error.InvalidPlaylistPath;
        var components = std.mem.splitScalar(u8, path, '/');
        while (components.next()) |component| if (std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".") or component.len == 0) return error.InvalidPlaylistPath;
    }
    try writer.write("#EXTM3U\n");
    for (0..data.count) |i| if (resolver.path(data.id(i))) |path| {
        try writer.write("./");
        try writer.write(path);
        try writer.write("\n");
    };
    return missing;
}

const Memory = struct {
    bytes: []u8,
    at: usize = 0,
    pub fn seekTo(self: *Memory, at: u32) !void {
        self.at = at;
    }

    pub fn read(self: *Memory, output: []u8) !usize {
        @memcpy(output, self.bytes[self.at..][0..output.len]);
        self.at += output.len;
        return output.len;
    }

    pub fn write(self: *Memory, bytes: []const u8) !void {
        @memcpy(self.bytes[self.at..][0..bytes.len], bytes);
        self.at += bytes.len;
    }

    pub fn sync(_: *Memory) !void {}
};

test "saved queues retain realized duplicate order in independently committed slots" {
    const a = std.testing.allocator;
    const card = try a.alloc(u8, allocation_bytes);
    defer a.free(card);
    @memset(card, 0);
    const scratch = try a.alloc(u8, max_payload_bytes);
    defer a.free(scratch);
    const loaded = try a.alloc(u8, max_payload_bytes);
    defer a.free(loaded);
    var bytes: [8 * 16]u8 = undefined;
    var queue = @import("play_queue.zig").Queue.init(&bytes);
    try queue.insert(&.{ 11, 11, 22, 33 }, false);
    queue.shuffle(71, false);
    var memory = Memory{ .bytes = card };
    var block: [512]u8 = undefined;
    var store = Store{};
    const first = try capture(queue, 41, scratch);
    try store.save(&memory, 0, first, &block);
    queue.clear();
    try queue.insert(&.{ 33, 33 }, false);
    try store.save(&memory, 7, try capture(queue, 41, scratch), &block);
    var reader = Store{};
    const last = (try reader.load(&memory, 7, 41, loaded, &block)).?;
    try std.testing.expectEqual(2, last.count);
    try std.testing.expectEqual(33, last.id(0));
    const original = (try reader.load(&memory, 0, 41, loaded, &block)).?;
    try std.testing.expectEqual(4, original.count);
    try original.restore(&queue);
    try std.testing.expectEqual(4, queue.count);
    try std.testing.expect(queue.occurrenceAt(0).? != queue.occurrenceAt(1).?);
    try std.testing.expect((try reader.load(&memory, 1, 41, loaded, &block)) == null);
    try std.testing.expect((try reader.load(&memory, 7, 42, loaded, &block)) == null);
}

test "M3U8 export retains Unicode duplicates, counts missing IDs and rejects injected paths before output" {
    var bytes: [64]u8 = undefined;
    var queue = @import("play_queue.zig").Queue.init(&bytes);
    try queue.insert(&.{ 11, 11, 22 }, false);
    var scratch: [128]u8 = undefined;
    const data = try capture(queue, 7, &scratch);
    const Resolver = struct {
        invalid: bool = false,
        fn path(self: @This(), id: u64) ?[]const u8 {
            return if (id != 11) null else if (self.invalid) "Music/bad\nname.flac" else "Music/世界/song.flac";
        }
    };
    const Writer = struct {
        bytes: [512]u8 = undefined,
        used: usize = 0,
        fn write(self: *@This(), value: []const u8) !void {
            @memcpy(self.bytes[self.used..][0..value.len], value);
            self.used += value.len;
        }
    };
    var writer = Writer{};
    try std.testing.expectEqual(1, try exportM3u(&writer, data, Resolver{}));
    try std.testing.expectEqualStrings("#EXTM3U\n./Music/世界/song.flac\n./Music/世界/song.flac\n", writer.bytes[0..writer.used]);
    writer.used = 0;
    try std.testing.expectError(error.InvalidPlaylistPath, exportM3u(&writer, data, Resolver{ .invalid = true }));
    try std.testing.expectEqual(0, writer.used);
}
