//! Ogg framing and bounded packet assembly, independent of the underlying storage.
const std = @import("std");

const crc_table = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*v, i| {
        var r: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| r = (r << 1) ^ (if (r & 0x80000000 != 0) @as(u32, 0x04c11db7) else 0);
        v.* = r;
    }
    break :blk table;
};

pub fn crc(r0: u32, bytes: []const u8) u32 {
    var r = r0;
    for (bytes) |b| r = (r << 8) ^ crc_table[@as(u8, @truncate(r >> 24)) ^ b];
    return r;
}

pub const Packet = struct { bytes: []const u8, serial: u32, bos: bool, eos: bool, granule: ?u64, number: u64, page_offset: u64 };

pub fn Reader(comptime Source: type) type {
    return struct {
        const Self = @This();
        source: *Source,
        offset: u64 = 0,
        body: []u8,
        laces: [255]u8 = undefined,
        segments: usize = 0,
        segment: usize = 0,
        body_at: usize = 0,
        serial: u32 = 0,
        sequence: u32 = 0,
        flags: u8 = 0,
        granule: ?u64 = null,
        last_complete: usize = 0,
        page_offset: u64 = 0,
        started: bool = false,
        ended: bool = false,
        number: u64 = 0,
        pages: u32 = 0,

        fn load(self: *Self, continuation: bool) !bool {
            if (self.offset == self.source.length) {
                if (!self.ended) return error.MissingEos;
                return false;
            }
            const page_at = self.offset;
            var head: [27]u8 = undefined;
            try self.source.read(page_at, &head);
            if (!std.mem.eql(u8, head[0..4], "OggS") or head[4] != 0 or head[5] & ~@as(u8, 7) != 0) return error.BadOggHeader;
            const serial = std.mem.readInt(u32, head[14..18], .little);
            const seq = std.mem.readInt(u32, head[18..22], .little);
            const flags = head[5];
            if (!self.started or self.ended) {
                if (continuation or flags & 2 == 0 or seq != 0 or flags & 1 != 0) return error.BadBos;
                self.serial = serial;
                self.number = 0;
                self.started = true;
                self.ended = false;
            } else if (serial != self.serial or seq != self.sequence +% 1 or flags & 2 != 0) return error.BadSequence;
            if ((flags & 1 != 0) != continuation) return error.BadContinuation;
            const segments = head[26];
            if (segments == 0) return error.EmptyPage;
            try self.source.read(page_at + 27, self.laces[0..segments]);
            var length: usize = 0;
            var last: ?usize = null;
            for (self.laces[0..segments], 0..) |n, i| {
                length += n;
                if (n < 255) last = i;
            }
            if (length > self.body.len) return error.PageTooLarge;
            try self.source.read(page_at + 27 + segments, self.body[0..length]);
            const expected = std.mem.readInt(u32, head[22..26], .little);
            @memset(head[22..26], 0);
            var actual = crc(0, &head);
            actual = crc(actual, self.laces[0..segments]);
            actual = crc(actual, self.body[0..length]);
            if (actual != expected) return error.BadCrc;
            const g = std.mem.readInt(i64, head[6..14], .little);
            if (g < -1) return error.BadGranule;
            self.granule = if (g < 0) null else @intCast(g);
            self.sequence = seq;
            self.flags = flags;
            self.page_offset = page_at;
            self.offset = page_at + 27 + segments + length;
            self.segment = 0;
            self.segments = segments;
            self.body_at = 0;
            self.last_complete = last orelse segments;
            self.pages += 1;
            if (flags & 4 != 0 and (last == null or last.? != segments - 1)) return error.BadEos;
            return true;
        }

        pub fn next(self: *Self, output: []u8) !?Packet {
            var count: usize = 0;
            var continuation = false;
            while (true) {
                if (self.segment == self.segments) {
                    if (!try self.load(continuation)) return null;
                }
                const index = self.segment;
                const n = self.laces[index];
                if (n > output.len - count) return error.PacketTooLarge;
                @memcpy(output[count..][0..n], self.body[self.body_at..][0..n]);
                self.body_at += n;
                count += n;
                self.segment += 1;
                if (n == 255) {
                    continuation = true;
                    continue;
                }
                const eos = self.flags & 4 != 0 and index == self.last_complete;
                const packet = Packet{ .bytes = output[0..count], .serial = self.serial, .bos = self.number == 0, .eos = eos, .granule = if (index == self.last_complete) self.granule else null, .number = self.number, .page_offset = self.page_offset };
                self.number += 1;
                if (eos) self.ended = true;
                return packet;
            }
        }
    };
}

/// Returns an exact terminal granule only when the final physical page belongs
/// to this logical stream, ends at EOF and passes its full CRC. Matching serials
/// are unique in a valid Ogg physical stream. A chained/multiplexed final stream
/// with another serial is deliberately left unknown, never treated as a shorter
/// single stream. Small local scratch leaves a demuxer's current page intact.
pub fn finalGranule(source: anytype, serial: u32) !?u64 {
    const begin = source.length - @min(source.length, 65536);
    var block: [1027]u8 = undefined;
    var end = source.length;
    var candidates: u32 = 0;
    while (end > begin) {
        const at = end - @min(end - begin, 1024);
        const span: usize = @intCast(end - at);
        const count: usize = @intCast(@min(block.len, source.length - at));
        try source.read(at, block[0..count]);
        end = at;
        var i = span;
        while (i > 0) {
            i -= 1;
            if (i + 4 > count or !std.mem.eql(u8, block[i..][0..4], "OggS")) continue;
            candidates += 1;
            if (candidates > 256) return null;
            if (at + i + 27 > source.length) continue;
            var header: [27]u8 = undefined;
            try source.read(at + i, &header);
            if (header[4] != 0 or header[5] & 4 == 0 or header[5] & 0xf8 != 0 or header[26] == 0 or std.mem.readInt(u32, header[14..18], .little) != serial) continue;
            if (at + i + 27 + header[26] > source.length) continue;
            var laces: [255]u8 = undefined;
            try source.read(at + i + 27, laces[0..header[26]]);
            if (laces[header[26] - 1] == 255) continue;
            var size: u32 = 0;
            for (laces[0..header[26]]) |n| size += n;
            if (at + i + 27 + header[26] + size != source.length) continue;
            var clean = header;
            const expected = std.mem.readInt(u32, clean[22..26], .little);
            @memset(clean[22..26], 0);
            var sum = crc(crc(0, &clean), laces[0..header[26]]);
            var bytes: [1024]u8 = undefined;
            var done: u32 = 0;
            while (done < size) {
                const n = @min(bytes.len, size - done);
                try source.read(at + i + 27 + header[26] + done, bytes[0..n]);
                sum = crc(sum, bytes[0..n]);
                done += n;
            }
            const granule = std.mem.readInt(i64, header[6..14], .little);
            if (sum == expected and granule >= 0) return @intCast(granule);
        }
    }
    return null;
}

pub fn title(bytes: []const u8, offset: usize, out: []u8) !usize {
    if (bytes.len < offset + 4) return error.BadComment;
    var at = offset;
    const vendor = std.mem.readInt(u32, bytes[at..][0..4], .little);
    at += 4;
    if (vendor > bytes.len - at) return error.BadComment;
    at += vendor;
    if (bytes.len - at < 4) return error.BadComment;
    const count = std.mem.readInt(u32, bytes[at..][0..4], .little);
    at += 4;
    if (count > 4096) return error.BadComment;
    var result: usize = 0;
    for (0..count) |_| {
        if (bytes.len - at < 4) return error.BadComment;
        const n = std.mem.readInt(u32, bytes[at..][0..4], .little);
        at += 4;
        if (n > bytes.len - at) return error.BadComment;
        const value = bytes[at..][0..n];
        if (value.len >= 6 and std.ascii.eqlIgnoreCase(value[0..6], "TITLE=")) {
            result = @min(out.len, value.len - 6);
            @memcpy(out[0..result], value[6..][0..result]);
        }
        at += n;
    }
    return result;
}
