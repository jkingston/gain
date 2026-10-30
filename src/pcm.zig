const wav = @import("wav.zig");

pub const Error = error{
    UnsupportedEncoding,
    UnsupportedChannels,
    UnsupportedSampleFormat,
    InvalidChannelMask,
    InvalidOutputBuffer,
    Truncated,
    TooManyChunks,
};

pub const SourceFormat = enum {
    signed_16_le,
    signed_24_le_packed,
    signed_24_le_in_32,

    pub fn bytesPerFrame(self: SourceFormat) u8 {
        return switch (self) {
            .signed_16_le => 4,
            .signed_24_le_packed => 6,
            .signed_24_le_in_32 => 8,
        };
    }
};

pub const OutputFormat = enum {
    signed_16_packed,
    signed_24_in_u32,

    pub fn bytesPerFrame(self: OutputFormat) u8 {
        return switch (self) {
            .signed_16_packed => 4,
            .signed_24_in_u32 => 8,
        };
    }
};

pub const Plan = struct {
    sample_rate: u32,
    source_format: SourceFormat,
    output_format: OutputFormat,
    frames: u32,

    pub fn fromWave(info: wav.Info) Error!Plan {
        if (info.encoding != .pcm_integer) return error.UnsupportedEncoding;
        if (info.channels != 2) return error.UnsupportedChannels;
        if (info.channel_mask != 0 and info.channel_mask != stereo_channel_mask) {
            return error.InvalidChannelMask;
        }

        const source_format: SourceFormat = if (info.bits_per_sample == 16 and
            info.valid_bits_per_sample == 16 and info.block_align == 4)
            .signed_16_le
        else if (info.bits_per_sample == 24 and info.valid_bits_per_sample == 24 and
            info.block_align == 6)
            .signed_24_le_packed
        else if (info.bits_per_sample == 32 and info.valid_bits_per_sample == 24 and
            info.block_align == 8)
            .signed_24_le_in_32
        else
            return error.UnsupportedSampleFormat;

        const output_format: OutputFormat = switch (source_format) {
            .signed_16_le => .signed_16_packed,
            .signed_24_le_packed, .signed_24_le_in_32 => .signed_24_in_u32,
        };
        return .{
            .sample_rate = info.sample_rate,
            .source_format = source_format,
            .output_format = output_format,
            .frames = info.data_bytes / source_format.bytesPerFrame(),
        };
    }

    pub fn outputBytes(self: Plan) u64 {
        return @as(u64, self.frames) * self.output_format.bytesPerFrame();
    }

    pub fn chunkCount(self: Plan, chunk_bytes: usize) Error!u32 {
        const frame_bytes = self.output_format.bytesPerFrame();
        if (chunk_bytes == 0 or chunk_bytes % frame_bytes != 0) {
            return error.InvalidOutputBuffer;
        }
        const bytes = self.outputBytes();
        const chunks = (bytes + chunk_bytes - 1) / chunk_bytes;
        if (chunks > maximum_u32) return error.TooManyChunks;
        return @intCast(chunks);
    }
};

pub const Fill = struct {
    frames: u32,
    bytes: u32,
    end: bool,
};

/// Converts one WAV PCM stream into the exact interleaved DMA layout consumed
/// by the native audio driver. The caller owns the output buffers; no memory is
/// allocated and a partial final buffer is padded with silence.
pub fn Stream(comptime Reader: type) type {
    return struct {
        const Self = @This();

        reader: *Reader,
        plan: Plan,
        remaining_frames: u32,

        pub fn init(reader: *Reader, info: wav.Info) Error!Self {
            const plan = try Plan.fromWave(info);
            return .{ .reader = reader, .plan = plan, .remaining_frames = plan.frames };
        }

        pub fn fill(self: *Self, output: []u8) !Fill {
            const output_frame_bytes = self.plan.output_format.bytesPerFrame();
            if (output.len == 0 or output.len % output_frame_bytes != 0 or
                output.len > maximum_u32)
            {
                return error.InvalidOutputBuffer;
            }
            @memset(output, 0);
            const capacity_frames = output.len / output_frame_bytes;
            const frames: usize = @min(capacity_frames, self.remaining_frames);
            if (frames == 0) return .{ .frames = 0, .bytes = 0, .end = true };

            const source_bytes = frames * self.plan.source_format.bytesPerFrame();
            try readExact(self.reader, output[0..source_bytes]);
            switch (self.plan.source_format) {
                .signed_16_le => {},
                .signed_24_le_packed => expandPacked24(output, frames),
                .signed_24_le_in_32 => compactAligned24(output, frames),
            }
            self.remaining_frames -= @intCast(frames);
            return .{
                .frames = @intCast(frames),
                .bytes = @intCast(frames * output_frame_bytes),
                .end = self.remaining_frames == 0,
            };
        }
    };
}

fn readExact(reader: anytype, output: []u8) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        const count = try reader.read(output[offset..]);
        if (count == 0) return error.Truncated;
        offset += count;
    }
}

fn expandPacked24(buffer: []u8, frames: usize) void {
    var frame = frames;
    while (frame != 0) {
        frame -= 1;
        const source = frame * 6;
        const target = frame * 8;
        const left: [3]u8 = buffer[source..][0..3].*;
        const right: [3]u8 = buffer[source + 3 ..][0..3].*;
        writeLow24(buffer[target..][0..4], &left);
        writeLow24(buffer[target + 4 ..][0..4], &right);
    }
}

fn compactAligned24(buffer: []u8, frames: usize) void {
    // WAVE_FORMAT_EXTENSIBLE stores valid bits left-aligned in each container.
    for (0..frames * 2) |sample| {
        const offset = sample * 4;
        buffer[offset] = buffer[offset + 1];
        buffer[offset + 1] = buffer[offset + 2];
        buffer[offset + 2] = buffer[offset + 3];
        buffer[offset + 3] = 0;
    }
}

fn writeLow24(output: *[4]u8, input: *const [3]u8) void {
    output[0] = input[0];
    output[1] = input[1];
    output[2] = input[2];
    output[3] = 0;
}

const stereo_channel_mask: u32 = 0x3;
const maximum_u32: u64 = 0xffff_ffff;
