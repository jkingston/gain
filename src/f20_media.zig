const audio = @import("f20_audio.zig");
const flac_pcm = @import("flac_pcm.zig");
const pcm = @import("pcm.zig");
const playback = @import("playback.zig");
const wav = @import("wav.zig");

pub const Config = struct {
    descriptor_count: u8,
    buffer_count: u8,
    chunk_bytes: u24,
    attenuation: u8,
};

pub const Result = struct {
    sample_rate: u32,
    output_format: pcm.OutputFormat,
    frames: u64,
    chunks: u32,
    underruns: u32,
    minimum_fifo_level: u7,
};

pub const FlacConfig = struct {
    descriptor_count: u8,
    buffer_count: u8,
    attenuation: u8,
};

pub const FlacWorkspace = struct {
    compressed: []u8,
    left: []i32,
    right: []i32,
};

pub const Error = error{
    AudioDmaFault,
    AudioUnderrun,
    EmptyChunk,
    UnsupportedSampleRate,
};

/// Streams one stereo PCM WAV from its current reader position through the
/// native F20 audio path. The caller supplies uncached descriptor and buffer
/// memory; this function allocates nothing and always powers audio down after a
/// successful start. A later call performs a complete hardware reinitialization.
pub fn playWave(reader: anytype, resources: audio.Engine.Resources, config: Config) !Result {
    const Reader = @TypeOf(reader.*);
    const info = try wav.parse(reader);
    var stream = try pcm.Stream(Reader).init(reader, info);
    const rate = audio.sampleRate(stream.plan.sample_rate) orelse
        return error.UnsupportedSampleRate;
    const chunk_count = try stream.plan.chunkCount(config.chunk_bytes);

    var state = try playback.State.init(.{
        .buffer_count = config.buffer_count,
        .descriptor_count = config.descriptor_count,
        .total_chunks = chunk_count,
    });
    var engine = try audio.Engine.init(resources, .{
        .descriptor_count = config.descriptor_count,
        .buffer_count = config.buffer_count,
        .chunk_bytes = config.chunk_bytes,
        .sample_format = audio.sampleFormat(stream.plan.output_format),
    });

    for (resources.buffers[0..config.buffer_count]) |buffer| {
        const output: [*]u8 = @ptrFromInt(buffer.address);
        const fill = try stream.fill(output[0..config.chunk_bytes]);
        if (fill.bytes == 0) return error.EmptyChunk;
    }

    try engine.initialize(rate, config.attenuation);
    try engine.start();
    defer engine.stop();

    while (!state.finished) {
        const event = try engine.poll();
        if (event.dma_fault) return error.AudioDmaFault;
        if (event.underrun) return error.AudioUnderrun;
        const observed = event.descriptor orelse continue;
        const transition = try state.advance(observed);
        if (transition.refill) |refill| {
            const output: [*]u8 = @ptrFromInt(resources.buffers[refill.slot].address);
            const fill = try stream.fill(output[0..config.chunk_bytes]);
            if (fill.bytes == 0) return error.EmptyChunk;
            try state.completeRefill(refill);
        }
    }

    return .{
        .sample_rate = stream.plan.sample_rate,
        .output_format = stream.plan.output_format,
        .frames = stream.plan.frames,
        .chunks = state.chunks_completed,
        .underruns = engine.underrun_count,
        .minimum_fifo_level = engine.minimum_fifo_level,
    };
}

/// Streams one stereo or mono FLAC file through the native F20 audio path.
/// Compressed input, decoded channels, DMA descriptors and output buffers are
/// all caller owned; the maximum FLAC block size determines each DMA chunk.
/// SD-backed callers should wrap their FAT32 reader in `storage.BufferedReader`
/// so DMA uses uncached bounce memory while decoding uses cached workspace.
pub fn playFlac(
    reader: anytype,
    resources: audio.Engine.Resources,
    workspace: FlacWorkspace,
    config: FlacConfig,
) !Result {
    const Reader = @TypeOf(reader.*);
    var stream = try flac_pcm.Stream(Reader).init(
        reader,
        workspace.compressed,
        workspace.left,
        workspace.right,
    );
    const rate = audio.sampleRate(stream.plan.sample_rate) orelse
        return error.UnsupportedSampleRate;
    const chunk_count = try stream.plan.chunkCount();
    const chunk_bytes = stream.plan.chunkBytes();

    var state = try playback.State.init(.{
        .buffer_count = config.buffer_count,
        .descriptor_count = config.descriptor_count,
        .total_chunks = chunk_count,
    });
    var engine = try audio.Engine.init(resources, .{
        .descriptor_count = config.descriptor_count,
        .buffer_count = config.buffer_count,
        .chunk_bytes = chunk_bytes,
        .sample_format = audio.sampleFormat(stream.plan.output_format),
    });

    for (resources.buffers[0..config.buffer_count]) |buffer| {
        const output: [*]u8 = @ptrFromInt(buffer.address);
        const fill = try stream.fill(output[0..chunk_bytes]);
        if (fill.bytes == 0) return error.EmptyChunk;
    }

    try engine.initialize(rate, config.attenuation);
    try engine.start();
    defer engine.stop();

    while (!state.finished) {
        const event = try engine.poll();
        if (event.dma_fault) return error.AudioDmaFault;
        if (event.underrun) return error.AudioUnderrun;
        const observed = event.descriptor orelse continue;
        const transition = try state.advance(observed);
        if (transition.refill) |refill| {
            const output: [*]u8 = @ptrFromInt(resources.buffers[refill.slot].address);
            const fill = try stream.fill(output[0..chunk_bytes]);
            if (fill.bytes == 0) return error.EmptyChunk;
            try state.completeRefill(refill);
        }
    }

    return .{
        .sample_rate = stream.plan.sample_rate,
        .output_format = stream.plan.output_format,
        .frames = stream.plan.frames,
        .chunks = state.chunks_completed,
        .underruns = engine.underrun_count,
        .minimum_fifo_level = engine.minimum_fifo_level,
    };
}

test "F20 media player compiles its production API" {
    @import("std").testing.refAllDecls(@This());
}
