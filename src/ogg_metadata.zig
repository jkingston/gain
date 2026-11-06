//! Streaming Vorbis/Opus comments. Only requested text is retained; large
//! pictures and unknown comments are skipped without a packet-sized allocation.
const std = @import("std");
const ogg = @import("ogg.zig");
const core = @import("library.zig");
const id3 = @import("id3.zig");
const maximum_header_bytes = 16 * 1024 * 1024;

fn Stream(comptime Source: type) type {
    return struct {
        source: Source,
        offset: u64 = 0,
        serial: ?u32 = null,
        sequence: u32 = 0,
        laces: [255]u8 = undefined,
        count: usize = 0,
        segment: usize = 0,
        used: u32 = 0,
        body: u64 = 0,
        packet_end: bool = true,
        total_read: u32 = 0,
        pages: u32 = 0,

        fn page(self: *@This(), continuation: bool) !void {
            self.pages += 1;
            if (self.pages > 65536) return error.MetadataBudget;
            var header: [27]u8 = undefined;
            try self.source.read(self.offset, &header);
            if (!std.mem.eql(u8, header[0..4], "OggS") or header[4] != 0 or header[5] & 0xf8 != 0 or ((header[5] & 1 != 0) != continuation)) return error.BadOggHeader;
            const serial = std.mem.readInt(u32, header[14..18], .little);
            const sequence = std.mem.readInt(u32, header[18..22], .little);
            if (self.serial) |old| {
                if (serial != old or sequence != self.sequence +% 1 or header[5] & 2 != 0) return error.BadSequence;
            } else {
                if (header[5] & 2 == 0 or sequence != 0) return error.BadBos;
                self.serial = serial;
            }
            self.sequence = sequence;
            self.count = header[26];
            self.segment = 0;
            self.used = 0;
            if (self.count == 0) return error.EmptyPage;
            try self.source.read(self.offset + 27, self.laces[0..self.count]);
            self.body = self.offset + 27 + self.count;
            var size: u32 = 0;
            for (self.laces[0..self.count]) |n| size += n;
            if (self.body > self.source.length or size > self.source.length - self.body) return error.Truncated;
            const expected = std.mem.readInt(u32, header[22..26], .little);
            @memset(header[22..26], 0);
            var checksum = ogg.crc(ogg.crc(0, &header), self.laces[0..self.count]);
            var bytes: [1024]u8 = undefined;
            var done: u32 = 0;
            while (done < size) {
                const n = @min(bytes.len, size - done);
                try self.source.read(self.body + done, bytes[0..n]);
                checksum = ogg.crc(checksum, bytes[0..n]);
                done += n;
            }
            if (checksum != expected) return error.BadCrc;
            self.offset = self.body + size;
        }
        fn next(self: *@This()) !void {
            var discard: [512]u8 = undefined;
            while (!self.packet_end) {
                if (try self.read(&discard) == 0 and !self.packet_end) return error.Truncated;
            }
            if (self.segment == self.count) try self.page(false);
            self.packet_end = false;
        }
        fn read(self: *@This(), bytes: []u8) !usize {
            var done: usize = 0;
            while (done < bytes.len and !self.packet_end) {
                if (self.segment == self.count) try self.page(true);
                const available = self.laces[self.segment] - self.used;
                const n = @min(available, bytes.len - done);
                if (n != 0) {
                    try self.source.read(self.body + self.used, bytes[done..][0..n]);
                    self.used += @intCast(n);
                    done += n;
                    self.total_read += @intCast(n);
                    if (self.total_read > maximum_header_bytes) return error.MetadataBudget;
                }
                if (self.used == self.laces[self.segment]) {
                    const end = self.laces[self.segment] < 255;
                    self.body += self.used;
                    self.used = 0;
                    self.segment += 1;
                    if (end) self.packet_end = true;
                }
            }
            return done;
        }
        fn exact(self: *@This(), bytes: []u8) !void {
            if (try self.read(bytes) != bytes.len) return error.Truncated;
        }
        fn skip(self: *@This(), size: u32) !void {
            if (size > maximum_header_bytes) return error.MetadataBudget;
            var left = size;
            var bytes: [1024]u8 = undefined;
            while (left != 0) {
                const n = @min(left, bytes.len);
                try self.exact(bytes[0..n]);
                left -= n;
            }
        }
        fn number(self: *@This()) !u32 {
            var bytes: [4]u8 = undefined;
            try self.exact(&bytes);
            return std.mem.readInt(u32, &bytes, .little);
        }
    };
}

pub fn extract(a: std.mem.Allocator, source: anytype) !core.Metadata {
    var stream = Stream(@TypeOf(source)){ .source = source };
    try stream.next();
    var first: [19]u8 = undefined;
    try stream.exact(&first);
    var result: core.Metadata = undefined;
    var preskip: u32 = 0;
    if (std.mem.eql(u8, first[0..8], "OpusHead")) {
        if (first[8] > 15 or first[9] < 1 or first[9] > 2 or first[18] != 0) return error.UnsupportedOpusMapping;
        result = .{ .codec = "opus", .sample_rate = 48000, .channels = first[9] };
        preskip = std.mem.readInt(u16, first[10..12], .little);
    } else if (first[0] == 1 and std.mem.eql(u8, first[1..7], "vorbis")) {
        if (std.mem.readInt(u32, first[7..11], .little) != 0 or first[11] < 1 or first[11] > 2) return error.UnsupportedFormat;
        result = .{ .codec = "vorbis", .sample_rate = std.mem.readInt(u32, first[12..16], .little), .channels = first[11] };
        if (result.sample_rate == 0) return error.UnsupportedSampleRate;
    } else return error.UnsupportedCodec;
    try stream.next();
    var signature: [8]u8 = undefined;
    const opus = std.mem.eql(u8, result.codec, "opus");
    const signature_bytes: usize = if (opus) 8 else 7;
    try stream.exact(signature[0..signature_bytes]);
    if (opus) {
        if (!std.mem.eql(u8, &signature, "OpusTags")) return error.BadComments;
    } else if (signature[0] != 3 or !std.mem.eql(u8, signature[1..7], "vorbis")) return error.BadComments;
    try stream.skip(try stream.number());
    const count = try stream.number();
    if (count > 65536) return error.MetadataBudget;
    var hash = std.crypto.hash.Blake3.init(.{});
    for (0..count) |_| {
        const size = try stream.number();
        if (size > maximum_header_bytes) return error.MetadataBudget;
        var key_buffer: [64]u8 = undefined;
        var key_length: usize = 0;
        var found = false;
        while (key_length < size and key_length < key_buffer.len) {
            try stream.exact(key_buffer[key_length..][0..1]);
            if (key_buffer[key_length] == '=') {
                found = true;
                break;
            }
            key_length += 1;
        }
        if (!found) {
            try stream.skip(size - @as(u32, @intCast(key_length)));
            continue;
        }
        const length = size - @as(u32, @intCast(key_length)) - 1;
        const key = key_buffer[0..key_length];
        if (std.ascii.eqlIgnoreCase(key, "METADATA_BLOCK_PICTURE")) result.embedded_art = true;
        const keys = [_][]const u8{ "TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "ALBUM ARTIST", "DATE", "GENRE", "TRACKNUMBER", "DISCNUMBER", "ARTISTSORT", "ALBUMARTISTSORT", "COMPILATION", "MUSICBRAINZ_ALBUMID", "MUSICBRAINZ_TRACKID", "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_TRACK_PEAK", "REPLAYGAIN_ALBUM_PEAK", "R128_TRACK_GAIN", "R128_ALBUM_GAIN" };
        var wanted = false;
        for (keys) |name| if (std.ascii.eqlIgnoreCase(key, name)) {
            wanted = true;
            break;
        };
        if (!wanted) {
            try stream.skip(length);
            continue;
        }
        if (length > 4096) return error.LongMetadata;
        var bytes: [4096]u8 = undefined;
        try stream.exact(bytes[0..length]);
        if (!std.unicode.utf8ValidateSlice(bytes[0..length]) or std.mem.indexOfScalar(u8, bytes[0..length], 0) != null) return error.InvalidText;
        const value = try core.text(a, bytes[0..length]);
        hash.update(key);
        hash.update(value);
        id3.apply(&result, key, value);
        if (opus and (std.ascii.eqlIgnoreCase(key, "R128_TRACK_GAIN") or std.ascii.eqlIgnoreCase(key, "R128_ALBUM_GAIN"))) {
            if (value.len > 6) return error.BadComments;
            const q = std.fmt.parseInt(i16, value, 10) catch return error.BadComments;
            // OpusHead gain is already applied by libopus. Match the player's
            // ReplayGain reference with a +5 dB normalization preamp for R128.
            const db = @as(f64, @floatFromInt(q)) / 256 + 5;
            if (std.ascii.eqlIgnoreCase(key, "R128_TRACK_GAIN")) result.gain.track_db = db else result.gain.album_db = db;
        }
    }
    if (!opus) {
        var framing: [1]u8 = undefined;
        try stream.exact(&framing);
        if (framing[0] != 1) return error.BadComments;
    }
    if (try ogg.finalGranule(source, stream.serial.?)) |frames| {
        const total = frames - @min(frames, preskip);
        const whole = @mulWithOverflow(total / result.sample_rate, @as(u64, 1000));
        const fraction = (total % result.sample_rate) * 1000 / result.sample_rate;
        const milliseconds = @addWithOverflow(whole[0], fraction);
        if (whole[1] != 0 or milliseconds[1] != 0) return error.BadGranule;
        result.duration_ms = milliseconds[0];
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    result.tag_digest = try core.text(a, &std.fmt.bytesToHex(&digest, .lower));
    return result;
}
