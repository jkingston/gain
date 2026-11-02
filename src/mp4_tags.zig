//! Bounded M4A tag extraction, independent of playback sample-table validation.
//! Repeated values are counted; display slots retain the first value for now.
const std = @import("std");

pub const keys = [_][]const u8{
    "title",
    "artist",
    "album",
    "album_artist",
    "date",
    "genre",
    "track",
    "disc",
    "musicbrainz_albumid",
    "replaygain_track_gain",
    "replaygain_album_gain",
    "replaygain_track_peak",
    "replaygain_album_peak",
    "sort_artist",
    "sort_albumartist",
    "compilation",
};

pub const Summary = extern struct {
    lengths: [keys.len]u32 = @splat(0),
    repeats: [keys.len]u32 = @splat(0),
    values: [keys.len][256]u8 = @splat(@splat(0)),
    art_bytes: u32 = 0,
    art_count: u32 = 0,
    item_count: u32 = 0,
    truncated: u32 = 0,
    tag_digest: [32]u8 = @splat(0),
    art_digest: [32]u8 = @splat(0),
};

pub fn artwork(source: anytype) !?struct { offset: u64, length: u32 } {
    const moov = try find(source, 0, source.length, "moov") orelse return null;
    const udta = try find(source, moov.body, moov.end, "udta") orelse return null;
    const meta = try find(source, udta.body, udta.end, "meta") orelse return null;
    if (meta.end - meta.body < 4) return error.BadMeta;
    const ilst = try find(source, meta.body + 4, meta.end, "ilst") orelse return null;
    const cover = try find(source, ilst.body, ilst.end, "covr") orelse return null;
    const data = try find(source, cover.body, cover.end, "data") orelse return null;
    if (data.end - data.body < 8 or data.end - data.body - 8 > 16 * 1024 * 1024) return error.BadData;
    return .{ .offset = data.body + 8, .length = @intCast(data.end - data.body - 8) };
}

const Atom = struct { start: u64, body: u64, end: u64, kind: [4]u8 };

fn atom(source: anytype, start: u64, end: u64) !Atom {
    if (start > end or end - start < 8) return error.TruncatedAtom;
    var bytes: [8]u8 = undefined;
    try source.read(start, &bytes);
    var size: u64 = std.mem.readInt(u32, bytes[0..4], .big);
    var header: u64 = 8;
    if (size == 1) {
        size = try source.int(u64, start + 8, .big);
        header = 16;
    }
    if (size == 0) size = end - start;
    if (size < header or size > end - start) return error.BadAtomSize;
    return .{ .start = start, .body = start + header, .end = start + size, .kind = bytes[4..8].* };
}

fn is(value: Atom, key: []const u8) bool {
    return std.mem.eql(u8, &value.kind, key);
}

fn find(source: anytype, start: u64, end: u64, key: []const u8) !?Atom {
    var offset = start;
    for (0..8192) |_| {
        if (offset == end) return null;
        const item = try atom(source, offset, end);
        if (is(item, key)) return item;
        offset = item.end;
    }
    return error.AtomBudget;
}

fn payloadHash(source: anytype, state: *std.crypto.hash.Blake3, start: u64, end: u64) !void {
    var offset = start;
    var buffer: [4096]u8 = undefined;
    while (offset < end) {
        const count: usize = @intCast(@min(buffer.len, end - offset));
        try source.read(offset, buffer[0..count]);
        state.update(buffer[0..count]);
        offset += count;
    }
}

fn store(source: anytype, result: *Summary, index: usize, start: u64, end: u64) !void {
    result.repeats[index] += 1;
    if (result.repeats[index] != 1) return;
    var count: usize = @intCast(@min(256, end - start));
    try source.read(start, result.values[index][0..count]);
    if (end - start > count) {
        result.truncated += 1;
        var removed: usize = 0;
        while (count != 0 and !std.unicode.utf8ValidateSlice(result.values[index][0..count]) and removed < 3) : (removed += 1) count -= 1;
    }
    if (!std.unicode.utf8ValidateSlice(result.values[index][0..count])) return error.BadUtf8;
    result.lengths[index] = @intCast(count);
}

pub fn scan(source: anytype, hash_art: bool) !Summary {
    var result = Summary{};
    var tags = std.crypto.hash.Blake3.init(.{});
    var pictures = std.crypto.hash.Blake3.init(.{});
    const moov = try find(source, 0, source.length, "moov") orelse return error.MissingMovie;
    const udta = try find(source, moov.body, moov.end, "udta") orelse return result;
    const meta = try find(source, udta.body, udta.end, "meta") orelse return result;
    if (meta.end - meta.body < 4) return error.BadMeta;
    const ilst = try find(source, meta.body + 4, meta.end, "ilst") orelse return result;
    var offset = ilst.body;
    for (0..8192) |_| {
        if (offset == ilst.end) {
            tags.final(&result.tag_digest);
            if (hash_art) pictures.final(&result.art_digest);
            return result;
        }
        const item = try atom(source, offset, ilst.end);
        result.item_count += 1;
        var slot: ?usize = null;
        const native_keys = [_][]const u8{
            "\xa9nam",
            "\xa9ART",
            "\xa9alb",
            "aART",
            "\xa9day",
            "\xa9gen",
            "trkn",
            "disk",
            "",
            "",
            "",
            "",
            "",
            "soar",
            "soaa",
            "cpil",
        };
        for (native_keys, 0..) |key, index| if (key.len == 4 and is(item, key)) {
            slot = index;
            break;
        };
        if (is(item, "----")) {
            for ([_][]const u8{ "mean", "name" }) |kind| {
                if (try find(source, item.body, item.end, kind)) |part| {
                    tags.update(&part.kind);
                    try payloadHash(source, &tags, part.body, part.end);
                }
            }
            if (try find(source, item.body, item.end, "name")) |name| {
                if (name.end - name.body >= 4 and name.end - name.body - 4 <= 128) {
                    var key: [128]u8 = undefined;
                    const length: usize = @intCast(name.end - name.body - 4);
                    try source.read(name.body + 4, key[0..length]);
                    const custom = [_][]const u8{
                        "MusicBrainz Album Id",
                        "replaygain_track_gain",
                        "replaygain_album_gain",
                        "replaygain_track_peak",
                        "replaygain_album_peak",
                    };
                    for (custom, 8..) |candidate, index| if (std.ascii.eqlIgnoreCase(key[0..length], candidate)) {
                        slot = index;
                        break;
                    };
                }
            }
        }
        var child = item.body;
        var count: usize = 0;
        while (child < item.end) : (count += 1) {
            if (count >= 8192) return error.AtomBudget;
            const data = try atom(source, child, item.end);
            if (is(data, "data")) {
                if (data.end - data.body < 8) return error.BadData;
                const start = data.body + 8;
                if (is(item, "covr")) {
                    result.art_count += 1;
                    result.art_bytes = std.math.add(u32, result.art_bytes, @intCast(data.end - start)) catch return error.TooMuchArt;
                    if (hash_art) {
                        var frame: [8]u8 = undefined;
                        std.mem.writeInt(u64, &frame, data.end - start, .little);
                        pictures.update(&frame);
                        try payloadHash(source, &pictures, start, data.end);
                    }
                } else {
                    // Frame every source item/value, including unknown freeform tags.
                    // A changed source hash triggers normalized-record comparison later.
                    tags.update(&item.kind);
                    var attributes: [8]u8 = undefined;
                    try source.read(data.body, &attributes);
                    tags.update(&attributes);
                    var frame: [8]u8 = undefined;
                    std.mem.writeInt(u64, &frame, data.end - start, .little);
                    tags.update(&frame);
                    try payloadHash(source, &tags, start, data.end);
                    if (slot) |index| {
                        if (index == 6 or index == 7 or index == 15) {
                            result.repeats[index] += 1;
                            if (result.repeats[index] == 1) {
                                var bytes: [8]u8 = @splat(0);
                                const length: usize = @intCast(@min(bytes.len, data.end - start));
                                try source.read(start, bytes[0..length]);
                                const number = if (index == 15) @as(u16, bytes[0]) else if (length >= 4) std.mem.readInt(u16, bytes[2..4], .big) else return error.BadNumber;
                                const text = try std.fmt.bufPrint(&result.values[index], "{d}", .{number});
                                result.lengths[index] = @intCast(text.len);
                            }
                        } else try store(source, &result, index, start, data.end);
                    }
                }
            }
            child = data.end;
        }
        offset = item.end;
    }
    return error.AtomBudget;
}
