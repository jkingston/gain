/// Compile-time device boundary for Surfans F20 V2.7 firmware. Product code
/// can depend on this facade while portable policy remains in modules such as
/// `playback`, `fat32`, `wav`, and `pcm`.
pub const audio = @import("f20_audio.zig");
pub const media = @import("f20_media.zig");
pub const storage = @import("f20_storage.zig");
pub const playback = @import("playback.zig");
pub const pcm = @import("pcm.zig");
pub const flac = @import("flac.zig");
pub const flac_pcm = @import("flac_pcm.zig");
pub const hardware = @import("f20_v27.zig");
pub const soc = @import("x1000.zig");
