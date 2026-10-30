const x1000 = @import("x1000.zig");
const board = @import("f20_v27.zig");
const audio = @import("audio.zig");
const pcm = @import("pcm.zig");

pub const Engine = audio.Engine(board.audio);
pub const Descriptor = x1000.Pdma.Descriptor;
pub const Buffer = audio.Buffer;
pub const Config = audio.Config;
pub const Event = audio.Event;
pub const SampleFormat = audio.SampleFormat;
pub const maximum_descriptors = audio.maximum_descriptors;
pub const maximum_buffers = audio.maximum_buffers;

pub fn sampleRate(hz: u32) ?board.audio.SampleRate {
    return switch (hz) {
        44_100 => .hz_44_100,
        48_000 => .hz_48_000,
        88_200 => .hz_88_200,
        96_000 => .hz_96_000,
        176_400 => .hz_176_400,
        192_000 => .hz_192_000,
        else => null,
    };
}

pub fn sampleFormat(format: pcm.OutputFormat) SampleFormat {
    return switch (format) {
        .signed_16_packed => .pcm_s16_packed,
        .signed_24_in_u32 => .pcm_s24,
    };
}

test "F20 audio specialization compiles its public driver API" {
    @import("std").testing.refAllDecls(Engine);
}
