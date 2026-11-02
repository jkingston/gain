//! minimp3 C ABI adapter; state is owned directly and requires no allocator.
const c = @import("c_mp3");

comptime {
    if (c.mp3d_sample_t != f32) @compileError("minimp3 must produce float PCM");
}

pub const Decoder = struct {
    state: c.mp3dec_t = undefined,

    pub fn init() Decoder {
        var self: Decoder = .{};
        c.mp3dec_init(&self.state);
        return self;
    }

    pub fn next(self: *Decoder, input: []const u8, out: *[2304]f32) !Step {
        var info = c.mp3dec_frame_info_t{};
        const frames = c.mp3dec_decode_frame(&self.state, input.ptr, @intCast(input.len), out, &info);
        if (frames < 0 or frames > 1152 or info.frame_bytes < 0 or info.frame_bytes > input.len) return error.InvalidDecoderResult;
        if (info.frame_bytes == 0) return .need_more;
        if (frames == 0) return .{ .skipped = @intCast(info.frame_bytes) };
        if (info.channels != 1 and info.channels != 2) return error.InvalidDecoderResult;
        return .{
            .frame = .{
                .consumed = @intCast(info.frame_bytes),
                .frames = @intCast(frames),
                .channels = @intCast(info.channels),
                .rate = @intCast(info.hz),
            },
        };
    }
};

pub const Frame = struct { consumed: usize, frames: usize, channels: u8, rate: u32 };

pub const Step = union(enum) { need_more, skipped: usize, frame: Frame };
