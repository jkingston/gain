//! Shared player status and control contract; execution lives in f20_player.
const pcm = @import("pcm.zig");
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
};

pub const PlaybackStatus = struct {
    phase: PlaybackPhase,
    sample_rate: u32,
    output_format: pcm.OutputFormat,
    total_frames: u64,
    played_frames: u64,
};

pub const PlaybackPhase = enum { preparing, playing };
