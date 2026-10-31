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
const Information = @import("media_info.zig").Information;
pub const maximum_packet_bytes = 65536;
pub const padding_bytes = 64;
pub const Workspace = struct {
    packet: []u8,
    page: []u8,
    pcm: []f32,
    frames: []Frame,
    pool: *Pool,
    pub fn valid(self: Workspace) bool {
        return self.packet.len >= maximum_packet_bytes + padding_bytes and self.page.len >= 65025 and self.pcm.len >= 16384 and self.frames.len >= 8192 and @import("buffer_regions.zig").disjoint(&.{
            self.packet, self.page, std.mem.sliceAsBytes(self.pcm), std.mem.sliceAsBytes(self.frames), self.pool.storage,
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
    var result = Decoded{ .information = .{ .kind = if (track.kind == .aac) .aac else .alac, .sample_rate = track.rate, .channels = @intCast(track.channels), .output_format = if (track.kind == .alac and track.bits <= 16) .signed_16_packed else .signed_24_in_u32, .source_bits = if (track.kind == .alac) @intCast(track.bits) else 32, .total_frames = track.frames, .start_frame = @min(seek, track.frames) } };
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
    var result = Decoded{ .information = .{ .kind = .vorbis, .sample_rate = 0, .channels = 1, .output_format = .signed_24_in_u32, .source_bits = 32, .start_frame = seek } };
    var headers: u32 = 0;
    var raw: u64 = 0;
    var lead: u64 = 0;
    var total: u64 = 0;
    var last_granule: u64 = 0;
    while (try reader.next(workspace.packet[0..maximum_packet_bytes])) |packet| {
        if (packet.bos) {
            if (decoder != null) return error.MissingEos;
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
            if (headers == required_headers) try sink.configure(result.information);
            continue;
        }
        const count = try decode(current, workspace, packet.bytes.len, packet.granule, packet.eos);
        if (packet.granule) |granule| {
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
    var result = Decoded{ .information = .{ .kind = .mp3, .sample_rate = 0, .channels = 1, .output_format = .signed_24_in_u32, .source_bits = 32, .start_frame = seek } };
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
