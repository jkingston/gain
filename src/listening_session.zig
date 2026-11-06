//! Portable listening-session schema and power-cut tolerant journal. All memory
//! is caller-owned. Queue membership and permutation are committed together;
//! small position checkpoints can only refer to that committed generation.
const std = @import("std");
const order = @import("play_queue.zig");
const library = @import("library.zig");
const managed = @import("managed_file.zig");

pub const max_tracks = 8192;
pub const payload_header_bytes = 128;
pub const max_payload_bytes = payload_header_bytes + max_tracks * 10;
pub const scratch_bytes = max_payload_bytes + max_tracks * 2;
pub const sector_bytes = 512;
pub const bank_bytes = 160 * 1024;
pub const allocation_bytes = 512 * 1024;
const position_base = managed.prefix_bytes + bank_bytes * 2;

pub const Navigation = struct {
    screen: u8 = 0,
    scope: u8 = 0,
    album: u64 = 0,
    artist: u64 = 0,
    selected: u64 = 0,
    anchor: u64 = 0,
};

pub const Position = struct {
    cursor: u16 = 0,
    frame: u64 = 0,
    sample_rate: u32 = 0,
    stamp: library.Stamp = .{},

    /// Changed encodings and changed sample rates invalidate a frame position.
    /// Metadata-only changes may also reset safely; no old position is blindly
    /// applied to a replacement file. Duration is authoritative after open.
    pub fn validatedFrame(self: Position, stamp: library.Stamp, rate: u32, total: u64) u64 {
        if (!self.stamp.same(stamp) or self.sample_rate != rate) return 0;
        return @min(self.frame, total);
    }
};

fn newer(a: u32, b: u32) bool {
    const delta = a -% b;
    return delta != 0 and delta < 0x80000000;
}

fn validPosition(position: Position, count: usize) bool {
    return (if (count == 0) position.cursor == 0 and position.frame == 0 else position.cursor < count) and position.sample_rate <= 768000 and (position.frame == 0 or position.sample_rate != 0);
}

fn putPosition(bytes: []u8, value: Position) void {
    std.mem.writeInt(u16, bytes[0..2], value.cursor, .little);
    std.mem.writeInt(u64, bytes[8..16], value.frame, .little);
    std.mem.writeInt(u32, bytes[16..20], value.sample_rate, .little);
    std.mem.writeInt(u64, bytes[24..32], value.stamp.size, .little);
    std.mem.writeInt(i64, bytes[32..40], value.stamp.modified, .little);
    std.mem.writeInt(u64, bytes[40..48], value.stamp.device, .little);
    std.mem.writeInt(u64, bytes[48..56], value.stamp.inode, .little);
}

fn getPosition(bytes: []const u8) Position {
    return .{
        .cursor = std.mem.readInt(u16, bytes[0..2], .little),
        .frame = std.mem.readInt(u64, bytes[8..16], .little),
        .sample_rate = std.mem.readInt(u32, bytes[16..20], .little),
        .stamp = .{
            .size = std.mem.readInt(u64, bytes[24..32], .little),
            .modified = std.mem.readInt(i64, bytes[32..40], .little),
            .device = std.mem.readInt(u64, bytes[40..48], .little),
            .inode = std.mem.readInt(u64, bytes[48..56], .little),
        },
    };
}

fn putNavigation(bytes: []u8, value: Navigation) void {
    bytes[0] = value.screen;
    bytes[1] = value.scope;
    std.mem.writeInt(u64, bytes[8..16], value.album, .little);
    std.mem.writeInt(u64, bytes[16..24], value.artist, .little);
    std.mem.writeInt(u64, bytes[24..32], value.selected, .little);
    std.mem.writeInt(u64, bytes[32..40], value.anchor, .little);
}

fn getNavigation(bytes: []const u8) ?Navigation {
    if (bytes[0] > 15 or bytes[1] > 7) return null;
    return .{ .screen = bytes[0], .scope = bytes[1], .album = std.mem.readInt(u64, bytes[8..16], .little), .artist = std.mem.readInt(u64, bytes[16..24], .little), .selected = std.mem.readInt(u64, bytes[24..32], .little), .anchor = std.mem.readInt(u64, bytes[32..40], .little) };
}

/// Borrows only the caller's snapshot buffer, never catalogue strings or a live
/// queue. Canonical ordinal identifies a duplicate occurrence across reboot.
pub const Data = struct {
    bytes: []const u8,
    count: u16,
    source: u64,
    shuffle: order.Shuffle,
    repeat: order.Repeat,
    pinned_next: u16,
    position: Position,
    navigation: Navigation,

    pub fn len(self: Data) usize {
        return self.count;
    }

    pub fn canonical(self: Data, i: usize) u64 {
        std.debug.assert(i < self.count);
        return std.mem.readInt(u64, self.bytes[payload_header_bytes + i * 8 ..][0..8], .little);
    }

    pub fn ordinal(self: Data, i: usize) u16 {
        std.debug.assert(i < self.count);
        return std.mem.readInt(u16, self.bytes[payload_header_bytes + @as(usize, self.count) * 8 + i * 2 ..][0..2], .little);
    }

    pub fn trackAt(self: Data, i: usize) u64 {
        return self.canonical(self.ordinal(i));
    }

    pub fn restore(self: Data, queue: *order.Queue) !void {
        try queue.restoreFrom(self, self.position.cursor, self.shuffle, self.repeat, self.pinned_next);
    }
};

/// Root caller must not publish a partially built snapshot. Slot-to-ordinal
/// mapping is O(N); duplicate song IDs never participate in the permutation.
pub fn capture(queue: anytype, source: u64, position: Position, navigation: Navigation, scratch: []u8) !Data {
    if (queue.count > max_tracks or scratch.len < scratch_bytes) return error.SessionCapacity;
    if (!validPosition(position, queue.count) or navigation.screen > 15 or navigation.scope > 7 or queue.pinned_next > queue.count -| (@as(usize, position.cursor) + 1)) return error.InvalidSession;
    const size = payload_header_bytes + queue.count * 10;
    const payload = scratch[0..size];
    @memset(payload, 0);
    @memcpy(payload[0..4], "GSQ1");
    std.mem.writeInt(u16, payload[4..6], @intCast(queue.count), .little);
    payload[6] = @intCast(@backingInt(queue.shuffle_kind));
    payload[7] = @intCast(@backingInt(queue.repeat));
    std.mem.writeInt(u64, payload[8..16], source, .little);
    std.mem.writeInt(u16, payload[16..18], @intCast(queue.pinned_next), .little);
    putPosition(payload[24..80], position);
    putNavigation(payload[80..120], navigation);
    const inverse = scratch[max_payload_bytes..][0 .. max_tracks * 2];
    @memset(inverse, 0xff); // A concurrently removed slot cannot read an unset ordinal.
    for (0..queue.count) |i| {
        const slot = queue.canonicalSlotAt(i).?;
        if (slot >= queue.capacity()) return error.InvalidSession;
        std.mem.writeInt(u16, inverse[@as(usize, slot) * 2 ..][0..2], @intCast(i), .little);
        std.mem.writeInt(u64, payload[payload_header_bytes + i * 8 ..][0..8], queue.canonicalAt(i).?, .little);
    }
    for (0..queue.count) |i| {
        const slot = queue.slotAt(i).?;
        if (slot >= queue.capacity()) return error.InvalidSession;
        const ordinal_value = std.mem.readInt(u16, inverse[@as(usize, slot) * 2 ..][0..2], .little);
        std.mem.writeInt(u16, payload[payload_header_bytes + queue.count * 8 + i * 2 ..][0..2], ordinal_value, .little);
    }
    return decode(payload) orelse error.InvalidSession;
}

/// CRC belongs to the journal envelope; schema checks remain necessary even
/// for an intact record produced by an older or faulty firmware.
pub fn decode(bytes: []const u8) ?Data {
    if (bytes.len < payload_header_bytes or !std.mem.eql(u8, bytes[0..4], "GSQ1")) return null;
    const count = std.mem.readInt(u16, bytes[4..6], .little);
    if (count > max_tracks or bytes.len != payload_header_bytes + @as(usize, count) * 10) return null;
    const shuffle = std.enums.fromInt(order.Shuffle, bytes[6]) orelse return null;
    const repeat = std.enums.fromInt(order.Repeat, bytes[7]) orelse return null;
    const position = getPosition(bytes[24..80]);
    const pinned_next = std.mem.readInt(u16, bytes[16..18], .little);
    if (!validPosition(position, count) or pinned_next > count -| (@as(usize, position.cursor) + 1) or bytes[80] > 15 or bytes[81] > 7) return null;
    const result = Data{
        .bytes = bytes,
        .count = count,
        .source = std.mem.readInt(u64, bytes[8..16], .little),
        .shuffle = shuffle,
        .repeat = repeat,
        .pinned_next = pinned_next,
        .position = position,
        .navigation = getNavigation(bytes[80..120]) orelse return null,
    };
    var seen = std.StaticBitSet(max_tracks).empty;
    for (0..count) |i| {
        const ordinal_value = result.ordinal(i);
        if (result.canonical(i) == 0 or ordinal_value >= count or seen.isSet(ordinal_value)) return null;
        if (shuffle == .off and ordinal_value != i) return null;
        seen.set(ordinal_value);
    }
    return result;
}

pub const Record = struct {
    data: Data,
    position: Position,
    navigation: Navigation,

    pub fn restore(self: Record, queue: *order.Queue) !void {
        var data = self.data;
        data.position = self.position;
        try data.restore(queue);
    }
};

pub const Journal = struct {
    bank: u1 = 1,
    generation: u32 = 0,
    committed: bool = false,
    membership_key: ?u64 = null,
    position_bank: u1 = 1,
    position_sequence: u32 = 0,

    fn queueOffset(bank: u1) u32 {
        return managed.prefix_bytes + @as(u32, bank) * bank_bytes;
    }

    fn crcValid(block: *const [sector_bytes]u8, magic: *const [4]u8) bool {
        return std.mem.eql(u8, block[0..4], magic) and std.hash.Crc32.hash(block[0..508]) == std.mem.readInt(u32, block[508..512], .little);
    }

    fn readPayload(reader: anytype, scratch: []u8, length: usize, block: *[sector_bytes]u8) !void {
        var written: usize = 0;
        while (written < length) {
            if (try reader.read(block) != sector_bytes) return error.TruncatedSession;
            const amount = @min(sector_bytes, length - written);
            @memcpy(scratch[written..][0..amount], block[0..amount]);
            written += amount;
        }
    }

    pub fn load(self: *Journal, reader: anytype, source: u64, scratch: []u8, block: *[sector_bytes]u8) !?Record {
        self.* = .{};
        if (scratch.len < scratch_bytes) return error.SessionCapacity;
        var candidates: [2]?struct { generation: u32, length: u32, crc: u32 } = .{ null, null };
        for (0..2) |i| {
            try reader.seekTo(queueOffset(@intCast(i)));
            if (try reader.read(block) != sector_bytes) return error.TruncatedSession;
            if (!crcValid(block, "GSES") or std.mem.readInt(u32, block[4..8], .little) != 1) continue;
            const length = std.mem.readInt(u32, block[12..16], .little);
            if (length < payload_header_bytes or length > max_payload_bytes) continue;
            candidates[i] = .{ .generation = std.mem.readInt(u32, block[8..12], .little), .length = length, .crc = std.mem.readInt(u32, block[16..20], .little) };
        }
        const first: u1 = if (candidates[1] != null and (candidates[0] == null or newer(candidates[1].?.generation, candidates[0].?.generation))) 1 else 0;
        var selected: ?Data = null;
        for ([_]u1{ first, first ^ 1 }) |bank| {
            const candidate = candidates[bank] orelse continue;
            try reader.seekTo(queueOffset(bank) + sector_bytes);
            try readPayload(reader, scratch, candidate.length, block);
            const payload = scratch[0..candidate.length];
            if (std.hash.Crc32.hash(payload) != candidate.crc) continue;
            const data = decode(payload) orelse continue;
            if (data.source != source) continue;
            selected = data;
            self.bank = bank;
            self.generation = candidate.generation;
            self.committed = true;
            self.membership_key = membershipKey(data);
            break;
        }
        const data = selected orelse return null;
        var position = data.position;
        var navigation = data.navigation;
        var found = false;
        for (0..2) |i| {
            try reader.seekTo(position_base + @as(u32, @intCast(i)) * sector_bytes);
            if (try reader.read(block) != sector_bytes) return error.TruncatedSession;
            if (!crcValid(block, "GPOS") or std.mem.readInt(u32, block[4..8], .little) != 1 or std.mem.readInt(u32, block[8..12], .little) != self.generation) continue;
            const sequence = std.mem.readInt(u32, block[12..16], .little);
            const candidate = getPosition(block[24..80]);
            if (!validPosition(candidate, data.count) or data.pinned_next > data.count -| (@as(usize, candidate.cursor) + 1)) continue;
            const candidate_navigation = getNavigation(block[80..120]) orelse continue;
            const id = if (data.count != 0) data.trackAt(candidate.cursor) else 0;
            if (id != std.mem.readInt(u64, block[16..24], .little)) continue;
            if (!found or newer(sequence, self.position_sequence)) {
                position = candidate;
                navigation = candidate_navigation;
                self.position_sequence = sequence;
                self.position_bank = @intCast(i);
                found = true;
            }
        }
        return .{ .data = data, .position = position, .navigation = navigation };
    }

    pub fn saveQueue(self: *Journal, writer: anytype, data: Data, block: *[sector_bytes]u8) !void {
        // Never accept a forged Data that bypassed the schema decoder.
        _ = decode(data.bytes) orelse return error.InvalidSession;
        const bank = self.bank ^ 1;
        const generation = self.generation +% 1;
        try writer.seekTo(queueOffset(bank) + sector_bytes);
        var consumed: usize = 0;
        while (consumed < data.bytes.len) {
            @memset(block, 0);
            const amount = @min(sector_bytes, data.bytes.len - consumed);
            @memcpy(block[0..amount], data.bytes[consumed..][0..amount]);
            try writer.write(block);
            consumed += amount;
        }
        try writer.sync();
        @memset(block, 0);
        @memcpy(block[0..4], "GSES");
        std.mem.writeInt(u32, block[4..8], 1, .little);
        std.mem.writeInt(u32, block[8..12], generation, .little);
        std.mem.writeInt(u32, block[12..16], @intCast(data.bytes.len), .little);
        std.mem.writeInt(u32, block[16..20], std.hash.Crc32.hash(data.bytes), .little);
        std.mem.writeInt(u32, block[508..512], std.hash.Crc32.hash(block[0..508]), .little);
        try writer.seekTo(queueOffset(bank));
        try writer.write(block);
        try writer.sync();
        self.bank = bank;
        self.generation = generation;
        self.committed = true;
        self.membership_key = membershipKey(data);
        self.position_sequence = 0;
        self.position_bank = 1;
    }

    pub fn savePosition(self: *Journal, writer: anytype, data: Data, position: Position, block: *[sector_bytes]u8) !void {
        const validated = decode(data.bytes) orelse return error.InvalidSession;
        if (!self.committed or self.membership_key == null or self.membership_key.? != membershipKey(validated) or !validPosition(position, validated.count) or validated.pinned_next > validated.count -| (@as(usize, position.cursor) + 1)) return error.InvalidSession;
        const bank = self.position_bank ^ 1;
        const sequence = self.position_sequence +% 1;
        @memset(block, 0);
        @memcpy(block[0..4], "GPOS");
        std.mem.writeInt(u32, block[4..8], 1, .little);
        std.mem.writeInt(u32, block[8..12], self.generation, .little);
        std.mem.writeInt(u32, block[12..16], sequence, .little);
        std.mem.writeInt(u64, block[16..24], if (validated.count != 0) validated.trackAt(position.cursor) else 0, .little);
        putPosition(block[24..80], position);
        putNavigation(block[80..120], validated.navigation);
        std.mem.writeInt(u32, block[508..512], std.hash.Crc32.hash(block[0..508]), .little);
        try writer.seekTo(position_base + @as(u32, bank) * sector_bytes);
        try writer.write(block);
        try writer.sync();
        self.position_bank = bank;
        self.position_sequence = sequence;
    }
};

/// Excludes transient cursor, frame and navigation. A checkpoint of another
/// occurrence does not rewrite the full queue bank.
pub fn membershipKey(data: Data) u64 {
    var hash = std.hash.Wyhash.init(0x47534553);
    hash.update(data.bytes[0..24]);
    hash.update(data.bytes[payload_header_bytes..]);
    return hash.final();
}

/// Cheap control-path dirty tracking. Serialization and SD writes happen only
/// when due, from the storage owner. Completion never clears a newer edit.
pub const Checkpoint = struct {
    revision: ?u32 = null,
    cursor: usize = 0,
    playing: bool = false,
    dirty_at: ?u64 = null,
    last_saved: u64 = 0,
    serial: u32 = 0,

    pub fn observe(self: *Checkpoint, now: u64, revision: u32, cursor: usize, playing: bool) void {
        const changed = self.revision == null or self.revision.? != revision;
        const boundary = self.cursor != cursor or self.playing != playing;
        if (changed or boundary) {
            self.serial +%= 1;
            self.dirty_at = if (boundary) now else now +| 1000;
            self.revision = revision;
            self.cursor = cursor;
            self.playing = playing;
        }
    }

    pub fn due(self: Checkpoint, now: u64, force: bool) bool {
        return force or (if (self.dirty_at) |at| now >= at else false) or (self.playing and now -| self.last_saved >= 30000);
    }

    pub fn saved(self: *Checkpoint, now: u64, serial: u32) void {
        if (self.serial == serial) self.dirty_at = null;
        self.last_saved = now;
    }
};

const Memory = struct {
    bytes: []u8,
    at: usize = 0,
    remaining: usize = std.math.maxInt(usize),
    fail_sync: bool = false,
    dma: ?*const [sector_bytes]u8 = null,
    writes: usize = 0,

    fn seekTo(self: *Memory, offset: u32) !void {
        if (offset > self.bytes.len) return error.Bounds;
        self.at = offset;
    }

    fn read(self: *Memory, output: []u8) !usize {
        if (self.dma) |dma| if (output.ptr != @as([*]const u8, @ptrCast(dma)) or output.len != sector_bytes) return error.CachedDmaBuffer;
        if (output.len > self.bytes.len - self.at) return error.Bounds;
        @memcpy(output, self.bytes[self.at..][0..output.len]);
        self.at += output.len;
        return output.len;
    }

    fn write(self: *Memory, bytes: []const u8) !void {
        if (self.dma) |dma| if (bytes.ptr != @as([*]const u8, @ptrCast(dma)) or bytes.len != sector_bytes) return error.CachedDmaBuffer;
        if (bytes.len > self.bytes.len - self.at) return error.Bounds;
        const amount = @min(self.remaining, bytes.len);
        @memcpy(self.bytes[self.at..][0..amount], bytes[0..amount]);
        self.remaining -= amount;
        self.at += amount;
        self.writes += 1;
        if (amount != bytes.len) return error.Interrupted;
    }

    fn sync(self: *Memory) !void {
        if (self.fail_sync) return error.Interrupted;
    }
};

test "full-size duplicate queue round-trips canonical order, realized shuffle and occurrence cursor" {
    const a = std.testing.allocator;
    const scratch = try a.alloc(u8, scratch_bytes);
    defer a.free(scratch);
    const bytes = try a.alloc(u8, max_tracks * 16);
    defer a.free(bytes);
    const restored_bytes = try a.alloc(u8, max_tracks * 16);
    defer a.free(restored_bytes);
    var queue = order.Queue.init(bytes);
    for (0..max_tracks) |i| try queue.append(1 + i % 79);
    try std.testing.expect(queue.selectOccurrence(queue.occurrenceAt(700).?));
    queue.shuffle(0x47a1, true);
    queue.repeat = .all;
    const position = Position{ .cursor = @intCast(queue.cursor), .frame = 1234567, .sample_rate = 48000, .stamp = .{ .size = 42, .modified = 77, .device = 3, .inode = 19 } };
    const data = try capture(queue, 71, position, .{ .screen = 3, .album = 77 }, scratch);
    var restored = order.Queue.init(restored_bytes);
    try data.restore(&restored);
    try std.testing.expectEqual(queue.count, restored.count);
    try std.testing.expectEqual(queue.cursor, restored.cursor);
    try std.testing.expectEqual(queue.shuffle_kind, restored.shuffle_kind);
    try std.testing.expectEqual(queue.repeat, restored.repeat);
    for (0..max_tracks) |i| {
        try std.testing.expectEqual(queue.at(i), restored.at(i));
        try std.testing.expectEqual(queue.canonicalAt(i), restored.canonicalAt(i));
    }
    try std.testing.expect(restored.occurrenceAt(0).? != restored.occurrenceAt(79).?);
    try std.testing.expectEqual(position, data.position);
}

test "schema rejects malformed permutations, enums, cursor and identities before restoring" {
    const scratch = try std.testing.allocator.alloc(u8, scratch_bytes);
    defer std.testing.allocator.free(scratch);
    var bytes: [4 * 16]u8 = undefined;
    var queue = order.Queue.init(&bytes);
    try queue.insert(&.{ 7, 7, 8 }, false);
    const data = try capture(queue, 12, .{}, .{}, scratch);
    const valid = try std.testing.allocator.dupe(u8, data.bytes);
    defer std.testing.allocator.free(valid);
    for ([_]usize{ 0, 4, 6, 7, 16, 24, 80, 81 }) |field| {
        @memcpy(scratch[0..valid.len], valid);
        scratch[field] = 255;
        try std.testing.expect(decode(scratch[0..valid.len]) == null);
    }
    @memcpy(scratch[0..valid.len], valid);
    @memset(scratch[payload_header_bytes..][0..8], 0);
    try std.testing.expect(decode(scratch[0..valid.len]) == null);
    @memcpy(scratch[0..valid.len], valid);
    const permutation = payload_header_bytes + 3 * 8;
    std.mem.writeInt(u16, scratch[permutation + 2 ..][0..2], 0, .little);
    try std.testing.expect(decode(scratch[0..valid.len]) == null);
    @memcpy(scratch[0..valid.len], valid);
    try std.testing.expect(decode(scratch[0 .. valid.len - 1]) == null);
    const position = Position{ .frame = 8000, .sample_rate = 48000, .stamp = .{ .size = 19, .modified = 7 } };
    try std.testing.expectEqual(5000, position.validatedFrame(position.stamp, 48000, 5000));
    try std.testing.expectEqual(0, position.validatedFrame(.{ .size = 19, .modified = 8 }, 48000, 9000));
    try std.testing.expectEqual(0, position.validatedFrame(position.stamp, 44100, 9000));
}

test "torn queue payloads and every partial commit header retain the preceding generation" {
    const a = std.testing.allocator;
    const scratch = try a.alloc(u8, scratch_bytes);
    defer a.free(scratch);
    const reloaded = try a.alloc(u8, scratch_bytes);
    defer a.free(reloaded);
    const card = try a.alloc(u8, allocation_bytes);
    defer a.free(card);
    @memset(card, 0);
    var bytes: [max_tracks * 16]u8 = undefined;
    var queue = order.Queue.init(&bytes);
    try queue.insert(&.{ 1, 2, 3 }, false);
    var block: [512]u8 = undefined;
    var memory = Memory{ .bytes = card };
    var journal = Journal{};
    try journal.saveQueue(&memory, try capture(queue, 77, .{}, .{}, scratch), &block);
    const baseline = try a.dupe(u8, card);
    defer a.free(baseline);
    queue.clear();
    for (1..max_tracks + 1) |id| try queue.append(id);
    const replacement = try capture(queue, 77, .{ .cursor = 2, .frame = 96000, .sample_rate = 48000 }, .{ .screen = 2 }, scratch);
    const payload_sectors = std.mem.alignForward(usize, replacement.bytes.len, sector_bytes);
    var cut: usize = 0;
    while (cut < payload_sectors) : (cut += sector_bytes) {
        @memcpy(card, baseline);
        memory = .{ .bytes = card, .remaining = cut };
        var interrupted = journal;
        try std.testing.expectError(error.Interrupted, interrupted.saveQueue(&memory, replacement, &block));
        var reader = Journal{};
        const record = (try reader.load(&memory, 77, reloaded, &block)).?;
        try std.testing.expectEqual(journal.generation, reader.generation);
        try std.testing.expectEqual(3, record.data.count);
    }
    for (0..sector_bytes) |partial_header| {
        @memcpy(card, baseline);
        memory = .{ .bytes = card, .remaining = payload_sectors + partial_header };
        var interrupted = journal;
        try std.testing.expectError(error.Interrupted, interrupted.saveQueue(&memory, replacement, &block));
        var reader = Journal{};
        const record = (try reader.load(&memory, 77, reloaded, &block)).?;
        try std.testing.expectEqual(journal.generation, reader.generation);
        try std.testing.expectEqual(3, record.data.count);
    }
    @memcpy(card, baseline);
    memory = .{ .bytes = card };
    try journal.saveQueue(&memory, replacement, &block);
    var reader = Journal{};
    try std.testing.expectEqual(max_tracks, (try reader.load(&memory, 77, reloaded, &block)).?.data.count);
    try std.testing.expect((try reader.load(&memory, 78, reloaded, &block)) == null);
}

test "position checkpoints never attach to a different queue generation and tolerate torn sectors" {
    const a = std.testing.allocator;
    const scratch = try a.alloc(u8, scratch_bytes);
    defer a.free(scratch);
    const reloaded = try a.alloc(u8, scratch_bytes);
    defer a.free(reloaded);
    const card = try a.alloc(u8, allocation_bytes);
    defer a.free(card);
    @memset(card, 0);
    var bytes: [8 * 16]u8 = undefined;
    var queue = order.Queue.init(&bytes);
    try queue.insert(&.{ 1, 1, 2 }, false);
    var block: [512]u8 = undefined;
    var memory = Memory{ .bytes = card };
    var journal = Journal{ .generation = 0xfffffffe };
    const data = try capture(queue, 77, .{}, .{}, scratch);
    try journal.saveQueue(&memory, data, &block);
    const first = Position{ .cursor = 1, .frame = 48000, .sample_rate = 48000 };
    try journal.savePosition(&memory, data, first, &block);
    const baseline = try a.dupe(u8, card);
    defer a.free(baseline);
    for (0..sector_bytes) |cut| {
        @memcpy(card, baseline);
        memory = .{ .bytes = card, .remaining = cut };
        var interrupted = journal;
        try std.testing.expectError(error.Interrupted, interrupted.savePosition(&memory, data, .{ .cursor = 2, .frame = 96000, .sample_rate = 48000 }, &block));
        var reader = Journal{};
        try std.testing.expectEqual(first, (try reader.load(&memory, 77, reloaded, &block)).?.position);
    }
    @memcpy(card, baseline);
    memory = .{ .bytes = card };
    try queue.append(9);
    const next = try capture(queue, 77, .{ .cursor = 3 }, .{}, scratch);
    try journal.saveQueue(&memory, next, &block);
    try std.testing.expectEqual(0, journal.generation);
    var reader = Journal{};
    const record = (try reader.load(&memory, 77, reloaded, &block)).?;
    try std.testing.expectEqual(3, record.position.cursor);
    try std.testing.expectEqual(0, record.position.frame);
    memory.fail_sync = true;
    const before = journal;
    try std.testing.expectError(error.Interrupted, journal.savePosition(&memory, next, .{ .cursor = 1 }, &block));
    try std.testing.expectEqualDeep(before, journal);
}

test "checkpoint coalesces edits and never clears one serviced during a cooperative write" {
    var checkpoint = Checkpoint{};
    checkpoint.observe(0, 1, 0, false);
    try std.testing.expect(!checkpoint.due(999, false));
    checkpoint.observe(500, 2, 0, false);
    try std.testing.expect(!checkpoint.due(1000, false));
    try std.testing.expect(checkpoint.due(1500, false));
    const serial = checkpoint.serial;
    checkpoint.observe(1501, 3, 0, false);
    checkpoint.saved(1502, serial);
    try std.testing.expect(checkpoint.dirty_at != null);
    checkpoint.observe(1600, 3, 0, true);
    try std.testing.expect(checkpoint.due(1600, false));
    checkpoint.saved(1600, checkpoint.serial);
    try std.testing.expect(!checkpoint.due(31599, false));
    try std.testing.expect(checkpoint.due(31600, false));
    checkpoint.observe(32000, 3, 0, false);
    try std.testing.expect(checkpoint.due(32000, false));
}

test "valid envelope CRC cannot authorize a malformed session and foreign positions cannot be committed" {
    const a = std.testing.allocator;
    const scratch = try a.alloc(u8, scratch_bytes);
    defer a.free(scratch);
    const reloaded = try a.alloc(u8, scratch_bytes);
    defer a.free(reloaded);
    const card = try a.alloc(u8, allocation_bytes);
    defer a.free(card);
    @memset(card, 0);
    var bytes: [8 * 16]u8 = undefined;
    var queue = order.Queue.init(&bytes);
    try queue.insert(&.{ 1, 1, 2 }, false);
    var block: [512]u8 = undefined;
    var memory = Memory{ .bytes = card };
    var journal = Journal{};
    try journal.saveQueue(&memory, try capture(queue, 7, .{}, .{}, scratch), &block);
    const previous_generation = journal.generation;
    try queue.append(3);
    const replacement = try capture(queue, 7, .{}, .{}, scratch);
    try std.testing.expectError(error.InvalidSession, journal.savePosition(&memory, replacement, .{}, &block));
    try journal.saveQueue(&memory, replacement, &block);
    const offset = Journal.queueOffset(journal.bank);
    const payload = card[offset + sector_bytes ..][0..replacement.bytes.len];
    // Duplicate the first ordinal while preserving both envelope checksums.
    std.mem.writeInt(u16, payload[payload_header_bytes + 4 * 8 + 2 ..][0..2], 0, .little);
    const header: *[512]u8 = @ptrCast(card[offset..][0..sector_bytes]);
    std.mem.writeInt(u32, header[16..20], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, header[508..512], std.hash.Crc32.hash(header[0..508]), .little);
    var reader = Journal{};
    const restored = (try reader.load(&memory, 7, reloaded, &block)).?;
    try std.testing.expectEqual(previous_generation, reader.generation);
    try std.testing.expectEqual(3, restored.data.count);
}

test "multi-sector session I/O uses only its supplied DMA bounce, never cached snapshot memory" {
    const a = std.testing.allocator;
    const scratch = try a.alloc(u8, scratch_bytes);
    defer a.free(scratch);
    const reloaded = try a.alloc(u8, scratch_bytes);
    defer a.free(reloaded);
    const card = try a.alloc(u8, allocation_bytes);
    defer a.free(card);
    @memset(card, 0);
    var bytes: [128 * 16]u8 = undefined;
    var queue = order.Queue.init(&bytes);
    for (1..129) |id| try queue.append(id);
    var block: [512]u8 align(4) = undefined;
    var memory = Memory{ .bytes = card, .dma = &block };
    var journal = Journal{};
    const data = try capture(queue, 41, .{}, .{}, scratch);
    try std.testing.expectError(error.CachedDmaBuffer, memory.write(data.bytes));
    try std.testing.expectError(error.CachedDmaBuffer, memory.read(scratch[0..512]));
    try journal.saveQueue(&memory, data, &block);
    try journal.savePosition(&memory, data, .{ .cursor = 71, .frame = 44100, .sample_rate = 44100 }, &block);
    var reader = Journal{};
    const restored = (try reader.load(&memory, 41, reloaded, &block)).?;
    try std.testing.expectEqual(71, restored.position.cursor);
    try std.testing.expectEqual(44100, restored.position.frame);
    try std.testing.expectEqualSlices(u8, data.bytes, restored.data.bytes);
}
