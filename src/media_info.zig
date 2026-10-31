//! Values shared by the decoder, playback session and presentation layer.
const pcm = @import("pcm.zig");
pub const Kind = enum { wave, aiff, flac, mp3, aac, alac, vorbis, opus };
pub const Text = struct {
    bytes: [128]u8 = @splat(0),
    length: usize = 0,
    pub fn set(self: *Text, value: []const u8) void {
        self.length = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..self.length], value[0..self.length]);
    }
    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.length];
    }
};
pub const Information = struct {
    kind: Kind,
    sample_rate: u32,
    channels: u2,
    output_format: pcm.OutputFormat,
    source_bits: u8 = 24,
    total_frames: ?u64 = null,
    start_frame: u64 = 0,
    title: Text = .{},
    artist: Text = .{},
    album: Text = .{},
};
