//! Bounded ID3v2.2/2.3/2.4 and ID3v1 display tags. Audio bytes are never copied
//! into the catalogue. Text is converted to UTF-8 and unknown frames are skipped.
const std = @import("std");
const core = @import("library.zig");
const A = std.mem.Allocator;
const maximum_tag_bytes = 16 * 1024 * 1024;
const maximum_text_bytes = 4096;
pub const Picture = struct { offset: u64, length: u32 };

fn synchsafe(bytes: []const u8) !u32 {
    if (bytes.len != 4) return error.InvalidId3;
    var result: u32 = 0;
    for (bytes) |byte| {
        if (byte & 0x80 != 0) return error.InvalidId3;
        result = (result << 7) | byte;
    }
    return result;
}

fn Cursor(comptime Source: type) type {
    return struct {
        source: Source,
        at: u64,
        end: u64,
        unsync: bool = false,
        previous_ff: bool = false,
        fn read(self: *@This(), out: []u8) !void {
            if (!self.unsync) {
                if (self.at > self.end or out.len > self.end - self.at) return error.Truncated;
                try self.source.read(self.at, out);
                self.at += out.len;
                return;
            }
            for (out) |*byte| {
                while (true) {
                    if (self.at >= self.end) return error.Truncated;
                    var next: [1]u8 = undefined;
                    try self.source.read(self.at, &next);
                    self.at += 1;
                    if (self.previous_ff and next[0] == 0) {
                        self.previous_ff = false;
                        continue;
                    }
                    self.previous_ff = next[0] == 0xff;
                    byte.* = next[0];
                    break;
                }
            }
        }
        fn skip(self: *@This(), count: u32) !void {
            if (!self.unsync) {
                if (count > self.end - self.at) return error.Truncated;
                self.at += count;
                return;
            }
            var buffer: [512]u8 = undefined;
            var left = count;
            while (left != 0) {
                const n = @min(left, buffer.len);
                try self.read(buffer[0..n]);
                left -= n;
            }
        }
    };
}

fn text(a: A, encoding: u8, data: []const u8) ![]const u8 {
    if (data.len > maximum_text_bytes * 2) return error.LongMetadata;
    var buffer: [maximum_text_bytes + 1]u8 = undefined;
    var used: usize = 0;
    if (encoding == 3) {
        if (!std.unicode.utf8ValidateSlice(data) or data.len > maximum_text_bytes) return error.InvalidText;
        return core.text(a, std.mem.trimEnd(u8, data, "\x00"));
    }
    if (encoding == 0) {
        for (data) |byte| {
            var out: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(byte, &out);
            if (used + n > maximum_text_bytes) return error.LongMetadata;
            @memcpy(buffer[used..][0..n], out[0..n]);
            used += n;
        }
    } else if (encoding == 1 or encoding == 2) {
        if (data.len % 2 != 0) return error.InvalidText;
        var at: usize = 0;
        var endian: std.builtin.Endian = .big;
        if (encoding == 1) {
            if (data.len < 2) return error.InvalidText;
            if (std.mem.eql(u8, data[0..2], &.{ 0xff, 0xfe })) endian = .little else if (!std.mem.eql(u8, data[0..2], &.{ 0xfe, 0xff })) return error.InvalidText;
            at = 2;
        }
        while (at < data.len) : (at += 2) {
            const unit = if (endian == .little) std.mem.readInt(u16, data[at..][0..2], .little) else std.mem.readInt(u16, data[at..][0..2], .big);
            var scalar: u21 = unit;
            if (unit >= 0xd800 and unit <= 0xdbff) {
                at += 2;
                if (at + 2 > data.len) return error.InvalidText;
                const next = if (endian == .little) std.mem.readInt(u16, data[at..][0..2], .little) else std.mem.readInt(u16, data[at..][0..2], .big);
                if (next < 0xdc00 or next > 0xdfff) return error.InvalidText;
                scalar = 0x10000 + (@as(u21, unit - 0xd800) << 10) + (next - 0xdc00);
            } else if (unit >= 0xdc00 and unit <= 0xdfff) return error.InvalidText;
            var out: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(scalar, &out);
            if (used + n > maximum_text_bytes) return error.LongMetadata;
            @memcpy(buffer[used..][0..n], out[0..n]);
            used += n;
        }
    } else return error.InvalidText;
    return core.text(a, std.mem.trimEnd(u8, buffer[0..used], "\x00"));
}

fn numeric(value: []const u8) u32 {
    var parts = std.mem.tokenizeAny(u8, value, "/ ");
    return std.fmt.parseInt(u32, parts.next() orelse "", 10) catch 0;
}
fn decimal(value: []const u8) ?f64 {
    var parts = std.mem.tokenizeAny(u8, value, " dB");
    const number = std.fmt.parseFloat(f64, parts.next() orelse "") catch return null;
    return if (std.math.isFinite(number)) number else null;
}

fn withoutBom(value: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, value, "\xef\xbb\xbf")) value[3..] else value;
}

pub fn apply(result: *core.Metadata, key: []const u8, value: []const u8) void {
    if (std.ascii.eqlIgnoreCase(key, "TITLE")) result.title = value else if (std.ascii.eqlIgnoreCase(key, "ARTIST")) result.artist = value else if (std.ascii.eqlIgnoreCase(key, "ALBUM")) result.album = value else if (std.ascii.eqlIgnoreCase(key, "ALBUMARTIST") or std.ascii.eqlIgnoreCase(key, "ALBUM ARTIST")) result.album_artist = value else if (std.ascii.eqlIgnoreCase(key, "DATE")) result.date = value else if (std.ascii.eqlIgnoreCase(key, "GENRE")) result.genre = value else if (std.ascii.eqlIgnoreCase(key, "TRACKNUMBER")) result.track = numeric(value) else if (std.ascii.eqlIgnoreCase(key, "DISCNUMBER")) result.disc = numeric(value) else if (std.ascii.eqlIgnoreCase(key, "MUSICBRAINZ_ALBUMID")) result.release_id = value else if (std.ascii.eqlIgnoreCase(key, "MUSICBRAINZ_TRACKID")) result.release_track_id = value else if (std.ascii.eqlIgnoreCase(key, "ARTISTSORT")) result.sort_artist = value else if (std.ascii.eqlIgnoreCase(key, "ALBUMARTISTSORT")) result.sort_album_artist = value else if (std.ascii.eqlIgnoreCase(key, "COMPILATION")) result.compilation = numeric(value) != 0 else if (std.ascii.eqlIgnoreCase(key, "REPLAYGAIN_TRACK_GAIN")) result.gain.track_db = decimal(value) else if (std.ascii.eqlIgnoreCase(key, "REPLAYGAIN_ALBUM_GAIN")) result.gain.album_db = decimal(value) else if (std.ascii.eqlIgnoreCase(key, "REPLAYGAIN_TRACK_PEAK")) result.gain.track_peak = decimal(value) else if (std.ascii.eqlIgnoreCase(key, "REPLAYGAIN_ALBUM_PEAK")) result.gain.album_peak = decimal(value);
}

const Frame = struct { id: [4]u8, length: u32, prefix: u32, unsync: bool, skipped: bool };
fn frame(cursor: anytype, version: u8, tag_unsync: bool) !?Frame {
    const n: usize = if (version == 2) 6 else 10;
    if (cursor.at == cursor.end) return null;
    var bytes: [10]u8 = @splat(0);
    try cursor.read(bytes[0..1]);
    if (bytes[0] == 0) return null;
    try cursor.read(bytes[1..n]);
    const id_len: usize = if (version == 2) 3 else 4;
    for (bytes[0..id_len]) |byte| if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte)) return error.InvalidId3;
    const length = if (version == 2) (@as(u32, bytes[3]) << 16) | (@as(u32, bytes[4]) << 8) | bytes[5] else if (version == 4) try synchsafe(bytes[4..8]) else std.mem.readInt(u32, bytes[4..8], .big);
    if (length == 0 or length > cursor.end - cursor.at) return error.InvalidId3;
    var id: [4]u8 = @splat(0);
    @memcpy(id[0..id_len], bytes[0..id_len]);
    const flags = bytes[9];
    return .{ .id = id, .length = length, .prefix = if (version == 3 and flags & 0x20 != 0) 1 else if (version == 4) @as(u32, @intFromBool(flags & 0x40 != 0)) + 4 * @as(u32, @intFromBool(flags & 1 != 0)) else 0, .unsync = version == 4 and (tag_unsync or flags & 2 != 0), .skipped = if (version == 3) flags & 0xc0 != 0 else if (version == 4) flags & 0x0c != 0 else false };
}

fn decodeUnsync(bytes: []u8) []u8 {
    var out: usize = 0;
    var previous = false;
    for (bytes) |byte| {
        if (previous and byte == 0) {
            previous = false;
            continue;
        }
        bytes[out] = byte;
        out += 1;
        previous = byte == 0xff;
    }
    return bytes[0..out];
}

fn skipExtended(cursor: anytype, version: u8, flags: u8) !void {
    if (version < 3 or flags & 0x40 == 0) return;
    var size: [4]u8 = undefined;
    try cursor.read(&size);
    const extra = if (version == 4) try synchsafe(&size) else std.mem.readInt(u32, &size, .big);
    if (extra < 6) return error.InvalidId3;
    try cursor.skip(if (version == 4) extra - 4 else extra);
}

pub fn extract(a: A, source: anytype) !core.Metadata {
    var result = core.Metadata{ .codec = "mp3" };
    var header: [10]u8 = undefined;
    try source.read(0, &header);
    if (!std.mem.eql(u8, header[0..3], "ID3")) return legacy(a, source, result);
    const version = header[3];
    if (version < 2 or version > 4 or header[4] != 0) return error.UnsupportedId3;
    const length = try synchsafe(header[6..10]);
    if (length > maximum_tag_bytes or 10 + @as(u64, length) > source.length) return error.InvalidId3;
    if (version == 2 and header[5] & 0x40 != 0) return error.UnsupportedId3;
    var cursor = Cursor(@TypeOf(source)){ .source = source, .at = 10, .end = 10 + @as(u64, length), .unsync = version < 4 and header[5] & 0x80 != 0 };
    try skipExtended(&cursor, version, header[5]);
    var digest = std.crypto.hash.Blake3.init(.{});
    for (0..4096) |_| {
        const current = (try frame(&cursor, version, header[5] & 0x80 != 0)) orelse break;
        const id = std.mem.trimEnd(u8, &current.id, "\x00");
        if (std.mem.eql(u8, id, "APIC") or std.mem.eql(u8, id, "PIC")) result.embedded_art = true;
        if (current.skipped or current.id[0] != 'T') {
            try cursor.skip(current.length);
            continue;
        }
        if (current.length > 8193 or current.prefix >= current.length) return error.LongMetadata;
        var buffer: [8193]u8 = undefined;
        try cursor.read(buffer[0..current.length]);
        const body = if (current.unsync) decodeUnsync(buffer[0..current.length]) else buffer[0..current.length];
        if (current.prefix >= body.len) return error.InvalidId3;
        const encoded = body[current.prefix..];
        const value = try text(a, encoded[0], encoded[1..]);
        digest.update(id);
        digest.update(value);
        const ids = [_][]const u8{ "TIT2", "TPE1", "TALB", "TPE2", "TDRC", "TYER", "TCON", "TRCK", "TPOS", "TSOP", "TSO2", "TCMP", "TT2", "TP1", "TAL", "TP2", "TYE", "TCO", "TRK", "TPA" };
        const keys = [_][]const u8{ "TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "DATE", "DATE", "GENRE", "TRACKNUMBER", "DISCNUMBER", "ARTISTSORT", "ALBUMARTISTSORT", "COMPILATION", "TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "DATE", "GENRE", "TRACKNUMBER", "DISCNUMBER" };
        for (ids, keys) |candidate, key| if (std.mem.eql(u8, id, candidate)) {
            apply(&result, key, if (std.mem.indexOfScalar(u8, value, 0)) |end| value[0..end] else value);
            break;
        };
        if (std.mem.eql(u8, id, "TXXX") or std.mem.eql(u8, id, "TXX")) {
            if (std.mem.indexOfScalar(u8, value, 0)) |separator| apply(&result, value[0..separator], withoutBom(value[separator + 1 ..]));
        }
    } else return error.MetadataBudget;
    var hash: [32]u8 = undefined;
    digest.final(&hash);
    result.tag_digest = try core.text(a, &std.fmt.bytesToHex(&hash, .lower));
    return legacy(a, source, result);
}

fn legacy(a: A, source: anytype, initial: core.Metadata) !core.Metadata {
    var result = initial;
    if (source.length < 128) return result;
    var bytes: [128]u8 = undefined;
    try source.read(source.length - 128, &bytes);
    if (!std.mem.eql(u8, bytes[0..3], "TAG")) return result;
    if (result.title.len == 0) result.title = try text(a, 0, std.mem.trimEnd(u8, bytes[3..33], " \x00"));
    if (result.artist.len == 0) result.artist = try text(a, 0, std.mem.trimEnd(u8, bytes[33..63], " \x00"));
    if (result.album.len == 0) result.album = try text(a, 0, std.mem.trimEnd(u8, bytes[63..93], " \x00"));
    if (result.date.len == 0) result.date = try text(a, 0, std.mem.trimEnd(u8, bytes[93..97], " \x00"));
    if (result.track == 0 and bytes[125] == 0) result.track = bytes[126];
    var digest = std.crypto.hash.Blake3.init(.{});
    digest.update(result.tag_digest);
    digest.update(&bytes);
    var hash: [32]u8 = undefined;
    digest.final(&hash);
    result.tag_digest = try core.text(a, &std.fmt.bytesToHex(&hash, .lower));
    return result;
}

/// Return a direct picture range for untransformed APIC/PIC frames. Encrypted,
/// compressed or unsynchronised pictures are not exposed as raw image bytes.
pub fn picture(source: anytype) !?Picture {
    var header: [10]u8 = undefined;
    try source.read(0, &header);
    if (!std.mem.eql(u8, header[0..3], "ID3")) return null;
    const version = header[3];
    if (version < 2 or version > 4 or header[4] != 0 or header[5] & 0x80 != 0 or (version == 2 and header[5] & 0x40 != 0)) return null;
    const length = try synchsafe(header[6..10]);
    if (length > maximum_tag_bytes or 10 + @as(u64, length) > source.length) return error.InvalidId3;
    var cursor = Cursor(@TypeOf(source)){ .source = source, .at = 10, .end = 10 + @as(u64, length) };
    try skipExtended(&cursor, version, header[5]);
    var first: ?Picture = null;
    for (0..4096) |_| {
        const current = (try frame(&cursor, version, false)) orelse return first;
        const start = cursor.at;
        const end = start + current.length;
        const id = std.mem.trimEnd(u8, &current.id, "\x00");
        if (!current.skipped and !current.unsync and (std.mem.eql(u8, id, "APIC") or std.mem.eql(u8, id, "PIC"))) {
            try cursor.skip(current.prefix);
            var byte: [1]u8 = undefined;
            try cursor.read(&byte);
            const encoding = byte[0];
            if (version == 2) try cursor.skip(3) else {
                var count: usize = 0;
                while (true) {
                    try cursor.read(&byte);
                    count += 1;
                    if (byte[0] == 0) break;
                    if (count > 256) return error.InvalidId3;
                }
            }
            try cursor.read(&byte);
            const kind = byte[0];
            if (encoding == 0 or encoding == 3) {
                var count: usize = 0;
                while (true) {
                    if (cursor.at >= end) return error.InvalidId3;
                    try cursor.read(&byte);
                    count += 1;
                    if (byte[0] == 0) break;
                    if (count > 8192) return error.LongMetadata;
                }
            } else if (encoding == 1 or encoding == 2) {
                var unit: [2]u8 = undefined;
                var count: usize = 0;
                while (true) {
                    if (cursor.at + 2 > end) return error.InvalidId3;
                    try cursor.read(&unit);
                    count += 2;
                    if (unit[0] == 0 and unit[1] == 0) break;
                    if (count > 8192) return error.LongMetadata;
                }
            } else return error.InvalidText;
            if (cursor.at >= end) return error.InvalidId3;
            const found = Picture{ .offset = cursor.at, .length = @intCast(end - cursor.at) };
            if (kind == 3) return found;
            if (first == null) first = found;
        }
        cursor.at = end;
    }
    return error.MetadataBudget;
}

const TestSource = struct {
    bytes: []const u8,
    length: u64,
    fn read(self: *@This(), at: u64, out: []u8) !void {
        if (at > self.length or out.len > self.length - at) return error.Truncated;
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
};
const Builder = struct {
    bytes: [4096]u8 = @splat(0),
    used: usize = 10,
    version: u8,
    fn init(version: u8) Builder {
        var self = Builder{ .version = version };
        @memcpy(self.bytes[0..3], "ID3");
        self.bytes[3] = version;
        return self;
    }
    fn size(out: []u8, value: u32) void {
        for (0..4) |i| out[i] = @intCast((value >> @as(u5, @intCast((3 - i) * 7))) & 127);
    }
    fn add(self: *Builder, id: []const u8, body: []const u8) void {
        const header: usize = if (self.version == 2) 6 else 10;
        @memcpy(self.bytes[self.used..][0..id.len], id);
        const n: u32 = @intCast(body.len);
        if (self.version == 4) size(self.bytes[self.used + 4 ..][0..4], n) else if (self.version == 3) std.mem.writeInt(u32, self.bytes[self.used + 4 ..][0..4], n, .big) else {
            self.bytes[self.used + 3] = @truncate(n >> 16);
            self.bytes[self.used + 4] = @truncate(n >> 8);
            self.bytes[self.used + 5] = @truncate(n);
        }
        @memcpy(self.bytes[self.used + header ..][0..body.len], body);
        self.used += header + body.len;
    }
    fn finish(self: *Builder) TestSource {
        size(self.bytes[6..10], @intCast(self.used - 10));
        return .{ .bytes = self.bytes[0..self.used], .length = self.used };
    }
};

test "ID3 versions preserve Unicode text, ordering, compilation and ReplayGain" {
    for ([_]u8{ 2, 3, 4 }) |version| {
        var builder = Builder.init(version);
        builder.add(if (version == 2) "TT2" else "TIT2", &.{ 1, 0xff, 0xfe, 'A', 0, 0x3c, 0xd8, 0xb5, 0xdf });
        builder.add(if (version == 2) "TP2" else "TPE2", "\x03Ensemble");
        builder.add(if (version == 2) "TRK" else "TRCK", "\x0012/15");
        builder.add(if (version == 2) "TPA" else "TPOS", "\x002/3");
        builder.add(if (version == 2) "TXX" else "TXXX", "\x03REPLAYGAIN_TRACK_GAIN\x00-7.25 dB");
        var source = builder.finish();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const meta = try extract(arena.allocator(), &source);
        try std.testing.expectEqualStrings("A🎵", meta.title);
        try std.testing.expectEqualStrings("Ensemble", meta.album_artist);
        try std.testing.expectEqual(12, meta.track);
        try std.testing.expectEqual(2, meta.disc);
        try std.testing.expectEqual(-7.25, meta.gain.track_db.?);
        for (0..source.bytes.len) |length| {
            source.length = length;
            if (extract(arena.allocator(), &source)) |_| return error.AcceptedTruncation else |_| {}
        }
    }
}

test "ID3v2.3 global unsynchronisation leaves text frame lengths logical" {
    var builder = Builder.init(3);
    builder.add("TIT2", &.{ 0, 0xff, 0xe0 });
    var source = builder.finish();
    var encoded: [64]u8 = undefined;
    @memcpy(encoded[0..10], source.bytes[0..10]);
    encoded[5] = 0x80;
    var used: usize = 10;
    for (source.bytes[10..]) |byte| {
        encoded[used] = byte;
        used += 1;
        if (byte == 0xff) {
            encoded[used] = 0;
            used += 1;
        }
    }
    Builder.size(encoded[6..10], @intCast(used - 10));
    source = .{ .bytes = encoded[0..used], .length = used };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const meta = try extract(arena.allocator(), &source);
    try std.testing.expectEqualStrings("ÿà", meta.title);
}

test "APIC range excludes descriptions and favours a front cover" {
    var builder = Builder.init(4);
    builder.add("APIC", "\x00image/jpeg\x00\x04Back\x00bad");
    builder.add("APIC", "\x03image/jpeg\x00\x03Front\x00jpg");
    var source = builder.finish();
    const found = (try picture(&source)).?;
    try std.testing.expectEqual(3, found.length);
    try std.testing.expectEqualStrings("jpg", source.bytes[@intCast(found.offset)..][0..found.length]);
    for (0..source.bytes.len) |length| {
        source.length = length;
        if (picture(&source)) |_| return error.AcceptedTruncatedPicture else |_| {}
    }
}

test "ID3v1 remains a fallback and decodes Latin-1 without fabricating UTF-8" {
    var bytes: [138]u8 = @splat(0);
    @memcpy(bytes[10..13], "TAG");
    @memcpy(bytes[13..17], "Caf\xe9");
    bytes[136] = 9;
    var source = TestSource{ .bytes = &bytes, .length = bytes.len };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const meta = try extract(arena.allocator(), &source);
    try std.testing.expectEqualStrings("Café", meta.title);
    try std.testing.expectEqual(9, meta.track);
    bytes[13] = 'K';
    const changed = try extract(arena.allocator(), &source);
    try std.testing.expect(!std.mem.eql(u8, meta.tag_digest, changed.tag_digest));
}

test "extended headers preserve text and direct artwork offsets in v2.3 and v2.4" {
    for ([_]u8{ 3, 4 }) |version| {
        var builder = Builder.init(version);
        builder.bytes[5] = 0x40;
        const extra: usize = if (version == 3) 10 else 6;
        if (version == 3) std.mem.writeInt(u32, builder.bytes[10..14], 6, .big) else Builder.size(builder.bytes[10..14], 6);
        builder.used += extra;
        builder.add("TIT2", "\x03Synthetic");
        builder.add("APIC", "\x03image/jpeg\x00\x03\x00jpg");
        var source = builder.finish();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const meta = try extract(arena.allocator(), &source);
        try std.testing.expectEqualStrings("Synthetic", meta.title);
        const image = (try picture(&source)).?;
        try std.testing.expectEqualStrings("jpg", source.bytes[@intCast(image.offset)..][0..image.length]);
        for ([_]u8{ 0, 1, 5, 127 }) |invalid| {
            builder.bytes[13] = invalid;
            if (picture(&source)) |_| return error.AcceptedInvalidExtendedHeader else |_| {}
        }
    }
}
