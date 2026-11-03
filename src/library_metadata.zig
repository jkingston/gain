//! Native bounded tags. MP4 tags are independent of sample tables; FLAC/Vorbis
//! comments retain common display/ReplayGain fields. Unknown tags are skipped.
const std = @import("std");
const catalog = @import("library.zig");
const tags = @import("mp4_tags.zig");

const A = std.mem.Allocator;

fn number(text: []const u8) u32 {
    var parts = std.mem.tokenizeAny(u8, text, "/ ");
    return std.fmt.parseInt(u32, parts.next() orelse "", 10) catch 0;
}

fn gain(text: []const u8) ?f64 {
    var parts = std.mem.tokenizeAny(u8, text, " dB");
    const value = std.fmt.parseFloat(f64, parts.next() orelse "") catch return null;
    return if (std.math.isFinite(value)) value else null;
}

pub fn extract(a: A, source: anytype, extension: []const u8) !catalog.Metadata {
    if (std.ascii.eqlIgnoreCase(extension, ".m4a") or std.ascii.eqlIgnoreCase(extension, ".m4b") or std.ascii.eqlIgnoreCase(extension, ".mp4")) {
        const info = try @import("mp4.zig").parse(source);
        const summary = try tags.scan(source, false);
        if (summary.truncated != 0) return error.LongMetadata;
        var fields: [16][]const u8 = undefined;
        for (&fields, 0..) |*field, i| field.* = summary.values[i][0..summary.lengths[i]];
        return .{
            .title = try catalog.text(a, fields[0]),
            .artist = try catalog.text(a, fields[1]),
            .album = try catalog.text(a, fields[2]),
            .album_artist = try catalog.text(a, fields[3]),
            .date = try catalog.text(a, fields[4]),
            .genre = try catalog.text(a, fields[5]),
            .track = number(fields[6]),
            .disc = number(fields[7]),
            .release_id = try catalog.text(a, fields[8]),
            .sort_artist = try catalog.text(a, fields[13]),
            .sort_album_artist = try catalog.text(a, fields[14]),
            .compilation = number(fields[15]) != 0,
            .codec = @tagName(info.kind),
            .duration_ms = if (info.rate == 0) 0 else info.frames * 1000 / info.rate,
            .sample_rate = info.rate,
            .channels = info.channels,
            .bits = info.bits,
            .embedded_art = summary.art_count != 0,
            .tag_digest = try catalog.text(a, &std.fmt.bytesToHex(&summary.tag_digest, .lower)),
            .gain = .{ .track_db = gain(fields[9]), .album_db = gain(fields[10]), .track_peak = gain(fields[11]), .album_peak = gain(fields[12]) },
        };
    }
    var magic: [4]u8 = undefined;
    try source.read(0, &magic);
    var result = catalog.Metadata{ .codec = try catalog.text(a, extension) };
    if (std.mem.eql(u8, &magic, "fLaC")) {
        result.codec = "flac";
        var at: u64 = 4;
        var fingerprint = std.crypto.hash.Blake3.init(.{});
        for (0..4096) |_| {
            var header: [4]u8 = undefined;
            try source.read(at, &header);
            at += 4;
            const size = (@as(u32, header[1]) << 16) | (@as(u32, header[2]) << 8) | header[3];
            if (at > source.length or size > source.length - at) return error.Truncated;
            switch (header[0] & 127) {
                0 => {
                    if (size != 34) return error.BadStreamInfo;
                    var info: [34]u8 = undefined;
                    try source.read(at, &info);
                    const stream = try @import("flac.zig").parseStreamInfoBlock(&info);
                    if (stream.sample_rate == 0) return error.BadStreamInfo;
                    result.sample_rate = stream.sample_rate;
                    result.channels = stream.channels;
                    result.bits = stream.bits_per_sample;
                    result.duration_ms = stream.total_samples * 1000 / stream.sample_rate;
                },
                4 => {
                    try comments(a, source, at, size, &result);
                    try hashRange(source, at, size, &fingerprint);
                },
                6 => result.embedded_art = true,
                else => {},
            }
            at += size;
            if (header[0] & 128 != 0) {
                var digest: [32]u8 = undefined;
                fingerprint.final(&digest);
                result.tag_digest = try catalog.text(a, &std.fmt.bytesToHex(&digest, .lower));
                return result;
            }
        }
        return error.MetadataBudget;
    }
    // Filename/folder fallbacks remain available for formats without library
    // tag extraction; decoding support is independent of this metadata layer.
    return result;
}

pub fn hashRange(source: anytype, at: u64, length: u64, state: *std.crypto.hash.Blake3) !void {
    var bytes: [4096]u8 = undefined;
    var done: u64 = 0;
    while (done < length) {
        const n: usize = @intCast(@min(bytes.len, length - done));
        try source.read(at + done, bytes[0..n]);
        state.update(bytes[0..n]);
        done += n;
    }
}

fn comments(a: A, source: anytype, at: u64, length: u32, result: *catalog.Metadata) !void {
    const end = at + length;
    if (length < 8) return error.BadComments;
    const vendor = try source.int(u32, at, .little);
    var cursor = at + 4;
    if (vendor > end - cursor) return error.BadComments;
    cursor += vendor;
    if (end - cursor < 4) return error.BadComments;
    const count = try source.int(u32, cursor, .little);
    cursor += 4;
    if (count > 65536) return error.MetadataBudget;
    for (0..count) |_| {
        if (end - cursor < 4) return error.BadComments;
        const size = try source.int(u32, cursor, .little);
        cursor += 4;
        if (size > end - cursor) return error.BadComments;
        var prefix: [64]u8 = undefined;
        const n = @min(size, prefix.len);
        try source.read(cursor, prefix[0..n]);
        if (std.mem.indexOfScalar(u8, prefix[0..n], '=')) |separator| {
            const key = prefix[0..separator];
            const keys = [_][]const u8{
                "TITLE",
                "ARTIST",
                "ALBUM",
                "ALBUMARTIST",
                "DATE",
                "GENRE",
                "TRACKNUMBER",
                "DISCNUMBER",
                "MUSICBRAINZ_ALBUMID",
                "REPLAYGAIN_TRACK_GAIN",
                "REPLAYGAIN_ALBUM_GAIN",
                "REPLAYGAIN_TRACK_PEAK",
                "REPLAYGAIN_ALBUM_PEAK",
            };
            for (keys, 0..) |candidate, index| {
                if (std.ascii.eqlIgnoreCase(key, candidate)) {
                    const bytes = size - @as(u32, @intCast(separator)) - 1;
                    if (bytes > 4096) return error.LongMetadata;
                    const value = try a.alloc(u8, bytes);
                    try source.read(cursor + separator + 1, value);
                    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
                    switch (index) {
                        0 => result.title = value,
                        1 => result.artist = value,
                        2 => result.album = value,
                        3 => result.album_artist = value,
                        4 => result.date = value,
                        5 => result.genre = value,
                        6 => result.track = number(value),
                        7 => result.disc = number(value),
                        8 => result.release_id = value,
                        9 => result.gain.track_db = gain(value),
                        10 => result.gain.album_db = gain(value),
                        11 => result.gain.track_peak = gain(value),
                        12 => result.gain.album_peak = gain(value),
                        else => unreachable,
                    }
                    break;
                }
            }
        }
        cursor += size;
    }
}

pub const PictureRange = struct { offset: u64, length: u32 };

/// Locate image bytes without loading the image or FLAC picture strings.
pub fn embeddedPicture(source: anytype) !?PictureRange {
    var magic: [4]u8 = undefined;
    try source.read(0, &magic);
    if (!std.mem.eql(u8, &magic, "fLaC")) {
        const picture = try tags.artwork(source) orelse return null;
        return .{ .offset = picture.offset, .length = picture.length };
    }
    var first: ?PictureRange = null;
    var at: u64 = 4;
    for (0..4096) |_| {
        var header: [4]u8 = undefined;
        try source.read(at, &header);
        at += 4;
        const size = (@as(u32, header[1]) << 16) | (@as(u32, header[2]) << 8) | header[3];
        if (at > source.length or size > source.length - at) return error.Truncated;
        const end = at + size;
        if (header[0] & 127 == 6) {
            if (size < 32) return error.BadPicture;
            const kind = try source.int(u32, at, .big);
            const mime = try source.int(u32, at + 4, .big);
            var cursor = at + 8;
            if (mime > end - cursor) return error.BadPicture;
            cursor += mime;
            if (end - cursor < 4) return error.BadPicture;
            const description = try source.int(u32, cursor, .big);
            cursor += 4;
            if (description > end - cursor) return error.BadPicture;
            cursor += description;
            if (end - cursor < 20) return error.BadPicture;
            const length = try source.int(u32, cursor + 16, .big);
            cursor += 20;
            if (length == 0 or length > end - cursor) return error.BadPicture;
            const picture = PictureRange{ .offset = cursor, .length = length };
            if (kind == 3) return picture;
            if (first == null) first = picture;
        }
        at = end;
        if (header[0] & 128 != 0) return first;
    }
    return error.MetadataBudget;
}

const TestSource = struct {
    bytes: []const u8,
    length: u64,

    pub fn read(self: *@This(), at: u64, out: []u8) !void {
        if (at > self.length or out.len > self.length - at) return error.Truncated;
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }

    pub fn int(self: *@This(), comptime T: type, at: u64, comptime endian: std.builtin.Endian) !T {
        var out: [@sizeOf(T)]u8 = undefined;
        try self.read(at, &out);
        return std.mem.readInt(T, &out, endian);
    }
};

test "FLAC library metadata parses the STREAMINFO payload rather than a file" {
    var bytes: [42]u8 = @splat(0);
    @memcpy(bytes[0..4], "fLaC");
    bytes[4] = 0x80;
    bytes[7] = 34;
    std.mem.writeInt(u16, bytes[8..10], 4096, .big);
    std.mem.writeInt(u16, bytes[10..12], 4096, .big);
    const fields: u64 = (@as(u64, 44100) << 44) | (@as(u64, 1) << 41) | (@as(u64, 23) << 36) | 88200;
    std.mem.writeInt(u64, bytes[18..26], fields, .big);
    var source = TestSource{ .bytes = &bytes, .length = bytes.len };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const metadata = try extract(arena.allocator(), &source, ".flac");
    try std.testing.expectEqualStrings("flac", metadata.codec);
    try std.testing.expectEqual(44100, metadata.sample_rate);
    try std.testing.expectEqual(2, metadata.channels);
    try std.testing.expectEqual(24, metadata.bits);
    try std.testing.expectEqual(2000, metadata.duration_ms);
    std.mem.writeInt(u64, bytes[18..26], fields & ((@as(u64, 1) << 44) - 1), .big);
    try std.testing.expectError(error.BadStreamInfo, extract(arena.allocator(), &source, ".flac"));
}

test "FLAC picture ranges are bounded and do not include picture metadata" {
    var bytes: [43]u8 = @splat(0);
    @memcpy(bytes[0..4], "fLaC");
    bytes[4] = 0x86;
    bytes[7] = 35;
    std.mem.writeInt(u32, bytes[8..12], 3, .big);
    std.mem.writeInt(u32, bytes[36..40], 3, .big);
    @memcpy(bytes[40..43], "jpg");
    var source = TestSource{ .bytes = &bytes, .length = bytes.len };
    const range = (try embeddedPicture(&source)).?;
    try std.testing.expectEqual(40, range.offset);
    try std.testing.expectEqual(3, range.length);
    for (0..bytes.len) |length| {
        source.length = length;
        if (embeddedPicture(&source)) |_| return error.AcceptedTruncation else |_| {}
    }
    source.length = bytes.len;
    std.mem.writeInt(u32, bytes[36..40], 4, .big);
    try std.testing.expectError(error.BadPicture, embeddedPicture(&source));
}
