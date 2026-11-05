//! Small versioned settings journal. Two independent sectors retain the last
//! committed settings across interrupted writes; no filesystem work runs in UI.
const std = @import("std");
const chrome = @import("music_chrome.zig");
const managed = @import("managed_file.zig");

pub const Theme = enum(u8) { classic, archive, studio, sleeve, sleeve_classic, custom };
pub const Timeout = enum(u8) {
    seconds15,
    seconds30,
    seconds60,
    never,

    pub fn milliseconds(self: Timeout) u64 {
        return switch (self) {
            .seconds15 => 15_000,
            .seconds30 => 30_000,
            .seconds60 => 60_000,
            .never => 0,
        };
    }
};

pub const Options = struct {
    theme: Theme = .classic,
    appearance: chrome.Appearance = .light,
    attenuation: u8 = 64,
    replay_gain: @import("replay_gain.zig").Mode = .off,
    timeout: Timeout = .seconds30,
};

pub const Record = struct { generation: u32, options: Options };
const sector_bytes = 512;
pub const allocation_bytes = managed.prefix_bytes + 4096;

pub fn encode(record: Record, bytes: *[sector_bytes]u8) void {
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "GSET");
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    std.mem.writeInt(u32, bytes[8..12], record.generation, .little);
    bytes[16] = @backingInt(record.options.theme);
    bytes[17] = @intCast(@backingInt(record.options.appearance));
    bytes[18] = record.options.attenuation;
    bytes[19] = @intCast(@backingInt(record.options.replay_gain));
    bytes[20] = @backingInt(record.options.timeout);
    std.mem.writeInt(u32, bytes[508..512], std.hash.Crc32.hash(bytes[0..508]), .little);
}

pub fn decode(bytes: *const [sector_bytes]u8) ?Record {
    if (!std.mem.eql(u8, bytes[0..4], "GSET") or std.mem.readInt(u16, bytes[4..6], .little) != 1 or std.hash.Crc32.hash(bytes[0..508]) != std.mem.readInt(u32, bytes[508..512], .little)) return null;
    if (bytes[18] < 16 or bytes[18] > 128) return null;
    return .{
        .generation = std.mem.readInt(u32, bytes[8..12], .little),
        .options = .{
            .theme = std.enums.fromInt(Theme, bytes[16]) orelse return null,
            .appearance = std.enums.fromInt(chrome.Appearance, bytes[17]) orelse return null,
            .attenuation = bytes[18],
            .replay_gain = std.enums.fromInt(@import("replay_gain.zig").Mode, bytes[19]) orelse return null,
            .timeout = std.enums.fromInt(Timeout, bytes[20]) orelse return null,
        },
    };
}

pub const Journal = struct {
    bank: u1 = 1,
    generation: u32 = 0,
    saved: ?Options = null,

    pub fn load(self: *Journal, reader: anytype, block: *[sector_bytes]u8) !Options {
        self.* = .{};
        for (0..2) |bank| {
            try reader.seekTo(managed.prefix_bytes + @as(u32, @intCast(bank)) * sector_bytes);
            if (try reader.read(block) != sector_bytes) return error.TruncatedSettings;
            if (decode(block)) |record| {
                const newer = record.generation -% self.generation;
                if (self.saved == null or (newer != 0 and newer < 0x80000000)) {
                    self.bank = @intCast(bank);
                    self.generation = record.generation;
                    self.saved = record.options;
                }
            }
        }
        return self.saved orelse .{};
    }

    pub fn save(self: *Journal, writer: anytype, options: Options, block: *[sector_bytes]u8) !void {
        if (self.saved) |saved| if (std.meta.eql(options, saved)) return;
        const bank = self.bank ^ 1;
        const generation = self.generation +% 1;
        encode(.{ .generation = generation, .options = options }, block);
        try writer.seekTo(managed.prefix_bytes + @as(u32, bank) * sector_bytes);
        try writer.write(block);
        try writer.sync();
        self.bank = bank;
        self.generation = generation;
        self.saved = options;
    }
};

const Memory = struct {
    bytes: [allocation_bytes]u8 = @splat(0),
    at: usize = 0,
    limit: usize = sector_bytes,
    writes: usize = 0,
    fail_sync: bool = false,
    fn seekTo(self: *Memory, at: u32) !void {
        self.at = at;
    }
    fn read(self: *Memory, out: []u8) !usize {
        @memcpy(out, self.bytes[self.at..][0..out.len]);
        self.at += out.len;
        return out.len;
    }
    fn write(self: *Memory, bytes: []const u8) !void {
        const n = @min(self.limit, bytes.len);
        @memcpy(self.bytes[self.at..][0..n], bytes[0..n]);
        self.writes += 1;
        if (n != bytes.len) return error.Interrupted;
    }
    fn sync(self: *Memory) !void {
        if (self.fail_sync) return error.Interrupted;
    }
};

test "every interrupted sector write retains the previous valid settings" {
    var baseline = Memory{};
    var block: [512]u8 = undefined;
    var journal = Journal{};
    try journal.save(&baseline, .{}, &block);
    const replacement = Options{ .appearance = .dark, .attenuation = 79, .theme = .sleeve_classic, .timeout = .seconds15 };
    for (0..512) |cut| {
        var card = baseline;
        card.limit = cut;
        var writer = journal;
        try std.testing.expectError(error.Interrupted, writer.save(&card, replacement, &block));
        var reloaded = Journal{};
        try std.testing.expectEqual(Options{}, try reloaded.load(&card, &block));
        try std.testing.expectEqual(journal.generation, writer.generation);
    }
    try journal.save(&baseline, replacement, &block);
    var reloaded = Journal{};
    try std.testing.expectEqual(replacement, try reloaded.load(&baseline, &block));
    const writes = baseline.writes;
    try reloaded.save(&baseline, replacement, &block);
    try std.testing.expectEqual(writes, baseline.writes);
}

test "settings survive generation wrap and reject unknown enums and unsafe volume even with a valid CRC" {
    var card = Memory{};
    var block: [512]u8 = undefined;
    var journal = Journal{ .generation = 0xfffffffe };
    try journal.save(&card, .{}, &block);
    const replacement = Options{ .appearance = .dark };
    try journal.save(&card, replacement, &block);
    var loaded = Journal{};
    try std.testing.expectEqual(replacement, try loaded.load(&card, &block));
    for ([_]usize{ 16, 17, 18, 19, 20 }) |field| {
        encode(.{ .generation = 1, .options = .{} }, &block);
        block[field] = 255;
        std.mem.writeInt(u32, block[508..512], std.hash.Crc32.hash(block[0..508]), .little);
        try std.testing.expect(decode(&block) == null);
    }
}

test "failed flush does not advance the in-memory commit and one corrupt bank falls back cleanly" {
    var card = Memory{};
    var journal = Journal{};
    var block: [512]u8 = undefined;
    try journal.save(&card, .{}, &block);
    const generation = journal.generation;
    card.fail_sync = true;
    try std.testing.expectError(error.Interrupted, journal.save(&card, .{ .appearance = .dark }, &block));
    try std.testing.expectEqual(generation, journal.generation);
    try std.testing.expectEqual(Options{}, journal.saved.?);
    // Model a torn or lost newer sector after the failed flush.
    card.bytes[managed.prefix_bytes + 512 + 16] ^= 1;
    var reloaded = Journal{};
    try std.testing.expectEqual(Options{}, try reloaded.load(&card, &block));
    card.bytes[managed.prefix_bytes + 16] ^= 1;
    try std.testing.expectEqual(Options{}, try reloaded.load(&card, &block));
    try std.testing.expect(reloaded.saved == null);
}
