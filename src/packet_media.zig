//! Container timing and packet delivery for the C decoder engines. Caller-owned
//! scratch keeps packet, float and canonical PCM lifetimes explicit.
const std = @import("std");
const mp3 = @import("mp3_decoder.zig");
const mpeg = @import("mpeg_metadata");
const mp4 = @import("mp4.zig");
const ogg = @import("ogg.zig");
const backend = @import("codec_backend.zig");
const Pool = @import("codec_pool.zig").Pool;
const Frame = @import("pcm_reservoir.zig").StereoFrame;
const sample = @import("pcm_sample.zig");
const seek_cache = @import("audio_seek.zig");
const Information = @import("media_info.zig").Information;

pub const maximum_packet_bytes = 65536;
pub const padding_bytes = 64;

pub const Workspace = struct {
    packet: []u8,
    page: []u8,
    pcm: []f32,
    frames: []Frame,
    pool: *Pool,
    seek_index: ?*seek_cache.Index = null,
    seek_source: u64 = 0,

    pub fn valid(self: Workspace) bool {
        return self.packet.len >= maximum_packet_bytes + padding_bytes and self.page.len >= 65025 and self.pcm.len >= 16384 and self.frames.len >= 8192 and @import("buffer_regions.zig").disjoint(&.{
            self.packet,                                                   self.page, std.mem.sliceAsBytes(self.pcm), std.mem.sliceAsBytes(self.frames), self.pool.storage,
            if (self.seek_index) |index| std.mem.asBytes(index) else &.{},
        });
    }
};

const Decoded = struct { information: Information, frames: u64 = 0 };

pub fn run(source: anytype, comptime Sink: type, sink: *Sink, workspace: Workspace, seek: u64) !Information {
    if (!workspace.valid()) return error.InvalidWorkspace;
    var magic: [4]u8 = undefined;
    try source.read(0, &magic);
    var result: Decoded = undefined;
    if (std.mem.eql(u8, &magic, "OggS")) result = try runOgg(source, Sink, sink, workspace, seek) else if (std.mem.eql(u8, magic[0..3], "ID3") or magic[0] == 0xff) result = try runMp3(source, Sink, sink, workspace, seek) else result = try runMp4(source, Sink, sink, workspace, seek);
    return result.information;
}

fn decode(decoder: *backend.Decoder, workspace: Workspace, bytes: usize, granule: ?u64, eos: bool) !usize {
    if (bytes > maximum_packet_bytes) return error.PacketTooLarge;
    @memset(workspace.packet[bytes..][0..padding_bytes], 0);
    return decoder.decode(workspace.packet[0..bytes], workspace.pcm, granule, eos);
}

fn publish(comptime Sink: type, sink: *Sink, result: *Decoded, workspace: Workspace, position: u64, count: usize, begin: u64, end: u64) !void {
    const first = @max(position, begin);
    const last = @min(position + count, end);
    if (last <= first) return;
    const frames: usize = @intCast(last - first);
    if (frames > workspace.frames.len) return error.InvalidWorkspace;
    const start: usize = @intCast(first - position);
    const channels = result.information.channels;
    for (workspace.frames[0..frames], 0..) |*frame, i| {
        const left = sample.fromFloat32(workspace.pcm[(start + i) * channels]);
        frame.* = .{ .left = left, .right = if (channels == 1) left else sample.fromFloat32(workspace.pcm[(start + i) * channels + 1]) };
    }
    try sink.push(workspace.frames[0..frames]);
    result.frames += frames;
}

fn runMp4(source: anytype, comptime Sink: type, sink: *Sink, workspace: Workspace, seek: u64) !Decoded {
    const track = try mp4.parse(source);
    var result = Decoded{ .information = .{
        .kind = if (track.kind == .aac) .aac else .alac,
        .sample_rate = track.rate,
        .channels = @intCast(track.channels),
        .output_format = if (track.kind == .alac and track.bits <= 16) .signed_16_packed else .signed_24_in_u32,
        .source_bits = if (track.kind == .alac) @intCast(track.bits) else 32,
        .total_frames = track.frames,
        .start_frame = @min(seek, track.frames),
    } };
    result.information.title.set(track.title[0..track.title_len]);
    var decoder = try backend.Decoder.init(workspace.pool, if (track.kind == .aac) .aac else .alac, track.config[0..track.config_len], track.rate, track.channels);
    defer decoder.deinit();
    try sink.configure(result.information);
    var index: u32 = if (seek == 0) 0 else try track.seekSample(source, seek);
    if (track.kind == .aac) index -= @min(index, 2);
    var cursor = try mp4.Cursor.init(&track, source, index);
    while (try cursor.next(source)) |packet| {
        if (packet.size > maximum_packet_bytes) return error.PacketTooLarge;
        try source.read(packet.offset, workspace.packet[0..packet.size]);
        const count = try decode(&decoder, workspace, packet.size, null, cursor.index == track.count);
        try publish(Sink, sink, &result, workspace, packet.dts, count, track.lead + result.information.start_frame, track.lead + track.frames);
    }
    if (result.frames != track.frames - result.information.start_frame) return error.PresentationLength;
    return result;
}

fn runOgg(source: anytype, comptime Sink: type, sink: *Sink, workspace: Workspace, seek: u64) !Decoded {
    const Source = @TypeOf(source.*);
    var reader = ogg.Reader(Source){ .source = source, .body = workspace.page };
    var decoder: ?backend.Decoder = null;
    defer if (decoder) |*value| value.deinit();
    var result = Decoded{ .information = .{
        .kind = .vorbis,
        .sample_rate = 0,
        .channels = 1,
        .output_format = .signed_24_in_u32,
        .source_bits = 32,
        .start_frame = seek,
    } };
    var headers: u32 = 0;
    var raw: u64 = 0;
    var lead: u64 = 0;
    var total: u64 = 0;
    var last_granule: u64 = 0;
    const index = if (workspace.seek_index) |value| if (value.bind(workspace.seek_source, source.length, .ogg)) value else null else null;
    var warmup = false;
    var did_seek = false;
    while (try reader.next(workspace.packet[0..maximum_packet_bytes])) |packet| {
        if (packet.bos) {
            if (decoder != null) return error.MissingEos;
            if (total != 0) if (index) |value| value.disable();
            headers = 0;
            raw = 0;
            lead = 0;
            last_granule = 0;
            var rate: u32 = 0;
            var channels: u32 = 0;
            var kind: backend.Kind = undefined;
            if (packet.bytes.len >= 30 and packet.bytes[0] == 1 and std.mem.eql(u8, packet.bytes[1..7], "vorbis")) {
                kind = .vorbis;
                rate = std.mem.readInt(u32, packet.bytes[12..16], .little);
                channels = packet.bytes[11];
            } else if (packet.bytes.len >= 19 and std.mem.eql(u8, packet.bytes[0..8], "OpusHead")) {
                kind = .opus;
                rate = 48000;
                channels = packet.bytes[9];
                lead = std.mem.readInt(u16, packet.bytes[10..12], .little);
                if (packet.bytes[8] > 15 or packet.bytes[18] != 0) return error.UnsupportedOpusMapping;
            } else return error.UnsupportedCodec;
            if (channels < 1 or channels > 2 or rate < 8000 or rate > 192000) return error.UnsupportedFormat;
            if (result.information.sample_rate != 0 and (rate != result.information.sample_rate or channels != result.information.channels)) return error.ChainedFormatChange;
            result.information.kind = if (kind == .vorbis) .vorbis else .opus;
            result.information.sample_rate = rate;
            result.information.channels = @intCast(channels);
            decoder = try backend.Decoder.init(workspace.pool, kind, packet.bytes, rate, channels);
        }
        const current = if (decoder) |*value| value else return error.MissingBos;
        const is_vorbis = result.information.kind == .vorbis;
        const required_headers: u32 = if (is_vorbis) 3 else 2;
        if (headers < required_headers) {
            if (headers == 1) {
                if (!is_vorbis and (packet.bytes.len < 8 or !std.mem.eql(u8, packet.bytes[0..8], "OpusTags"))) return error.InvalidHeader;
                result.information.title.length = try ogg.title(packet.bytes, if (is_vorbis) 7 else 8, &result.information.title.bytes);
            }
            if (is_vorbis) try current.header(packet.bytes, packet.bos);
            headers += 1;
            if (headers == required_headers) {
                if (total == 0) if (try ogg.finalGranule(source, reader.serial)) |last| {
                    if (last < lead) return error.BadGranule;
                    result.information.total_frames = last - lead;
                    result.information.start_frame = @min(seek, last - lead);
                };
                try sink.configure(result.information);
                if (!did_seek and seek != 0 and total == 0) {
                    did_seek = true;
                    const target = std.math.add(u64, seek, lead) catch std.math.maxInt(u64);
                    const before = target -| 3840;
                    var point = if (index) |value| value.before(before) else null;
                    if (before - (if (point) |value| value.sample else @as(u64, 0)) > @as(u64, result.information.sample_rate) * 2) {
                        if (try findOggStart(source, workspace, reader.serial, before)) |cold| point = cold;
                        if (point == null) {
                            // Probing reuses the page scratch. A fallback must
                            // restore the header page's unconsumed audio laces.
                            var body_bytes: usize = 0;
                            for (reader.laces[0..reader.segments]) |n| body_bytes += n;
                            try source.read(reader.page_offset + 27 + reader.segments, workspace.page[0..body_bytes]);
                        }
                    }
                    if (point) |start| {
                        reader.offset = start.offset;
                        reader.sequence = start.auxiliary -% 1;
                        reader.segment = 0;
                        reader.segments = 0;
                        warmup = true;
                    }
                }
            }
            continue;
        }
        const count = try decode(current, workspace, packet.bytes.len, packet.granule, packet.eos);
        if (warmup) {
            if (packet.granule) |granule| {
                raw = granule;
                last_granule = granule;
                warmup = false;
            }
            continue;
        }
        if (packet.granule) |granule| {
            if (index) |value| if (total == 0 and reader.flags & 7 == 0 and granule != 0) value.observe(.{ .sample = granule, .offset = @intCast(packet.page_offset), .auxiliary = reader.sequence }, result.information.sample_rate);
            if (granule < last_granule or granule < lead) return error.BadGranule;
            last_granule = granule;
        }
        const end = if (packet.eos) packet.granule orelse return error.MissingGranule else std.math.maxInt(u64);
        const skip = if (seek > total) seek - total else 0;
        try publish(Sink, sink, &result, workspace, raw, count, lead + skip, end);
        raw += count;
        if (packet.eos) {
            const granule = packet.granule orelse return error.MissingGranule;
            if (raw < granule) return error.MissingSamples;
            total += granule - lead;
            current.deinit();
            decoder = null;
        }
    }
    if (decoder != null) return error.MissingEos;
    if (result.frames != total - @min(total, seek)) return error.PresentationLength;
    result.information.total_frames = total;
    result.information.start_frame = @min(seek, total);
    return result;
}

comptime {
    if (@import("builtin").os.tag == .freestanding) {
        _ = @import("codec_math.zig");
        _ = @import("codec_runtime.zig");
    }
}

fn synchsafe(bytes: *const [4]u8) !u32 {
    var result: u32 = 0;
    for (bytes) |byte| {
        if (byte & 0x80 != 0) return error.InvalidTag;
        result = (result << 7) | byte;
    }
    return result;
}

fn mp3Start(source: anytype) !u64 {
    if (source.length < 10) return 0;
    var header: [10]u8 = undefined;
    try source.read(0, &header);
    if (!std.mem.eql(u8, header[0..3], "ID3")) return 0;
    if (header[3] < 2 or header[3] > 4) return error.UnsupportedTag;
    const length = @as(u64, try synchsafe(header[6..10])) + 10 + @as(u64, if (header[3] == 4 and header[5] & 0x10 != 0) 10 else 0);
    if (length > source.length) return error.Truncated;
    return length;
}

fn runMp3(source: anytype, comptime Sink: type, sink: *Sink, workspace: Workspace, seek: u64) !Decoded {
    var decoder = mp3.Decoder.init();
    const index = if (workspace.seek_index) |value| if (value.bind(workspace.seek_source, source.length, .mpeg)) value else null else null;
    var seek_applied = false;
    var indexed_start = false;
    var offset = try mp3Start(source);
    var end = source.length;
    if (end >= 128) {
        var trailer: [3]u8 = undefined;
        try source.read(end - 128, &trailer);
        if (std.mem.eql(u8, &trailer, "TAG")) end -= 128;
    }
    if (offset > end) return error.InvalidTag;
    var raw: u64 = 0;
    var lead: u64 = 0;
    var initialized = false;
    var result = Decoded{ .information = .{
        .kind = .mp3,
        .sample_rate = 0,
        .channels = 1,
        .output_format = .signed_24_in_u32,
        .source_bits = 32,
        .start_frame = seek,
    } };
    var head: usize = 0;
    var tail: usize = 0;
    const window_bytes = 16 * 1024;
    var input_eof = false;
    while (true) {
        if (tail - head < 4096 and !input_eof) {
            const remaining = tail - head;
            std.mem.copyForwards(u8, workspace.packet[0..remaining], workspace.packet[head..tail]);
            head = 0;
            tail = remaining;
            const count: usize = @intCast(@min(window_bytes - tail, end - offset));
            try source.read(offset, workspace.packet[tail..][0..count]);
            tail += count;
            offset += count;
            input_eof = offset == end;
            @memset(workspace.packet[tail..][0..padding_bytes], 0);
        }
        if (head == tail) break;
        if (!initialized and tail - head >= 4) {
            if (mpeg.Header.parse(workspace.packet[head..][0..4].*)) |header| {
                if (header.frameSize()) |bytes| if (bytes <= tail - head) {
                    if (mpeg.vbr.parse(header, workspace.packet[head..][0..bytes])) |info| {
                        lead = info.leadIn() orelse 0;
                        result.information.total_frames = info.playableSamples(header) orelse if (info.frames) |frames| @as(u64, frames) * header.samplesPerFrame() else null;
                        head += bytes;
                        continue;
                    }
                };
            }
        }
        if (!seek_applied and tail - head >= 4) {
            if (mpeg.Header.parse(workspace.packet[head..][0..4].*)) |header| {
                seek_applied = true;
                const requested = if (result.information.total_frames) |frames| @min(seek, frames) else seek;
                if (requested != 0) if (try findMpegStart(source, index, offset - (tail - head), end, requested +| lead, header)) |point| {
                    if (point.sample != 0) {
                        offset = point.offset;
                        raw = point.sample;
                        head = 0;
                        tail = 0;
                        input_eof = false;
                        indexed_start = true;
                        continue;
                    }
                };
            }
        }
        const step = try decoder.next(workspace.packet[head..tail], @ptrCast(workspace.pcm.ptr));
        switch (step) {
            .need_more => {
                if (input_eof) break;
                if (tail - head == window_bytes) return error.PacketTooLarge;
                // A free-format frame can need more than the ordinary refill
                // threshold. Compact once and extend the same decoder window.
                const remaining = tail - head;
                std.mem.copyForwards(u8, workspace.packet[0..remaining], workspace.packet[head..tail]);
                head = 0;
                tail = remaining;
                const count: usize = @intCast(@min(window_bytes - tail, end - offset));
                try source.read(offset, workspace.packet[tail..][0..count]);
                tail += count;
                offset += count;
                input_eof = offset == end;
                @memset(workspace.packet[tail..][0..padding_bytes], 0);
            },
            .skipped => |count| {
                if (count == 0) return error.InvalidDecoderResult;
                if (indexed_start) {
                    var skipped: usize = 0;
                    while (skipped + 4 <= count) {
                        const header = mpeg.Header.parse(workspace.packet[head + skipped ..][0..4].*) orelse return error.InvalidSeekAnchor;
                        const bytes = header.frameSize() orelse return error.InvalidSeekAnchor;
                        if (bytes > count - skipped) return error.InvalidSeekAnchor;
                        raw += header.samplesPerFrame();
                        skipped += bytes;
                    }
                    if (skipped != count) return error.InvalidSeekAnchor;
                }
                head += count;
            },
            .frame => |frame| {
                if (!initialized) {
                    result.information.sample_rate = frame.rate;
                    result.information.channels = @intCast(frame.channels);
                    if (result.information.total_frames) |frames| result.information.start_frame = @min(seek, frames);
                    try sink.configure(result.information);
                    initialized = true;
                } else if (frame.rate != result.information.sample_rate or frame.channels != result.information.channels) return error.FormatChanged;
                if (index) |value| if (tail - head >= 4) {
                    if (mpeg.Header.parse(workspace.packet[head..][0..4].*)) |header| {
                        if (header.frameSize()) |bytes| if (bytes == frame.consumed) value.observe(.{ .sample = raw, .offset = @intCast(offset - (tail - head)) }, frame.rate);
                    }
                };
                const limit = if (result.information.total_frames) |frames| lead + frames else std.math.maxInt(u64);
                try publish(Sink, sink, &result, workspace, raw, frame.frames, lead + result.information.start_frame, limit);
                raw += frame.frames;
                head += frame.consumed;
            },
        }
    }
    if (!initialized) return error.UnsupportedFormat;
    const total = result.information.total_frames orelse raw;
    if (result.frames != total - @min(total, seek)) return error.PresentationLength;
    result.information.total_frames = total;
    result.information.start_frame = @min(total, seek);
    return result;
}

/// MPEG's variable bitrate TOC is approximate. Walking sized frame headers
/// establishes exact sample positions without decoding discarded PCM. A cached
/// checkpoint removes that walk for subsequent seeks. Free-format and damaged
/// synchronization retain the existing sequential decoder path.
fn findMpegStart(source: anytype, index: ?*seek_cache.Index, data: u64, end: u64, target: u64, format: mpeg.Header) !?seek_cache.Point {
    const wanted = target -| format.sampleRate(); // reservoir plus synthesis preroll
    var point = if (index) |value| value.before(wanted) orelse seek_cache.Point{ .sample = 0, .offset = @intCast(data) } else seek_cache.Point{ .sample = 0, .offset = @intCast(data) };
    var offset: u64 = point.offset;
    var sample_number = point.sample;
    while (offset + 4 <= end and sample_number <= wanted) {
        var bytes: [4]u8 = undefined;
        try source.read(offset, &bytes);
        const header = mpeg.Header.parse(bytes) orelse return null;
        if (header.version != format.version or header.layer != format.layer or header.sampleRate() != format.sampleRate() or (header.mode == .mono) != (format.mode == .mono)) return null;
        const length = header.frameSize() orelse return null;
        if (length > end - offset) return null;
        point = .{ .sample = sample_number, .offset = @intCast(offset) };
        if (index) |value| value.observe(point, header.sampleRate());
        const next = sample_number + header.samplesPerFrame();
        if (next > wanted) break;
        sample_number = next;
        offset += length;
    }
    return point;
}

const OggPage = struct { point: seek_cache.Point, end: u64, serial: u32, flags: u8 };

/// Searches one bounded window, validating complete page CRCs before using a
/// granule. Continued pages may guide bisection but cannot initialize a decoder.
fn findOggPage(source: anytype, workspace: Workspace, start: u64, limit: u64, serial: u32) !?OggPage {
    if (start >= limit) return null;
    const count: usize = @intCast(@min(maximum_packet_bytes, limit - start));
    try source.read(start, workspace.packet[0..count]);
    var i: usize = 0;
    while (i + 27 <= count) : (i += 1) {
        if (!std.mem.eql(u8, workspace.packet[i..][0..4], "OggS")) continue;
        var head: [27]u8 = workspace.packet[i..][0..27].*;
        if (head[4] != 0 or head[5] & ~@as(u8, 7) != 0 or head[26] == 0) continue;
        if (std.mem.readInt(u32, head[14..18], .little) != serial) continue;
        const offset = start + i;
        const segments = head[26];
        var laces: [255]u8 = undefined;
        if (@as(u64, 27) + segments > source.length - offset) continue;
        try source.read(offset + 27, laces[0..segments]);
        var length: usize = 0;
        for (laces[0..segments]) |n| length += n;
        if (length > source.length - offset - 27 - segments) continue;
        try source.read(offset + 27 + segments, workspace.page[0..length]);
        const expected = std.mem.readInt(u32, head[22..26], .little);
        @memset(head[22..26], 0);
        if (ogg.crc(ogg.crc(ogg.crc(0, &head), laces[0..segments]), workspace.page[0..length]) != expected) continue;
        const granule = std.mem.readInt(i64, head[6..14], .little);
        if (granule < 0) continue;
        return .{ .point = .{ .sample = @intCast(granule), .offset = @intCast(offset), .auxiliary = std.mem.readInt(u32, head[18..22], .little) }, .end = offset + 27 + segments + length, .serial = serial, .flags = head[5] };
    }
    return null;
}

/// RFC 7845 section 4.6 specifies granule bisection and 3840-sample Opus preroll.
/// Cold Ogg seeks use the container's granules and weighted bisection instead
/// of constructing a full-file index. Chained files whose final logical stream
/// differs use the sequential path, preserving their cumulative presentation.
fn findOggStart(source: anytype, workspace: Workspace, serial: u32, target: u64) !?seek_cache.Point {
    if (target == 0) return null;
    var tail = source.length -| maximum_packet_bytes;
    var terminal: ?OggPage = null;
    while (try findOggPage(source, workspace, tail, source.length, serial)) |page| {
        if (page.flags & 4 != 0 and page.end == source.length) {
            terminal = page;
            break;
        }
        if (page.end <= tail) break;
        tail = page.end;
    }
    const last = terminal orelse return null;
    if (target >= last.point.sample or target == 0) return null;
    var low: u64 = 0;
    var low_sample: u64 = 0;
    var high: u64 = last.point.offset;
    var high_sample = last.point.sample;
    var best: ?seek_cache.Point = null;
    for (0..32) |_| {
        if (low >= high or low_sample >= target or high_sample <= low_sample) break;
        const ratio = if (std.math.mul(u64, target - low_sample, 1_000_000)) |numerator| @min(999999, numerator / (high_sample - low_sample)) else |_| 500000;
        const probe = low + (high - low) * ratio / 1_000_000;
        const page = try findOggPage(source, workspace, probe, source.length, serial) orelse {
            high = probe;
            continue;
        };
        if (page.point.sample > target) {
            high = page.point.offset;
            high_sample = page.point.sample;
        } else {
            if (page.flags & 7 == 0 and page.point.sample != 0) best = page.point;
            low = page.end;
            low_sample = page.point.sample;
        }
    }
    return best;
}
