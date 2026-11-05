//! RIFF INFO, AIFF text and embedded ID3 chunks. Chunk traversal uses offsets,
//! so scanning tags after a large PCM data chunk never reads the audio payload.
const std = @import("std");
const core = @import("library.zig");
const id3 = @import("id3.zig");
const A = std.mem.Allocator;
pub const Picture = struct { offset: u64, length: u32 };

fn Window(comptime Source: type) type {
    return struct {
        source: Source,
        base: u64,
        length: u64,
        position: u32 = 0,
        pub fn read(self: *@This(), at: u64, out: []u8) !void {
            if (at > self.length or out.len > self.length - at) return error.Truncated;
            try self.source.read(self.base + at, out);
        }
    };
}
fn Reader(comptime Source: type) type {
    return struct {
        source: Source,
        position: u32 = 0,

        pub fn seekTo(self: *@This(), at: u32) !void {
            if (at > self.source.length) return error.Truncated;
            self.position = at;
        }

        pub fn read(self: *@This(), out: []u8) !usize {
            const count: usize = @intCast(@min(out.len, self.source.length - self.position));
            try self.source.read(self.position, out[0..count]);
            self.position += @intCast(count);
            return count;
        }
    };
}
const Chunk = struct { id: [4]u8, at: u64, length: u32 };
fn Chunks(comptime Source: type) type {
    return struct {
        source: Source,
        at: u64 = 12,
        end: u64,
        big: bool,
        count: u32 = 0,
        fn init(source: Source) !@This() {
            var bytes: [12]u8 = undefined;
            try source.read(0, &bytes);
            const big = std.mem.eql(u8, bytes[0..4], "FORM");
            if (!big and (!std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE"))) return error.InvalidContainer;
            if (big and !std.mem.eql(u8, bytes[8..12], "AIFF") and !std.mem.eql(u8, bytes[8..12], "AIFC")) return error.InvalidContainer;
            const length = if (big) std.mem.readInt(u32, bytes[4..8], .big) else std.mem.readInt(u32, bytes[4..8], .little);
            if (length < 4 or @as(u64, length) + 8 > source.length) return error.Truncated;
            return .{ .source = source, .end = @as(u64, length) + 8, .big = big };
        }
        fn next(self: *@This()) !?Chunk {
            if (self.at == self.end) return null;
            self.count += 1;
            if (self.count > 4096) return error.MetadataBudget;
            if (self.at > self.end or self.end - self.at < 8) return error.Truncated;
            var header: [8]u8 = undefined;
            try self.source.read(self.at, &header);
            const size = if (self.big) std.mem.readInt(u32, header[4..8], .big) else std.mem.readInt(u32, header[4..8], .little);
            const at = self.at + 8;
            if (size > self.end - at or (size & 1 != 0 and @as(u64, size) + 1 > self.end - at)) return error.Truncated;
            self.at = at + size + (size & 1);
            return .{ .id = header[0..4].*, .at = at, .length = size };
        }
    };
}

fn value(a: A, source: anytype, at: u64, length: u32) ![]const u8 {
    if (length > 4096) return error.LongMetadata;
    var bytes: [4096]u8 = undefined;
    try source.read(at, bytes[0..length]);
    const content = std.mem.trimEnd(u8, bytes[0..length], "\x00 ");
    if (std.unicode.utf8ValidateSlice(content)) return core.text(a, content);
    var converted: [8192]u8 = undefined;
    var used: usize = 0;
    for (content) |byte| {
        const n = try std.unicode.utf8Encode(byte, converted[used..]);
        used += n;
    }
    if (used > 4096) return error.LongMetadata;
    return core.text(a, converted[0..used]);
}

fn technical(result: *core.Metadata, source: anytype, big: bool) !void {
    var reader = Reader(@TypeOf(source)){ .source = source };
    const plan = if (big) (try @import("aiff.zig").parse(&reader)).plan else try @import("pcm.zig").Plan.fromWave(try @import("wav.zig").parse(&reader));
    result.codec = if (big) "aiff" else "wave";
    result.sample_rate = plan.sample_rate;
    result.channels = plan.channels;
    result.bits = plan.sample_format.valid_bits;
    result.duration_ms = plan.frames * 1000 / plan.sample_rate;
}

pub fn extract(a: A, source: anytype) !core.Metadata {
    var chunks = try Chunks(@TypeOf(source)).init(source);
    var result = core.Metadata{};
    try technical(&result, source, chunks.big);
    var rich: ?core.Metadata = null;
    var hash = std.crypto.hash.Blake3.init(.{});
    while (try chunks.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.id, "id3 ") or std.mem.eql(u8, &chunk.id, "ID3 ")) {
            var window = Window(@TypeOf(source)){ .source = source, .base = chunk.at, .length = chunk.length };
            rich = try id3.extract(a, &window);
            continue;
        }
        if (!chunks.big and std.mem.eql(u8, &chunk.id, "LIST") and chunk.length >= 4) {
            var magic: [4]u8 = undefined;
            try source.read(chunk.at, &magic);
            if (!std.mem.eql(u8, &magic, "INFO")) continue;
            var cursor = chunk.at + 4;
            const end = chunk.at + chunk.length;
            while (cursor < end) {
                if (end - cursor < 8) return error.Truncated;
                var header: [8]u8 = undefined;
                try source.read(cursor, &header);
                const length = std.mem.readInt(u32, header[4..8], .little);
                cursor += 8;
                if (length > end - cursor or @as(u64, length) + (length & 1) > end - cursor) return error.Truncated;
                const ids = [_][]const u8{ "INAM", "IART", "IPRD", "IGNR", "ICRD", "ITRK" };
                const keys = [_][]const u8{ "TITLE", "ARTIST", "ALBUM", "GENRE", "DATE", "TRACKNUMBER" };
                for (ids, keys) |id, key| if (std.mem.eql(u8, header[0..4], id)) {
                    const text = try value(a, source, cursor, length);
                    id3.apply(&result, key, text);
                    hash.update(id);
                    hash.update(text);
                    break;
                };
                cursor += length + (length & 1);
            }
        } else if (chunks.big and (std.mem.eql(u8, &chunk.id, "NAME") or std.mem.eql(u8, &chunk.id, "AUTH"))) {
            const text = try value(a, source, chunk.at, chunk.length);
            hash.update(&chunk.id);
            hash.update(text);
            if (std.mem.eql(u8, &chunk.id, "NAME")) result.title = text else result.artist = text;
        }
    }
    if (rich) |tags| {
        const title = result.title;
        const artist = result.artist;
        const album = result.album;
        const codec = result.codec;
        const rate = result.sample_rate;
        const channels = result.channels;
        const bits = result.bits;
        const duration = result.duration_ms;
        result = tags;
        if (result.title.len == 0) result.title = title;
        if (result.artist.len == 0) result.artist = artist;
        if (result.album.len == 0) result.album = album;
        result.codec = codec;
        result.sample_rate = rate;
        result.channels = channels;
        result.bits = bits;
        result.duration_ms = duration;
        hash.update(tags.tag_digest);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    result.tag_digest = try core.text(a, &std.fmt.bytesToHex(&digest, .lower));
    return result;
}

pub fn picture(source: anytype) !?Picture {
    var chunks = try Chunks(@TypeOf(source)).init(source);
    while (try chunks.next()) |chunk| if (std.mem.eql(u8, &chunk.id, "id3 ") or std.mem.eql(u8, &chunk.id, "ID3 ")) {
        var window = Window(@TypeOf(source)){ .source = source, .base = chunk.at, .length = chunk.length };
        if (try id3.picture(&window)) |found| return .{ .offset = chunk.at + found.offset, .length = found.length };
    };
    return null;
}
