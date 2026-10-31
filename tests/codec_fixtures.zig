pub const Case = struct { name: []const u8, kind: enum { aac, alac, vorbis, opus, mp3, wave, aiff, flac }, bytes: []const u8, reference: []const u8, rate: u32, channels: u32, frames: u32, bits: u32 };
pub const cases = [_]Case{
    .{ .name = "free-format", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/free-format.mp3"), .reference = @embedFile("fixtures/codecs/stereo-cbr.reference.f32le"), .rate = 44100, .channels = 2, .frames = 24192, .bits = 16 },
    .{ .name = "aac44", .kind = .aac, .bytes = @embedFile("fixtures/codecs/aac44.m4a"), .reference = @embedFile("fixtures/codecs/aac44.reference.f32le"), .rate = 44100, .channels = 2, .frames = 22050, .bits = 16 },
    .{ .name = "aac48-fast", .kind = .aac, .bytes = @embedFile("fixtures/codecs/aac48-fast.m4a"), .reference = @embedFile("fixtures/codecs/aac48-fast.reference.f32le"), .rate = 48000, .channels = 1, .frames = 24000, .bits = 16 },
    .{ .name = "alac16", .kind = .alac, .bytes = @embedFile("fixtures/codecs/alac16.m4a"), .reference = @embedFile("fixtures/codecs/alac16.reference.f32le"), .rate = 44100, .channels = 2, .frames = 22050, .bits = 16 },
    .{ .name = "alac24-high", .kind = .alac, .bytes = @embedFile("fixtures/codecs/alac24-high.m4a"), .reference = @embedFile("fixtures/codecs/alac24-high.reference.f32le"), .rate = 192000, .channels = 2, .frames = 24000, .bits = 24 },
    .{ .name = "vorbis44", .kind = .vorbis, .bytes = @embedFile("fixtures/codecs/vorbis44.ogg"), .reference = @embedFile("fixtures/codecs/vorbis44.reference.f32le"), .rate = 44100, .channels = 2, .frames = 44100, .bits = 16 },
    .{ .name = "vorbis48", .kind = .vorbis, .bytes = @embedFile("fixtures/codecs/vorbis48.ogg"), .reference = @embedFile("fixtures/codecs/vorbis48.reference.f32le"), .rate = 48000, .channels = 1, .frames = 48000, .bits = 16 },
    .{ .name = "opus48", .kind = .opus, .bytes = @embedFile("fixtures/codecs/opus48.opus"), .reference = @embedFile("fixtures/codecs/opus48.reference.f32le"), .rate = 48000, .channels = 2, .frames = 48000, .bits = 16 },
    .{ .name = "vorbis-continued", .kind = .vorbis, .bytes = @embedFile("fixtures/codecs/vorbis-continued.ogg"), .reference = @embedFile("fixtures/codecs/vorbis44.reference.f32le"), .rate = 44100, .channels = 2, .frames = 44100, .bits = 16 },
    .{ .name = "vorbis-chain", .kind = .vorbis, .bytes = @embedFile("fixtures/codecs/vorbis-chain.ogg"), .reference = @embedFile("fixtures/codecs/vorbis-chain.reference.f32le"), .rate = 44100, .channels = 2, .frames = 88200, .bits = 16 },
    .{ .name = "opus-chain", .kind = .opus, .bytes = @embedFile("fixtures/codecs/opus-chain.ogg"), .reference = @embedFile("fixtures/codecs/opus-chain.reference.f32le"), .rate = 48000, .channels = 2, .frames = 96000, .bits = 16 },
    .{ .name = "aac44-nopns", .kind = .aac, .bytes = @embedFile("fixtures/codecs/aac44-nopns.m4a"), .reference = @embedFile("fixtures/codecs/aac44-nopns.reference.f32le"), .rate = 44100, .channels = 2, .frames = 22050, .bits = 16 },
    .{ .name = "aac48-nopns", .kind = .aac, .bytes = @embedFile("fixtures/codecs/aac48-nopns.m4a"), .reference = @embedFile("fixtures/codecs/aac48-nopns.reference.f32le"), .rate = 48000, .channels = 1, .frames = 24000, .bits = 16 },
    .{ .name = "stereo-cbr", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/stereo-cbr.mp3"), .reference = @embedFile("fixtures/codecs/stereo-cbr.reference.f32le"), .rate = 44100, .channels = 2, .frames = 24192, .bits = 16 },
    .{ .name = "stereo-dense", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/stereo-dense.mp3"), .reference = @embedFile("fixtures/codecs/stereo-dense.reference.f32le"), .rate = 48000, .channels = 2, .frames = 25344, .bits = 16 },
    .{ .name = "stereo-vbr", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/stereo-vbr.mp3"), .reference = @embedFile("fixtures/codecs/stereo-vbr.reference.f32le"), .rate = 44100, .channels = 2, .frames = 24192, .bits = 16 },
    .{ .name = "speech-low", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/speech-low.mp3"), .reference = @embedFile("fixtures/codecs/speech-low.reference.f32le"), .rate = 8000, .channels = 1, .frames = 5184, .bits = 16 },
    .{ .name = "mono-32k", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/mono-32k.mp3"), .reference = @embedFile("fixtures/codecs/mono-32k.reference.f32le"), .rate = 32000, .channels = 1, .frames = 17280, .bits = 16 },
    .{ .name = "stereo-24k", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/stereo-24k.mp3"), .reference = @embedFile("fixtures/codecs/stereo-24k.reference.f32le"), .rate = 24000, .channels = 2, .frames = 13248, .bits = 16 },
    .{ .name = "stereo44", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/stereo44.mp3"), .reference = @embedFile("fixtures/codecs/stereo44.reference.f32le"), .rate = 44100, .channels = 2, .frames = 21888, .bits = 16 },
    .{ .name = "mono22", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/mono22.mp3"), .reference = @embedFile("fixtures/codecs/mono22.reference.f32le"), .rate = 22050, .channels = 1, .frames = 11520, .bits = 16 },
    .{ .name = "mono11", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/mono11.mp3"), .reference = @embedFile("fixtures/codecs/mono11.reference.f32le"), .rate = 11025, .channels = 1, .frames = 6336, .bits = 16 },
    .{ .name = "layer1", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/layer1.mp1"), .reference = @embedFile("fixtures/codecs/layer1.reference.f32le"), .rate = 44100, .channels = 2, .frames = 7680, .bits = 16 },
    .{ .name = "layer2", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/layer2.mp2"), .reference = @embedFile("fixtures/codecs/layer2.reference.f32le"), .rate = 44100, .channels = 2, .frames = 26496, .bits = 16 },
    .{ .name = "tagged-gapless", .kind = .mp3, .bytes = @embedFile("fixtures/codecs/tagged-gapless.mp3"), .reference = @embedFile("fixtures/codecs/tagged.reference.f32le"), .rate = 44100, .channels = 2, .frames = 32123, .bits = 16 },
    .{ .name = "flac-16", .kind = .flac, .bytes = @embedFile("fixtures/codecs/flac-16.flac"), .reference = @embedFile("fixtures/codecs/flac-16.reference.f32le"), .rate = 44100, .channels = 2, .frames = 16317, .bits = 16 },
    .{ .name = "flac-24", .kind = .flac, .bytes = @embedFile("fixtures/codecs/flac-24.flac"), .reference = @embedFile("fixtures/codecs/flac-24.reference.f32le"), .rate = 48000, .channels = 2, .frames = 14880, .bits = 24 },
    .{ .name = "wave16", .kind = .wave, .bytes = @embedFile("fixtures/codecs/wave16.wav"), .reference = @embedFile("fixtures/codecs/wave16.reference.f32le"), .rate = 44100, .channels = 2, .frames = 16317, .bits = 16 },
    .{ .name = "wave-mono8", .kind = .wave, .bytes = @embedFile("fixtures/codecs/wave-mono8.wav"), .reference = @embedFile("fixtures/codecs/wave-mono8.reference.f32le"), .rate = 44100, .channels = 1, .frames = 16317, .bits = 8 },
    .{ .name = "wave-float", .kind = .wave, .bytes = @embedFile("fixtures/codecs/wave-float.wav"), .reference = @embedFile("fixtures/codecs/wave-float.reference.f32le"), .rate = 44100, .channels = 1, .frames = 16317, .bits = 32 },
    .{ .name = "aiff24", .kind = .aiff, .bytes = @embedFile("fixtures/codecs/aiff24.aiff"), .reference = @embedFile("fixtures/codecs/aiff24.reference.f32le"), .rate = 48000, .channels = 2, .frames = 14880, .bits = 24 },
    .{ .name = "aifc-float64", .kind = .aiff, .bytes = @embedFile("fixtures/codecs/aifc-float64.aiff"), .reference = @embedFile("fixtures/codecs/aifc-float64.reference.f32le"), .rate = 48000, .channels = 2, .frames = 14880, .bits = 64 },
};

pub const oracle = @import("fixtures/codecs/oracle.zig");
pub const extended = @embedFile("fixtures/codecs/aac-co64-v1-chapters.m4a");

pub const multichunk = @embedFile("fixtures/codecs/aac-multichunk.m4a");
