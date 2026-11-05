//! Read the first MPEG frame and its Xing/VBRI/LAME timing without decoding or
//! scanning the audio. No duration is invented when the frame count is absent.
const std = @import("std");
const mpeg = @import("mpeg_metadata");
const core = @import("library.zig");

pub fn enrich(source: anytype, result: *core.Metadata) !void {
    var at: u64 = 0;
    if (source.length < 10) return;
    var bytes: [10]u8 = undefined;
    try source.read(0, &bytes);
    if (std.mem.eql(u8, bytes[0..3], "ID3")) {
        var size: u32 = 0;
        for (bytes[6..10]) |byte| {
            if (byte & 128 != 0) return error.InvalidId3;
            size = (size << 7) | byte;
        }
        at = 10 + @as(u64, size) + @as(u64, if (bytes[3] == 4 and bytes[5] & 16 != 0) 10 else 0);
    }
    const end = @min(source.length, at + 65536);
    while (at + 4 <= end) : (at += 1) {
        var header_bytes: [4]u8 = undefined;
        try source.read(at, &header_bytes);
        const header = mpeg.Header.parse(header_bytes) orelse continue;
        const length = header.frameSize() orelse continue;
        if (length < 4 or length > 4096 or length > source.length - at) continue;
        // A sync word also occurs in arbitrary tag or padding bytes. Confirm
        // its predicted boundary before accepting a stream's technical fields.
        if (at + length + 4 > source.length) continue;
        var next_bytes: [4]u8 = undefined;
        try source.read(at + length, &next_bytes);
        const next = mpeg.Header.parse(next_bytes) orelse continue;
        if (next.version != header.version or next.layer != header.layer or next.sampleRate() != header.sampleRate()) continue;
        result.sample_rate = header.sampleRate();
        result.channels = header.channels();
        result.codec = switch (header.layer) {
            .layer1 => "mp1",
            .layer2 => "mp2",
            .layer3 => "mp3",
            else => return,
        };
        var frame: [4096]u8 = undefined;
        try source.read(at, frame[0..length]);
        if (mpeg.vbr.parse(header, frame[0..length])) |info| {
            const frames = info.playableSamples(header) orelse if (info.frames) |count| @as(u64, count) * header.samplesPerFrame() else return;
            result.duration_ms = frames * 1000 / result.sample_rate;
        }
        return;
    }
}
