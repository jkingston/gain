//! One producer contract for all supported files. Decode work and I/O may block
//! in their owning tasks; the sink publishes canonical PCM independently of DMA.
const std = @import("std");
const source_module = @import("media_source.zig");
const packet_media = @import("packet_media.zig");
const flac = @import("flac.zig");
const wav = @import("wav.zig");
const aiff = @import("aiff.zig");
const pcm = @import("pcm.zig");
const Frame = @import("pcm_reservoir.zig").StereoFrame;
pub const Information = @import("media_info.zig").Information;
pub const Workspace = struct {
    packet: packet_media.Workspace,
    cache: []u8,
    compressed: []u8,
    left: []i32,
    right: []i32,
};
pub fn run(reader: anytype, length: u64, comptime Sink: type, sink: *Sink, workspace: Workspace, seek: u64) !Information {
    if (!workspace.packet.valid() or !@import("buffer_regions.zig").disjoint(&.{
        workspace.packet.packet,                       workspace.packet.page,                std.mem.sliceAsBytes(workspace.packet.pcm),
        std.mem.sliceAsBytes(workspace.packet.frames), workspace.packet.pool.storage,        workspace.cache,
        workspace.compressed,                          std.mem.sliceAsBytes(workspace.left), std.mem.sliceAsBytes(workspace.right),
    })) return error.InvalidWorkspace;
    var source = try source_module.Source(@TypeOf(reader.*)).init(reader, length, workspace.cache);
    var magic: [4]u8 = undefined;
    try source.read(0, &magic);
    try reader.seekTo(0);
    if (std.mem.eql(u8, &magic, "fLaC")) return runFlac(reader, Sink, sink, workspace, seek);
    if (std.mem.eql(u8, &magic, "RIFF")) {
        const info = try wav.parse(reader);
        return runPcm(reader, Sink, sink, workspace, try pcm.Plan.fromWave(info), info.data_offset, .wave, seek);
    }
    if (std.mem.eql(u8, &magic, "FORM")) {
        const info = try aiff.parse(reader);
        return runPcm(reader, Sink, sink, workspace, info.plan, info.data_offset, .aiff, seek);
    }
    // The source owns a logical reader position. Reset it after the sequential
    // format probe before returning to cached random-access container reads.
    source = try source_module.Source(@TypeOf(reader.*)).init(reader, length, workspace.cache);
    return packet_media.run(&source, Sink, sink, workspace.packet, seek);
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
            frame.* = .{ .left = left, .right = if (plan.channels == 1) left else plan.sample_format.decode(bytes[index * frame_bytes + plan.sample_format.bytes ..]) };
        }
        try sink.push(frames);
        remaining -= count;
    }
    return info;
}
fn runFlac(reader: anytype, comptime Sink: type, sink: *Sink, workspace: Workspace, seek: u64) !Information {
    var decoder = try flac.Decoder(@TypeOf(reader.*)).init(reader, workspace.compressed, workspace.left, workspace.right);
    if (decoder.info.bits_per_sample < 4 or decoder.info.bits_per_sample > 24) return error.UnsupportedPrecision;
    const known = decoder.info.total_samples != 0;
    var info = Information{ .kind = .flac, .sample_rate = decoder.info.sample_rate, .channels = @intCast(decoder.info.channels), .output_format = if (decoder.info.bits_per_sample <= 16) .signed_16_packed else .signed_24_in_u32, .source_bits = decoder.info.bits_per_sample, .total_frames = if (known) decoder.info.total_samples else null, .start_frame = if (known) @min(seek, decoder.info.total_samples) else seek };
    try sink.configure(info);
    if (workspace.packet.frames.len == 0) return error.InvalidWorkspace;
    const shift: u5 = @intCast(32 - decoder.info.bits_per_sample);
    var position: u64 = 0;
    while (try decoder.next()) |decoded| {
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
