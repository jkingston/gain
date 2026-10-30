const flac = @import("flac.zig");
const pcm = @import("pcm.zig");

pub const Error = error{
    MissingSampleCount,
    UnsupportedSampleFormat,
    InvalidOutputBuffer,
    FormatChanged,
    TooManyChunks,
};

pub const Plan = struct {
    sample_rate: u32,
    output_format: pcm.OutputFormat,
    frames: u64,
    block_frames: u16,

    pub fn fromStreamInfo(info: flac.StreamInfo) Error!Plan {
        if (info.total_samples == 0) return error.MissingSampleCount;
        const output_format: pcm.OutputFormat = switch (info.bits_per_sample) {
            16 => .signed_16_packed,
            24 => .signed_24_in_u32,
            else => return error.UnsupportedSampleFormat,
        };
        return .{
            .sample_rate = info.sample_rate,
            .output_format = output_format,
            .frames = info.total_samples,
            .block_frames = info.maximum_block_size,
        };
    }

    pub fn chunkBytes(self: Plan) u24 {
        return @intCast(@as(u32, self.block_frames) * self.output_format.bytesPerFrame());
    }

    pub fn chunkCount(self: Plan) Error!u32 {
        const chunks = (self.frames + self.block_frames - 1) / self.block_frames;
        if (chunks > maximum_u32) return error.TooManyChunks;
        return @intCast(chunks);
    }
};

pub const Fill = struct {
    frames: u32,
    bytes: u32,
    end: bool,
};

/// Converts a sequential FLAC stream into fixed-size stereo DMA chunks. Short
/// frames are combined and the final chunk is padded with silence.
pub fn Stream(comptime Reader: type) type {
    return struct {
        const Self = @This();

        decoder: flac.Decoder(Reader),
        plan: Plan,
        remaining_frames: u64,
        current_frame: ?flac.Frame = null,
        frame_offset: u16 = 0,

        pub fn init(
            reader: *Reader,
            compressed: []u8,
            left: []i32,
            right: []i32,
        ) !Self {
            const decoder = try flac.Decoder(Reader).init(reader, compressed, left, right);
            const plan = try Plan.fromStreamInfo(decoder.info);
            return .{ .decoder = decoder, .plan = plan, .remaining_frames = plan.frames };
        }

        pub fn fill(self: *Self, output: []u8) !Fill {
            if (output.len != self.plan.chunkBytes() or @intFromPtr(output.ptr) & 3 != 0) {
                return error.InvalidOutputBuffer;
            }
            const words: [*]u32 = @ptrCast(@alignCast(output.ptr));
            var written_frames: u32 = 0;
            while (written_frames < self.plan.block_frames and self.remaining_frames != 0) {
                if (self.current_frame == null or self.frame_offset == self.current_frame.?.block_size) {
                    const frame = try self.decoder.next() orelse return error.Truncated;
                    if (frame.sample_rate != self.plan.sample_rate or
                        frame.bits_per_sample != self.decoder.info.bits_per_sample)
                    {
                        return error.FormatChanged;
                    }
                    self.current_frame = frame;
                    self.frame_offset = 0;
                }

                const frame = self.current_frame.?;
                const available = frame.block_size - self.frame_offset;
                const capacity = self.plan.block_frames - written_frames;
                const count: u16 = @intCast(@min(available, capacity));
                packFrames(
                    words,
                    written_frames,
                    self.decoder.left[self.frame_offset..][0..count],
                    self.decoder.right[self.frame_offset..][0..count],
                    self.plan.output_format,
                );
                written_frames += count;
                self.frame_offset += count;
                self.remaining_frames -= count;
            }
            const written_bytes = written_frames * self.plan.output_format.bytesPerFrame();
            @memset(output[written_bytes..], 0);
            return .{
                .frames = written_frames,
                .bytes = written_bytes,
                .end = self.remaining_frames == 0,
            };
        }
    };
}

fn packFrames(output: [*]u32, first_frame: u32, left: []const i32, right: []const i32, format: pcm.OutputFormat) void {
    switch (format) {
        .signed_16_packed => for (left, right, 0..) |left_sample, right_sample, index| {
            const target = @as(usize, first_frame) + index;
            const left_bits: u16 = @bitCast(@as(i16, @intCast(left_sample)));
            const right_bits: u16 = @bitCast(@as(i16, @intCast(right_sample)));
            output[target] = @as(u32, left_bits) | @as(u32, right_bits) << 16;
        },
        .signed_24_in_u32 => for (left, right, 0..) |left_sample, right_sample, index| {
            const target = (@as(usize, first_frame) + index) * 2;
            output[target] = @as(u32, @bitCast(left_sample)) & 0x00ff_ffff;
            output[target + 1] = @as(u32, @bitCast(right_sample)) & 0x00ff_ffff;
        },
    }
}

const maximum_u32: u64 = 0xffff_ffff;
