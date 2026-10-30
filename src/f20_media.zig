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
    stopped: bool = false,
    exit: PlaybackExit = .completed,
    attenuation: u8 = 0,
};

pub const PlaybackExit = enum { completed, stopped, next, previous };

pub const PlaybackCommand = union(enum) {
    none,
    stop,
    next,
    previous,
    set_attenuation: u8,
};

pub const PlaybackControl = struct {
    context: *anyopaque,
    poll: *const fn (context: *anyopaque, status: PlaybackStatus) PlaybackCommand,

    fn command(self: PlaybackControl, status: PlaybackStatus) PlaybackCommand {
        return self.poll(self.context, status);
    }
};

pub const PlaybackStatus = struct {
    phase: PlaybackPhase,
    sample_rate: u32,
    output_format: pcm.OutputFormat,
    total_frames: u64,
    played_frames: u64,
};

pub const PlaybackPhase = enum { preparing, playing };

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

const playback_dac_attenuation: u8 = 16;
const software_gains_q24 = [_]u32{
    16_777_216, 13_326_616, 10_585_708, 8_408_526, 6_679_130, 5_305_422,
    4_214_246,  3_347_495,  2_659_010,  2_112_126, 1_677_722, 1_332_662,
    1_058_571,  840_853,    667_913,    530_542,   421_425,   334_749,
    265_901,    211_213,    167_772,    133_266,   105_857,   84_085,
    66_791,     53_054,     42_142,     33_475,    26_590,
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
    try prefetchReader(reader);

    try engine.initialize(rate, playback_dac_attenuation);
    try engine.start();
    defer engine.stop();

    while (!state.finished) {
        const event = try engine.poll();
        if (event.dma_fault) return error.AudioDmaFault;
        if (event.underrun) return error.AudioUnderrun;
        const observed = event.descriptor orelse continue;
        try catchUpPlayback(
            &state,
            observed,
            reader,
            &stream,
            resources,
            config.chunk_bytes,
        );
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
/// SD-backed callers should use `storage.ReadAheadReader` so physical reads run
/// while audio DMA is playing and decoding uses cached workspace.
pub fn playFlac(
    reader: anytype,
    resources: audio.Engine.Resources,
    workspace: FlacWorkspace,
    config: FlacConfig,
) !Result {
    return playFlacControlled(reader, resources, workspace, config, null);
}

/// `control` is polled throughout playback so a device UI can kick its
/// watchdog and stop promptly without coupling the codec pipeline to buttons.
pub fn playFlacControlled(
    reader: anytype,
    resources: audio.Engine.Resources,
    workspace: FlacWorkspace,
    config: FlacConfig,
    control: ?PlaybackControl,
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
    var attenuation = config.attenuation;
    stream.setGain(gainForAttenuation(attenuation));
    if (control) |active| {
        switch (active.command(flacStatus(&stream, &state, .preparing))) {
            .stop => return resultForFlac(&stream, &state, &engine, .stopped, attenuation),
            .next => return resultForFlac(&stream, &state, &engine, .next, attenuation),
            .previous => return resultForFlac(&stream, &state, &engine, .previous, attenuation),
            .set_attenuation => |value| {
                stream.setGain(gainForAttenuation(value));
                attenuation = value;
            },
            .none => {},
        }
    }

    for (resources.buffers[0..config.buffer_count]) |buffer| {
        const output: [*]u8 = @ptrFromInt(buffer.address);
        const fill = try stream.fill(output[0..chunk_bytes]);
        if (fill.bytes == 0) return error.EmptyChunk;
    }
    try prefetchReader(reader);

    try engine.initialize(rate, playback_dac_attenuation);
    try engine.start();
    defer engine.stop();
    if (control) |active| {
        switch (active.command(flacStatus(&stream, &state, .playing))) {
            .stop => return resultForFlac(&stream, &state, &engine, .stopped, attenuation),
            .next => return resultForFlac(&stream, &state, &engine, .next, attenuation),
            .previous => return resultForFlac(&stream, &state, &engine, .previous, attenuation),
            .set_attenuation => |value| {
                stream.setGain(gainForAttenuation(value));
                attenuation = value;
            },
            .none => {},
        }
    }

    while (!state.finished) {
        const event = try engine.poll();
        if (event.dma_fault) return error.AudioDmaFault;
        if (event.underrun) return error.AudioUnderrun;
        if (event.descriptor) |observed| {
            try catchUpPlayback(&state, observed, reader, &stream, resources, chunk_bytes);
            if (state.finished) continue;
        }
        if (control) |active| {
            switch (active.command(flacStatus(&stream, &state, .playing))) {
                .none => {},
                .stop => return resultForFlac(&stream, &state, &engine, .stopped, attenuation),
                .next => return resultForFlac(&stream, &state, &engine, .next, attenuation),
                .previous => return resultForFlac(&stream, &state, &engine, .previous, attenuation),
                .set_attenuation => |value| {
                    stream.setGain(gainForAttenuation(value));
                    attenuation = value;
                },
            }
        }
    }

    return resultForFlac(&stream, &state, &engine, .completed, attenuation);
}

fn gainForAttenuation(attenuation: u8) u32 {
    const bounded = @min(@max(attenuation, playback_dac_attenuation), @as(u8, 128));
    const index = (bounded - playback_dac_attenuation) / 4;
    return software_gains_q24[index];
}

fn flacStatus(stream: anytype, state: anytype, phase: PlaybackPhase) PlaybackStatus {
    const played = @as(u64, state.chunks_completed) * stream.plan.block_frames;
    return .{
        .phase = phase,
        .sample_rate = stream.plan.sample_rate,
        .output_format = stream.plan.output_format,
        .total_frames = stream.plan.frames,
        .played_frames = @min(played, stream.plan.frames),
    };
}

fn resultForFlac(
    stream: anytype,
    state: anytype,
    engine: anytype,
    exit: PlaybackExit,
    attenuation: u8,
) Result {
    return .{
        .sample_rate = stream.plan.sample_rate,
        .output_format = stream.plan.output_format,
        .frames = stream.plan.frames,
        .chunks = state.chunks_completed,
        .underruns = engine.underrun_count,
        .minimum_fifo_level = engine.minimum_fifo_level,
        .stopped = exit != .completed,
        .exit = exit,
        .attenuation = attenuation,
    };
}

fn prefetchReader(reader: anytype) !void {
    const Reader = @TypeOf(reader.*);
    if (comptime @hasDecl(Reader, "prefetch")) try reader.prefetch();
}

fn catchUpPlayback(
    state: *playback.State,
    observed: u7,
    reader: anytype,
    stream: anytype,
    resources: audio.Engine.Resources,
    chunk_bytes: u24,
) !void {
    const completions = try state.completionsTo(observed);
    for (0..completions) |_| {
        const transition = try state.advance(state.nextDescriptor());
        if (transition.refill) |refill| {
            const output: [*]u8 = @ptrFromInt(resources.buffers[refill.slot].address);
            const fill = try stream.fill(output[0..chunk_bytes]);
            if (fill.bytes == 0) return error.EmptyChunk;
            try state.completeRefill(refill);
            try prefetchReader(reader);
        }
    }
}

test "F20 media player compiles its production API" {
    @import("std").testing.refAllDecls(@This());
}

test "media playback discovers optional read-ahead" {
    const std = @import("std");
    const Reader = struct {
        calls: u8 = 0,

        pub fn prefetch(self: *@This()) !void {
            self.calls += 1;
        }
    };
    var reader = Reader{};
    try prefetchReader(&reader);
    try std.testing.expectEqual(@as(u8, 1), reader.calls);
}

test "software volume matches the DAC half-decibel scale at UI steps" {
    const std = @import("std");
    try std.testing.expectEqual(flac_pcm.unity_gain_q24, gainForAttenuation(16));
    try std.testing.expectEqual(@as(u32, 1_677_722), gainForAttenuation(56));
    try std.testing.expectEqual(@as(u32, 26_590), gainForAttenuation(128));
    try std.testing.expect(gainForAttenuation(60) < gainForAttenuation(56));
}
