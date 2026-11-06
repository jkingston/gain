//! One producer contract for all supported files. Decode work and I/O may block
//! in their owning tasks; the sink publishes canonical PCM independently of DMA.
const std = @import("std");
const source_module = @import("media_source.zig");
const packet_media = @import("packet_media.zig");
const flac = @import("flac.zig");
const wav = @import("wav.zig");
const aiff = @import("aiff.zig");
const pcm = @import("pcm.zig");
const seek_cache = @import("audio_seek.zig");
pub const SeekIndex = seek_cache.Index;
pub const SeekCache = seek_cache.Cache;
const Frame = @import("pcm_reservoir.zig").StereoFrame;
pub const Information = @import("media_info.zig").Information;

pub const Workspace = struct {
    packet: packet_media.Workspace,
    cache: []u8,
    compressed: []u8,
    left: []i32,
    right: []i32,
    seek_index: ?*SeekIndex = null,
    /// Stable track identity mixed with the file's content/change stamp. Zero
    /// disables persistent offsets; callers must not use only a path or size.
    seek_source: u64 = 0,
};

pub fn run(reader: anytype, length: u64, comptime Sink: type, sink: *Sink, workspace: Workspace, seek: u64) !Information {
    if (!workspace.packet.valid() or !@import("buffer_regions.zig").disjoint(&.{
        workspace.packet.packet,                                            workspace.packet.page,                std.mem.sliceAsBytes(workspace.packet.pcm),
        std.mem.sliceAsBytes(workspace.packet.frames),                      workspace.packet.pool.storage,        workspace.cache,
        workspace.compressed,                                               std.mem.sliceAsBytes(workspace.left), std.mem.sliceAsBytes(workspace.right),
        if (workspace.seek_index) |index| std.mem.asBytes(index) else &.{},
    })) return error.InvalidWorkspace;
    if (workspace.cache.len < 512) return error.InvalidCache;
    if (length > std.math.maxInt(u32)) return error.FileTooLarge;
    if (length < 4) return error.Truncated;
    var magic: [4]u8 = undefined;
    try reader.seekTo(0);
    try exact(reader, &magic);
    try reader.seekTo(0);
    if (std.mem.eql(u8, &magic, "fLaC")) return runFlac(reader, length, Sink, sink, workspace, seek);
    if (std.mem.eql(u8, &magic, "RIFF")) {
        const info = try wav.parse(reader);
        return runPcm(reader, Sink, sink, workspace, try pcm.Plan.fromWave(info), info.data_offset, .wave, seek);
    }
    if (std.mem.eql(u8, &magic, "FORM")) {
        const info = try aiff.parse(reader);
        return runPcm(reader, Sink, sink, workspace, info.plan, info.data_offset, .aiff, seek);
    }
    // The four-byte probe needs no read-ahead. Construct the packet cache once,
    // after dispatch, instead of transferring its first working set twice.
    var source = try source_module.Source(@TypeOf(reader.*)).init(reader, length, workspace.cache);
    var packets = workspace.packet;
    packets.seek_index = workspace.seek_index;
    packets.seek_source = workspace.seek_source;
    return packet_media.run(&source, Sink, sink, packets, seek);
}

fn exact(reader: anytype, output: []u8) !void {
    var done: usize = 0;
    while (done < output.len) {
        const count = try reader.read(output[done..]);
        if (count == 0) return error.Truncated;
        if (count > output.len - done) return error.InvalidReadCount;
        done += count;
    }
}

fn runPcm(reader: anytype, comptime Sink: type, sink: *Sink, workspace: Workspace, plan: pcm.Plan, data_offset: u32, kind: @import("media_info.zig").Kind, seek: u64) !Information {
    const start = @min(seek, plan.frames);
    const offset = @as(u64, data_offset) + start * plan.sourceBytesPerFrame();
    if (offset > std.math.maxInt(u32)) return error.SeekBounds;
    try reader.seekTo(@intCast(offset));
    const info = Information{ .kind = kind, .sample_rate = plan.sample_rate, .channels = plan.channels, .output_format = plan.output_format, .source_bits = plan.sample_format.valid_bits, .total_frames = plan.frames, .start_frame = start };
    try sink.configure(info);
    const frame_bytes = plan.sourceBytesPerFrame();
    const capacity = @min(workspace.packet.packet.len / frame_bytes, workspace.packet.frames.len);
    if (capacity == 0) return error.InvalidWorkspace;
    var remaining: u64 = plan.frames - start;
    while (remaining != 0) {
        const count: usize = @intCast(@min(capacity, remaining));
        const bytes = workspace.packet.packet[0 .. count * frame_bytes];
        try exact(reader, bytes);
        const frames = workspace.packet.frames[0..count];
        for (frames, 0..) |*frame, index| {
            const left = plan.sample_format.decode(bytes[index * frame_bytes ..]);
            frame.* = .{
                .left = left,
                .right = if (plan.channels == 1) left else plan.sample_format.decode(bytes[index * frame_bytes + plan.sample_format.bytes ..]),
            };
        }
        try sink.push(frames);
        remaining -= count;
    }
    return info;
}

fn runFlac(reader: anytype, length: u64, comptime Sink: type, sink: *Sink, workspace: Workspace, seek: u64) !Information {
    var decoder = try flac.Decoder(@TypeOf(reader.*)).initSeeking(reader, workspace.compressed, workspace.left, workspace.right, seek, length);
    const index = if (workspace.seek_index) |value| if (value.bind(workspace.seek_source, length, .flac)) value else null else null;
    if (decoder.info.bits_per_sample < 4 or decoder.info.bits_per_sample > 24) return error.UnsupportedPrecision;
    const known = decoder.info.total_samples != 0;
    var info = Information{ .kind = .flac, .sample_rate = decoder.info.sample_rate, .channels = @intCast(decoder.info.channels), .output_format = if (decoder.info.bits_per_sample <= 16) .signed_16_packed else .signed_24_in_u32, .source_bits = decoder.info.bits_per_sample, .total_frames = if (known) decoder.info.total_samples else null, .start_frame = if (known) @min(seek, decoder.info.total_samples) else seek };
    try sink.configure(info);
    if (workspace.packet.frames.len == 0) return error.InvalidWorkspace;
    const shift: u5 = @intCast(32 - decoder.info.bits_per_sample);
    var position: u64 = 0;
    if (info.start_frame != 0) {
        const point = try findFlacStart(reader, length, &decoder, workspace, info.start_frame, index);
        try decoder.seekToPoint(point);
        position = point.sample;
    }
    while (true) {
        const frame_offset = decoder.frame_offset;
        const decoded = try decoder.next() orelse break;
        if (index) |value| value.observe(.{ .sample = position, .offset = frame_offset }, info.sample_rate);
        if (decoded.sample_rate != info.sample_rate or decoded.channels != info.channels or decoded.bits_per_sample != decoder.info.bits_per_sample) return error.FormatChanged;
        var offset: usize = @intCast(@min(decoded.block_size, info.start_frame - @min(info.start_frame, position)));
        while (offset < decoded.block_size) {
            const count = @min(workspace.packet.frames.len, decoded.block_size - offset);
            for (workspace.packet.frames[0..count], 0..) |*frame, i| {
                const left = decoder.left[offset + i] << shift;
                frame.* = .{ .left = left, .right = if (info.channels == 1) left else decoder.right[offset + i] << shift };
            }
            try sink.push(workspace.packet.frames[0..count]);
            offset += count;
        }
        position += decoded.block_size;
    }
    if (known and position != decoder.info.total_samples) return error.PresentationLength;
    info.total_frames = position;
    info.start_frame = @min(seek, position);
    return info;
}

const FlacCandidate = struct { point: flac.SeekPoint, bytes: u32, samples: u16 };

/// A frame CRC, its explicit sample number and stream format must all agree.
/// A coincidental sync word in compressed data is never a seek checkpoint.
fn flacCandidate(source: anytype, start: u64, limit: u64, info: flac.StreamInfo, workspace: Workspace, scan: bool) !?FlacCandidate {
    if (start >= limit) return null;
    const maximum: usize = if (info.maximum_frame_size != 0) @max(32, info.maximum_frame_size) else workspace.compressed.len;
    const count: usize = @intCast(@min(workspace.compressed.len, limit - start, if (scan) workspace.compressed.len else maximum));
    try source.read(start, workspace.compressed[0..count]);
    var i: usize = 0;
    while (i + 8 <= count) : (i += 1) {
        if (!scan and i != 0) break;
        if (workspace.compressed[i] != 0xff or workspace.compressed[i + 1] & 0xfe != 0xf8) continue;
        const frame = flac.decodeFrame(workspace.compressed[i..count], info, workspace.left, workspace.right) catch continue;
        if (frame.sample_rate != info.sample_rate or frame.channels != info.channels or frame.bits_per_sample != info.bits_per_sample or (info.total_samples != 0 and frame.first_sample >= info.total_samples)) continue;
        return .{ .point = .{ .sample = frame.first_sample, .offset = @intCast(start + i) }, .bytes = @intCast(frame.bytes_consumed), .samples = frame.block_size };
    }
    return null;
}

fn findFlacStart(reader: anytype, length: u64, decoder: anytype, workspace: Workspace, target: u64, index: ?*SeekIndex) !flac.SeekPoint {
    var source = try source_module.Source(@TypeOf(reader.*)).init(reader, length, workspace.cache);
    var best = flac.SeekPoint{ .sample = 0, .offset = @intCast(decoder.info.first_frame_offset) };
    if (decoder.seek_point) |relative| {
        const offset = @as(u64, relative.offset) + decoder.info.first_frame_offset;
        if (offset < length) if (try flacCandidate(&source, offset, length, decoder.info, workspace, false)) |candidate| {
            if (candidate.point.sample == relative.sample and relative.sample <= target) best = candidate.point;
        };
    }
    if (index) |value| if (value.before(target)) |point| {
        if (point.sample > best.sample) if (try flacCandidate(&source, point.offset, length, decoder.info, workspace, false)) |candidate| {
            if (candidate.point.sample == point.sample) best = candidate.point;
        };
    };
    // Tables and learned anchors are enough for nearby seeks. For a cold seek,
    // bounded interpolation uses independent, CRC-checked FLAC frames. It does
    // not decode the entire file or add an indexing pass to startup.
    if (decoder.info.total_samples != 0 and target > best.sample + @as(u64, decoder.info.sample_rate) * 2) {
        var low: u64 = best.offset;
        var low_sample = best.sample;
        var high = length;
        var high_sample: u64 = decoder.info.total_samples;
        for (0..32) |_| {
            if (low >= high or low_sample >= target or high_sample <= low_sample) break;
            const ratio = @min(999999, (target - low_sample) * 1_000_000 / (high_sample - low_sample));
            const probe = low + (high - low) * ratio / 1_000_000;
            const candidate = try flacCandidate(&source, probe, high, decoder.info, workspace, true) orelse {
                high = probe;
                continue;
            };
            if (candidate.point.sample > target) {
                high = candidate.point.offset;
                high_sample = candidate.point.sample;
            } else {
                best = candidate.point;
                if (target < candidate.point.sample + candidate.samples) break;
                low = @as(u64, candidate.point.offset) + candidate.bytes;
                low_sample = candidate.point.sample + candidate.samples;
            }
        }
    }
    return best;
}
