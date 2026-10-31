//! Bounded MP4 audio sample tables, edits and metadata. Source storage is supplied by the caller.
const std = @import("std");
const Atom = struct { start: u64, body: u64, end: u64, kind: [4]u8 };
fn atom(s: anytype, at: u64, end: u64) !Atom {
    if (at > end or end - at < 8) return error.TruncatedAtom;
    var b: [8]u8 = undefined;
    try s.read(at, &b);
    var size: u64 = std.mem.readInt(u32, b[0..4], .big);
    var header: u64 = 8;
    if (size == 1) {
        if (end - at < 16) return error.TruncatedAtom;
        size = try s.int(u64, at + 8, .big);
        header = 16;
    }
    if (size == 0) size = end - at;
    if (size < header or size > end - at) return error.BadAtomSize;
    return .{ .start = at, .body = at + header, .end = at + size, .kind = b[4..8].* };
}
fn is(a: Atom, key: []const u8) bool {
    return std.mem.eql(u8, &a.kind, key);
}
fn find(s: anytype, start: u64, end: u64, key: []const u8) !?Atom {
    var at = start;
    var budget: usize = 0;
    while (at < end) : (budget += 1) {
        if (budget >= 4096) return error.AtomBudget;
        const a = try atom(s, at, end);
        if (is(a, key)) return a;
        at = a.end;
    }
    return null;
}
fn minimum(a: Atom, bytes: u64) !void {
    if (a.end - a.body < bytes) return error.TruncatedAtom;
}
fn child(s: anytype, a: Atom, key: []const u8) !Atom {
    return try find(s, a.body, a.end, key) orelse error.MissingAtom;
}
pub const Packet = struct { offset: u64, size: u32, dts: u64, duration: u32 };
pub const Chapter = struct { ticks_100ns: u64 = 0, name: [128]u8 = @splat(0), len: usize = 0 };
pub const Track = struct {
    kind: enum { aac, alac } = .aac,
    rate: u32 = 0,
    channels: u32 = 0,
    bits: u32 = 0,
    config: [128]u8 = @splat(0),
    config_len: usize = 0,
    title: [128]u8 = @splat(0),
    title_len: usize = 0,
    count: u32 = 0,
    chunks: u32 = 0,
    stsz: u64 = 0,
    stco: u64 = 0,
    stsc: u64 = 0,
    stts: u64 = 0,
    stsc_count: u32 = 0,
    stts_count: u32 = 0,
    fixed_size: u32 = 0,
    co64: bool = false,
    media_duration: u64 = 0,
    lead: u64 = 0,
    frames: u64 = 0,
    pub fn size(self: *const Track, s: anytype, index: u32) !u32 {
        if (index >= self.count) return error.SampleBounds;
        return if (self.fixed_size != 0) self.fixed_size else s.int(u32, self.stsz + @as(u64, index) * 4, .big);
    }
    pub fn packet(self: *const Track, s: anytype, index: u32) !Packet {
        if (index >= self.count) return error.SampleBounds;
        var sample_base: u64 = 0;
        var chunk: u64 = 0;
        var in_chunk: u64 = 0;
        for (0..self.stsc_count) |i| {
            const p = self.stsc + i * 12;
            const first = try s.int(u32, p, .big);
            const per = try s.int(u32, p + 4, .big);
            const desc = try s.int(u32, p + 8, .big);
            const next = if (i + 1 < self.stsc_count) try s.int(u32, p + 12, .big) else self.chunks + 1;
            if (first == 0 or first > self.chunks or next <= first or next > self.chunks + 1 or per == 0 or per > 65536 or desc != 1) return error.BadChunkMap;
            const n = @as(u64, next - first) * per;
            if (index < sample_base + n) {
                chunk = first + (index - sample_base) / per;
                in_chunk = (index - sample_base) % per;
                break;
            }
            sample_base += n;
        }
        if (chunk == 0) return error.MissingChunk;
        var offset = if (self.co64) try s.int(u64, self.stco + (chunk - 1) * 8, .big) else @as(u64, try s.int(u32, self.stco + (chunk - 1) * 4, .big));
        var previous: u32 = index - @as(u32, @intCast(in_chunk));
        while (previous < index) : (previous += 1) offset = std.math.add(u64, offset, try self.size(s, previous)) catch return error.BadOffset;
        const length = try self.size(s, index);
        if (length == 0 or offset > s.length or length > s.length - offset) return error.BadOffset;
        var base: u64 = 0;
        var dts: u64 = 0;
        for (0..self.stts_count) |i| {
            const n = try s.int(u32, self.stts + i * 8, .big);
            const delta = try s.int(u32, self.stts + i * 8 + 4, .big);
            if (n == 0 or delta == 0 or delta > 4096) return error.BadTiming;
            if (index < base + n) return .{ .offset = offset, .size = length, .dts = dts + (index - base) * delta, .duration = delta };
            base += n;
            dts += @as(u64, n) * delta;
        }
        return error.MissingTiming;
    }
    pub fn seekSample(self: *const Track, s: anytype, frame: u64) !u32 {
        const target = std.math.add(u64, @min(frame, self.frames), self.lead) catch return error.BadTiming;
        var base: u64 = 0;
        var dts: u64 = 0;
        for (0..self.stts_count) |i| {
            const n = try s.int(u32, self.stts + i * 8, .big);
            const delta = try s.int(u32, self.stts + i * 8 + 4, .big);
            if (n == 0 or delta == 0 or delta > 4096) return error.BadTiming;
            const end = dts + @as(u64, n) * delta;
            if (target < end) return @intCast(@min(self.count - 1, base + (target - dts) / delta));
            base += n;
            dts = end;
        }
        return self.count - 1;
    }
};
fn table(s: anytype, a: Atom, width: u64) !struct { at: u64, count: u32 } {
    if (a.end - a.body < 8) return error.TruncatedTable;
    const count = try s.int(u32, a.body + 4, .big);
    if (count == 0 or count > 1000000 or @as(u64, count) * width > a.end - a.body - 8) return error.BadTable;
    return .{ .at = a.body + 8, .count = count };
}
fn descriptor(bytes: []const u8, at: *usize) !struct { tag: u8, data: []const u8 } {
    if (at.* >= bytes.len) return error.BadDescriptor;
    const tag = bytes[at.*];
    at.* += 1;
    var length: usize = 0;
    var ready = false;
    for (0..4) |_| {
        if (at.* >= bytes.len) return error.BadDescriptor;
        const b = bytes[at.*];
        at.* += 1;
        length = (length << 7) | (b & 127);
        if (b & 128 == 0) {
            ready = true;
            break;
        }
    }
    if (!ready or length > bytes.len - at.*) return error.BadDescriptor;
    const data = bytes[at.*..][0..length];
    at.* += length;
    return .{ .tag = tag, .data = data };
}
fn esds(t: *Track, bytes: []const u8) !void {
    var at: usize = 0;
    const es = try descriptor(bytes, &at);
    if (es.tag != 3 or es.data.len < 3) return error.BadDescriptor;
    const flags = es.data[2];
    var pos: usize = 3;
    if (flags & 128 != 0) pos += 2;
    if (flags & 64 != 0) {
        if (pos >= es.data.len) return error.BadDescriptor;
        pos += 1 + es.data[pos];
    }
    if (flags & 32 != 0) pos += 2;
    const dec = try descriptor(es.data, &pos);
    if (dec.tag != 4 or dec.data.len < 13 or dec.data[0] != 0x40) return error.UnsupportedCodec;
    pos = 13;
    const cfg = try descriptor(dec.data, &pos);
    if (cfg.tag != 5 or cfg.data.len < 2 or cfg.data.len > t.config.len) return error.BadDescriptor;
    if (cfg.data[0] >> 3 != 2) return error.UnsupportedAacProfile;
    @memcpy(t.config[0..cfg.data.len], cfg.data);
    t.config_len = cfg.data.len;
}
fn parseTrack(s: anytype, tr: Atom, movie_rate: u32) !?Track {
    const mdia = try child(s, tr, "mdia");
    const handler = try child(s, mdia, "hdlr");
    try minimum(handler, 12);
    var h: [4]u8 = undefined;
    try s.read(handler.body + 8, &h);
    if (!std.mem.eql(u8, &h, "soun")) return null;
    var t = Track{};
    const mdhd = try child(s, mdia, "mdhd");
    try minimum(mdhd, 1);
    const version = try s.int(u8, mdhd.body, .big);
    if (version > 1) return error.BadVersion;
    try minimum(mdhd, if (version == 1) 32 else 20);
    const rate_at = mdhd.body + (if (version == 1) @as(u64, 20) else 12);
    t.rate = try s.int(u32, rate_at, .big);
    t.media_duration = if (version == 1) try s.int(u64, rate_at + 4, .big) else try s.int(u32, rate_at + 4, .big);
    if (t.rate == 0 or t.rate > 384000 or t.media_duration == 0) return error.BadTiming;
    t.frames = t.media_duration;
    if (try find(s, tr.body, tr.end, "edts")) |edts| {
        const e = try child(s, edts, "elst");
        try minimum(e, 8);
        const ver = try s.int(u8, e.body, .big);
        const n = try s.int(u32, e.body + 4, .big);
        if (n != 1 or ver > 1) return error.UnsupportedEdits;
        try minimum(e, if (ver == 1) 28 else 20);
        const duration = if (ver == 1) try s.int(u64, e.body + 8, .big) else @as(u64, try s.int(u32, e.body + 8, .big));
        const media = if (ver == 1) try s.int(i64, e.body + 16, .big) else @as(i64, try s.int(i32, e.body + 12, .big));
        if (media < 0 or movie_rate == 0) return error.UnsupportedEdits;
        t.lead = @intCast(media);
        t.frames = std.math.mul(u64, duration, t.rate) catch return error.BadTiming;
        t.frames /= movie_rate;
        const speed = try s.int(u32, e.body + (if (ver == 1) @as(u64, 24) else 16), .big);
        if (speed != 0x10000) return error.UnsupportedEdits;
        if (t.lead > t.media_duration or t.frames > t.media_duration - t.lead) return error.BadTiming;
    }
    const stbl = try child(s, try child(s, mdia, "minf"), "stbl");
    const stsd = try child(s, stbl, "stsd");
    try minimum(stsd, 8);
    if (try s.int(u32, stsd.body + 4, .big) != 1) return error.UnsupportedDescriptions;
    const entry = try atom(s, stsd.body + 8, stsd.end);
    if (is(entry, "mp4a")) t.kind = .aac else if (is(entry, "alac")) t.kind = .alac else return error.UnsupportedCodec;
    try minimum(entry, 28);
    const audio_version = try s.int(u16, entry.body + 8, .big);
    if (audio_version > 1) return error.UnsupportedAudioVersion;
    t.channels = try s.int(u16, entry.body + 16, .big);
    t.bits = try s.int(u16, entry.body + 18, .big);
    if (t.channels < 1 or t.channels > 2) return error.UnsupportedChannels;
    const cfg = try find(s, entry.body + (if (audio_version == 1) @as(u64, 44) else 28), entry.end, if (t.kind == .aac) "esds" else "alac") orelse return error.MissingConfig;
    if (t.kind == .aac) {
        var data: [512]u8 = undefined;
        const n = cfg.end - cfg.body;
        if (n < 4 or n > data.len) return error.BadDescriptor;
        try s.read(cfg.body, data[0..@intCast(n)]);
        try esds(&t, data[4..@intCast(n)]);
    } else {
        if (cfg.end - cfg.body != 28) return error.BadAlacConfig;
        try s.read(cfg.body + 4, t.config[0..24]);
        t.config_len = 24;
        t.bits = t.config[5];
        if (t.bits != 16 and t.bits != 24) return error.UnsupportedPrecision;
        if (t.config[9] != t.channels or std.mem.readInt(u32, t.config[20..24], .big) != t.rate) return error.BadAlacConfig;
        const block = std.mem.readInt(u32, t.config[0..4], .big);
        if (block == 0 or block > 4096) return error.BadAlacConfig;
    }
    const sizes = try child(s, stbl, "stsz");
    if (sizes.end - sizes.body < 12) return error.BadTable;
    t.fixed_size = try s.int(u32, sizes.body + 4, .big);
    t.count = try s.int(u32, sizes.body + 8, .big);
    t.stsz = sizes.body + 12;
    if (t.count == 0 or t.count > 10000000 or (t.fixed_size == 0 and @as(u64, t.count) * 4 > sizes.end - t.stsz)) return error.BadTable;
    const offsets = try find(s, stbl.body, stbl.end, "stco") orelse try child(s, stbl, "co64");
    t.co64 = is(offsets, "co64");
    const co = try table(s, offsets, if (t.co64) 8 else 4);
    t.stco = co.at;
    t.chunks = co.count;
    const sc = try table(s, try child(s, stbl, "stsc"), 12);
    t.stsc = sc.at;
    t.stsc_count = sc.count;
    if (sc.count > 4096) return error.BadTable;
    const ts = try table(s, try child(s, stbl, "stts"), 8);
    t.stts = ts.at;
    t.stts_count = ts.count;
    if (ts.count > 4096) return error.BadTable;
    // Validate every index run once; no file-sized allocation is needed.
    var samples: u64 = 0;
    var duration: u64 = 0;
    for (0..ts.count) |i| {
        const n = try s.int(u32, ts.at + i * 8, .big);
        const delta = try s.int(u32, ts.at + i * 8 + 4, .big);
        if (n == 0 or delta == 0 or delta > 4096) return error.BadTiming;
        samples += n;
        duration = std.math.add(u64, duration, @as(u64, n) * delta) catch return error.BadTiming;
    }
    var chunk_samples: u64 = 0;
    for (0..t.stsc_count) |i| {
        const first = try s.int(u32, t.stsc + i * 12, .big);
        const per = try s.int(u32, t.stsc + i * 12 + 4, .big);
        const desc = try s.int(u32, t.stsc + i * 12 + 8, .big);
        const next = if (i + 1 < t.stsc_count) try s.int(u32, t.stsc + (i + 1) * 12, .big) else t.chunks + 1;
        if ((i == 0 and first != 1) or first == 0 or next <= first or next > t.chunks + 1 or per == 0 or per > 65536 or desc != 1) return error.BadChunkMap;
        chunk_samples += @as(u64, next - first) * per;
    }
    if (chunk_samples != t.count) return error.BadChunkMap;
    if (samples != t.count or duration < t.media_duration) return error.BadTiming;
    return t;
}
pub fn parse(s: anytype) !Track {
    const moov = try find(s, 0, s.length, "moov") orelse return error.MissingMovie;
    const mvhd = try child(s, moov, "mvhd");
    try minimum(mvhd, 1);
    const ver = try s.int(u8, mvhd.body, .big);
    if (ver > 1) return error.BadVersion;
    try minimum(mvhd, if (ver == 1) 24 else 16);
    const movie_rate = try s.int(u32, mvhd.body + (if (ver == 1) @as(u64, 20) else 12), .big);
    var result: ?Track = null;
    var at = moov.body;
    var budget: usize = 0;
    while (at < moov.end) : (budget += 1) {
        if (budget >= 4096) return error.AtomBudget;
        const a = try atom(s, at, moov.end);
        if (is(a, "trak")) {
            if (try parseTrack(s, a, movie_rate)) |t| {
                if (result != null) return error.MultipleAudio;
                result = t;
            }
        }
        at = a.end;
    }
    var t = result orelse return error.MissingAudio;
    if (try find(s, moov.body, moov.end, "udta")) |udta| {
        if (try find(s, udta.body, udta.end, "meta")) |meta| {
            if (try find(s, meta.body + 4, meta.end, "ilst")) |ilst| {
                if (try find(s, ilst.body, ilst.end, "\xa9nam")) |name| {
                    const data = try child(s, name, "data");
                    if (data.end - data.body >= 8) {
                        t.title_len = @intCast(@min(t.title.len, data.end - data.body - 8));
                        try s.read(data.body + 8, t.title[0..t.title_len]);
                    }
                }
            }
        }
    }
    return t;
}

// Resolve the chunk/timing runs once, then advance in constant work per packet.
// Re-summing a large chunk for every sample would make long-file playback quadratic.
pub const Cursor = struct {
    track: *const Track,
    index: u32,
    current: Packet,
    chunk: u32 = 0,
    chunk_left: u32 = 0,
    chunk_run: u32 = 0,
    time_left: u32 = 0,
    time_run: u32 = 0,
    pub fn init(t: *const Track, s: anytype, index: u32) !Cursor {
        var c = Cursor{ .track = t, .index = index, .current = try t.packet(s, index) };
        var base: u64 = 0;
        for (0..t.stsc_count) |i| {
            const first = try s.int(u32, t.stsc + i * 12, .big);
            const per = try s.int(u32, t.stsc + i * 12 + 4, .big);
            const next_chunk = if (i + 1 < t.stsc_count) try s.int(u32, t.stsc + (i + 1) * 12, .big) else t.chunks + 1;
            const n = @as(u64, next_chunk - first) * per;
            if (index < base + n) {
                c.chunk = first + @as(u32, @intCast((index - base) / per));
                c.chunk_left = per - @as(u32, @intCast((index - base) % per));
                c.chunk_run = @intCast(i);
                break;
            }
            base += n;
        }
        base = 0;
        for (0..t.stts_count) |i| {
            const n = try s.int(u32, t.stts + i * 8, .big);
            if (index < base + n) {
                c.time_left = @intCast(base + n - index);
                c.time_run = @intCast(i);
                break;
            }
            base += n;
        }
        return c;
    }
    pub fn next(c: *Cursor, s: anytype) !?Packet {
        const t = c.track;
        if (c.index >= t.count) return null;
        const result = c.current;
        c.index += 1;
        if (c.index == t.count) return result;
        c.current.offset = std.math.add(u64, c.current.offset, c.current.size) catch return error.BadOffset;
        c.chunk_left -= 1;
        if (c.chunk_left == 0) {
            c.chunk += 1;
            if (c.chunk_run + 1 < t.stsc_count and c.chunk == try s.int(u32, t.stsc + (@as(u64, c.chunk_run) + 1) * 12, .big)) c.chunk_run += 1;
            c.chunk_left = try s.int(u32, t.stsc + @as(u64, c.chunk_run) * 12 + 4, .big);
            c.current.offset = if (t.co64) try s.int(u64, t.stco + (@as(u64, c.chunk) - 1) * 8, .big) else try s.int(u32, t.stco + (@as(u64, c.chunk) - 1) * 4, .big);
        }
        c.current.dts += c.current.duration;
        c.time_left -= 1;
        if (c.time_left == 0) {
            c.time_run += 1;
            c.time_left = try s.int(u32, t.stts + @as(u64, c.time_run) * 8, .big);
            c.current.duration = try s.int(u32, t.stts + @as(u64, c.time_run) * 8 + 4, .big);
        }
        c.current.size = try t.size(s, c.index);
        if (c.current.offset > s.length or c.current.size > s.length - c.current.offset) return error.BadOffset;
        return result;
    }
};

pub const Chapters = struct { entries: [32]Chapter = @splat(.{}), count: usize = 0 };
pub fn readChapters(s: anytype) !Chapters {
    var result = Chapters{};
    const moov = try find(s, 0, s.length, "moov") orelse return error.MissingMovie;
    if (try find(s, moov.body, moov.end, "udta")) |udta| {
        if (try find(s, udta.body, udta.end, "chpl")) |chapters| {
            try minimum(chapters, 9);
            const n = try s.int(u8, chapters.body + 8, .big);
            if (n > result.entries.len) return error.TooManyChapters;
            var pos = chapters.body + 9;
            var previous: u64 = 0;
            for (0..n) |i| {
                if (pos > chapters.end or chapters.end - pos < 9) return error.TruncatedAtom;
                const when = try s.int(u64, pos, .big);
                const len = try s.int(u8, pos + 8, .big);
                pos += 9;
                if (len > chapters.end - pos or (i > 0 and when < previous)) return error.BadChapter;
                var c = Chapter{ .ticks_100ns = when, .len = @min(len, 128) };
                try s.read(pos, c.name[0..c.len]);
                result.entries[i] = c;
                pos += len;
                previous = when;
            }
            result.count = n;
        }
    }
    return result;
}
