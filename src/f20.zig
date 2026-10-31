/// Compile-time device boundary for Surfans F20 V2.7 firmware. Product code
/// can depend on this facade while portable policy remains in modules such as
/// `playback`, `fat32`, `wav`, and `pcm`.
pub const audio = @import("f20_audio.zig");
pub const media = @import("f20_media.zig");
pub const storage = @import("f20_storage.zig");
pub const playback = @import("playback.zig");
pub const pcm = @import("pcm.zig");
pub const flac = @import("flac.zig");
pub const flac_lpc = @import("flac_lpc.zig");
pub const flac_pcm = @import("flac_pcm.zig");
pub const hardware = @import("f20_v27.zig");
pub const soc = @import("x1000.zig");

pub const aiff = @import("aiff.zig");
pub const packet_media = @import("packet_media.zig");
pub const codec_pool = @import("codec_pool.zig");
pub const media_source = @import("media_source.zig");
pub const media_info = @import("media_info.zig");
pub const pcm_reservoir = @import("pcm_reservoir.zig");
pub const mp4 = @import("mp4.zig");
pub const ogg = @import("ogg.zig");
pub const media_decoder = @import("media_decoder.zig");
pub const input_stream = @import("input_stream.zig");
pub const audio_output = @import("audio_output.zig");
pub const memory = @import("f20_memory.zig");
