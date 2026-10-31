const wav = @import("wav.zig");
const sample = @import("pcm_sample.zig");
pub const Sample = sample;

pub const Error = error{
    UnsupportedEncoding,
    UnsupportedChannels,
    UnsupportedSampleFormat,
    InvalidChannelMask,
    InvalidOutputBuffer,
    Truncated,
    TooManyChunks,
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
    output_format: OutputFormat,
    frames: u32,
    channels: u2 = 2,
    sample_format: sample.Format = .{ .bytes = 2, .valid_bits = 16 },

    pub fn sourceBytesPerFrame(self: Plan) u8 {
        return @as(u8, self.sample_format.bytes) * self.channels;
    }

    pub fn fromWave(info: wav.Info) Error!Plan {
        if (info.channels != 1 and info.channels != 2) return error.UnsupportedChannels;
        const mono_channel_mask: u32 = 4;
        const expected_mask = if (info.channels == 1) mono_channel_mask else stereo_channel_mask;
        if (info.channel_mask != 0 and info.channel_mask != expected_mask) return error.InvalidChannelMask;
        if (info.valid_bits_per_sample > info.bits_per_sample or info.bits_per_sample == 0 or info.bits_per_sample % 8 != 0 or info.bits_per_sample > 64) return error.UnsupportedSampleFormat;
        const format = sample.Format{
            .encoding = if (info.encoding == .ieee_float) .float else if (info.bits_per_sample == 8) .unsigned else .signed,
            .bytes = @intCast(info.bits_per_sample / 8),
            .valid_bits = @intCast(info.valid_bits_per_sample),
        };
        if (info.block_align != @as(u32, format.bytes) * info.channels or info.data_bytes % info.block_align != 0) return error.UnsupportedSampleFormat;
        return fromFormat(info.sample_rate, info.channels, format, info.data_bytes / info.block_align);
    }

    pub fn fromFormat(rate: u32, channels: u16, format: sample.Format, frames: u32) Error!Plan {
        if (channels != 1 and channels != 2) return error.UnsupportedChannels;
        if (!format.valid()) return error.UnsupportedSampleFormat;
        return .{
            .sample_rate = rate,
            .output_format = if (format.encoding != .float and format.valid_bits <= 16) .signed_16_packed else .signed_24_in_u32,
            .frames = frames,
            .channels = @intCast(channels),
            .sample_format = format,
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
        quantizer: sample.Quantizer = .{},

        pub fn init(reader: *Reader, info: wav.Info) Error!Self {
            return fromPlan(reader, try Plan.fromWave(info));
        }

        pub fn fromPlan(reader: *Reader, plan: Plan) Self {
            return .{ .reader = reader, .plan = plan, .remaining_frames = plan.frames };
        }

        pub fn fill(self: *Self, output: []u8) !Fill {
            const output_frame_bytes = self.plan.output_format.bytesPerFrame();
            if (output.len == 0 or output.len % output_frame_bytes != 0 or
                output.len > maximum_u32)
            {
                return error.InvalidOutputBuffer;
            }
            const capacity_frames = output.len / output_frame_bytes;
            const frames: usize = @min(capacity_frames, self.remaining_frames);
            if (frames == 0) {
                @memset(output, 0);
                return .{ .frames = 0, .bytes = 0, .end = true };
            }

            const format = self.plan.sample_format;
            const direct_copy = self.plan.channels == 2 and format.endian == .little and format.encoding == .signed and format.bytes == 2 and format.valid_bits == 16;
            if (direct_copy) try readExact(self.reader, output[0 .. frames * output_frame_bytes]) else try self.convert(output, frames);
            @memset(output[frames * output_frame_bytes ..], 0);
            self.remaining_frames -= @intCast(frames);
            return .{
                .frames = @intCast(frames),
                .bytes = @intCast(frames * output_frame_bytes),
                .end = self.remaining_frames == 0,
            };
        }
        fn convert(self: *Self, output: []u8, frames: usize) !void {
            // Bounded scratch also handles float64 stereo (16 source bytes per
            // frame) without aliasing a smaller DMA output buffer.
            var scratch: [1024]u8 = undefined;
            const source_frame = self.plan.sourceBytesPerFrame();
            const format = self.plan.sample_format;
            const output_frame = self.plan.output_format.bytesPerFrame();
            var done: usize = 0;
            while (done < frames) {
                const count = @min(frames - done, scratch.len / source_frame);
                try readExact(self.reader, scratch[0 .. count * source_frame]);
                for (0..count) |frame| {
                    const input = scratch[frame * source_frame ..];
                    var pair: [2]i32 = undefined;
                    for (0..self.plan.channels) |channel| {
                        const decoded = format.decode(input[channel * format.bytes ..]);
                        pair[channel] = if (output_frame == 4) decoded >> 16 else self.quantizer.to24(decoded, format.valid_bits > 24);
                    }
                    if (self.plan.channels == 1) pair[1] = pair[0];
                    const target = (done + frame) * output_frame;
                    if (@intFromPtr(output.ptr) & 3 == 0) {
                        // One paired word for 16-bit or two words for 24-bit.
                        // Never read back or byte-write uncached DMA memory.
                        const words: [*]u32 = @ptrCast(@alignCast(output.ptr));
                        if (output_frame == 4) {
                            words[done + frame] = (@as(u32, @bitCast(pair[0])) & 0xffff) | (@as(u32, @bitCast(pair[1])) << 16);
                        } else {
                            words[(done + frame) * 2] = @as(u32, @bitCast(pair[0])) & 0xffffff;
                            words[(done + frame) * 2 + 1] = @as(u32, @bitCast(pair[1])) & 0xffffff;
                        }
                    } else for (pair, 0..) |value, channel| {
                        const word: u32 = @bitCast(value);
                        const size = output_frame / 2;
                        for (0..size) |byte| output[target + channel * size + byte] = if (byte == 3) 0 else @truncate(word >> @as(u5, @intCast(byte * 8)));
                    }
                }
                done += count;
            }
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

const stereo_channel_mask: u32 = 0x3;
const maximum_u32: u64 = 0xffff_ffff;

test "unaligned DMA destination fallback preserves samples, padding and canaries" {
    const std = @import("std");
    const Reader = struct {
        position: usize = 0,
        pub fn read(self: *@This(), output: []u8) !usize {
            const source = [_]u8{ 0, 0, 0x80, 0xff, 0xff, 0x7f, 1, 2, 3, 4, 5, 6 };
            const count = @min(output.len, source.len - self.position);
            @memcpy(output[0..count], source[self.position..][0..count]);
            self.position += count;
            return count;
        }
    };
    var first = Reader{};
    var second = Reader{};
    const plan = try Plan.fromFormat(48000, 2, .{ .bytes = 3, .valid_bits = 24 }, 2);
    var aligned: [24]u8 align(4) = undefined;
    var memory: [26]u8 align(4) = @splat(0xa5);
    var a = Stream(Reader).fromPlan(&first, plan);
    var b = Stream(Reader).fromPlan(&second, plan);
    _ = try a.fill(&aligned);
    _ = try b.fill(memory[1..25]);
    try std.testing.expectEqualSlices(u8, &aligned, memory[1..25]);
    try std.testing.expect(memory[0] == 0xa5 and memory[25] == 0xa5);
}
