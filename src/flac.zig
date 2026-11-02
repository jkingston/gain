//! Allocation-free native FLAC decoding for mono and stereo streams.
//!
//! The caller supplies one signed 32-bit work buffer per output channel. Each
//! must hold `StreamInfo.maximum_block_size` samples. Frames are independent,
//! CRC checked and decoded without floating point or heap allocation.

const std = @import("std");
const lpc = @import("flac_lpc.zig");

pub const Error = error{
    Truncated,
    InvalidSignature,
    InvalidMetadata,
    MissingStreamInfo,
    UnsupportedChannels,
    InvalidFrame,
    InvalidHeaderCrc,
    InvalidFrameCrc,
    OutputTooSmall,
    CompressedBufferTooSmall,
    InvalidSubframe,
    InvalidResidual,
};

pub const StreamInfo = struct {
    minimum_block_size: u16,
    maximum_block_size: u16,
    minimum_frame_size: u24,
    maximum_frame_size: u24,
    sample_rate: u20,
    channels: u4,
    bits_per_sample: u6,
    total_samples: u36,
    first_frame_offset: usize,
};

pub const Frame = struct {
    block_size: u16,
    sample_rate: u32,
    bits_per_sample: u6,
    channels: u4,
    coded_number: u36,
    bytes_consumed: usize,
};

pub const Coverage = struct {
    channel_modes: u16 = 0,
    subframe_types: u64 = 0,
    residual_methods: u2 = 0,
    saw_escape: bool = false,
    saw_wasted_bits: bool = false,
};

/// Parses the mandatory STREAMINFO block and skips all file-level metadata.
pub fn parseStreamInfo(input: []const u8) Error!StreamInfo {
    if (input.len < minimum_file_bytes or !std.mem.eql(u8, input[0..4], flac_signature)) {
        return error.InvalidSignature;
    }
    var offset: usize = 4;
    var first = true;
    var result: ?StreamInfo = null;
    while (true) {
        if (offset + 4 > input.len) return error.Truncated;
        const flags = input[offset];
        const last = flags & 0x80 != 0;
        const kind = flags & 0x7f;
        const length = readBe24(input[offset + 1 ..][0..3]);
        offset += 4;
        if (kind == 127) return error.InvalidMetadata;
        if (offset + length > input.len) return error.Truncated;
        if (first and kind != 0) return error.MissingStreamInfo;
        if (kind == 0) {
            if (!first or length != stream_info_bytes or result != null) return error.InvalidMetadata;
            const block = input[offset..][0..stream_info_bytes];
            result = try parseStreamInfoBlock(block);
        }
        offset += length;
        first = false;
        if (last) break;
    }
    var info = result orelse return error.MissingStreamInfo;
    info.first_frame_offset = offset;
    return info;
}

/// Incrementally reads FLAC metadata and frames from a sequential source.
/// Compressed input and decoded channel storage are supplied by the caller.
pub fn Decoder(comptime Reader: type) type {
    return struct {
        const Self = @This();

        reader: *Reader,
        info: StreamInfo,
        compressed: []u8,
        compressed_bytes: usize = 0,
        end_of_input: bool = false,
        left: []i32,
        right: []i32,
        decoded_samples: u64 = 0,

        pub fn init(reader: *Reader, compressed: []u8, left: []i32, right: []i32) !Self {
            if (compressed.len == 0) return error.CompressedBufferTooSmall;
            var signature: [4]u8 = undefined;
            try readExact(reader, &signature);
            if (!std.mem.eql(u8, &signature, flac_signature)) return error.InvalidSignature;

            var first = true;
            var stream_info: ?StreamInfo = null;
            var stream_offset: usize = signature.len;
            while (true) {
                var header: [4]u8 = undefined;
                try readExact(reader, &header);
                stream_offset += header.len;
                const last = header[0] & 0x80 != 0;
                const kind = header[0] & 0x7f;
                const length = readBe24(header[1..4]);
                if (kind == 127) return error.InvalidMetadata;
                if (first and kind != 0) return error.MissingStreamInfo;
                if (kind == 0) {
                    if (!first or length != stream_info_bytes or stream_info != null) {
                        return error.InvalidMetadata;
                    }
                    var block: [stream_info_bytes]u8 = undefined;
                    try readExact(reader, &block);
                    stream_info = try parseStreamInfoBlock(&block);
                } else {
                    try discardExact(reader, compressed, length);
                }
                stream_offset += length;
                first = false;
                if (last) break;
            }

            var info = stream_info orelse return error.MissingStreamInfo;
            info.first_frame_offset = stream_offset;
            if (left.len < info.maximum_block_size or right.len < info.maximum_block_size) {
                return error.OutputTooSmall;
            }
            if (info.maximum_frame_size != 0 and compressed.len < info.maximum_frame_size) {
                return error.CompressedBufferTooSmall;
            }
            return .{
                .reader = reader,
                .info = info,
                .compressed = compressed,
                .left = left,
                .right = right,
            };
        }

        pub fn next(self: *Self) !?Frame {
            if (self.info.total_samples != 0 and self.decoded_samples == self.info.total_samples) {
                return null;
            }
            // Refill before decoding so a partial frame carried from the prior
            // chunk is never decoded twice. This keeps refill work bounded to
            // one frame decode on the device's real-time audio path.
            const refill_bytes: usize = if (self.info.maximum_frame_size == 0)
                self.compressed.len
            else
                self.info.maximum_frame_size;
            while (self.compressed_bytes < refill_bytes and !self.end_of_input) {
                const count = try self.reader.read(self.compressed[self.compressed_bytes..refill_bytes]);
                if (count == 0) {
                    self.end_of_input = true;
                    break;
                }
                self.compressed_bytes += count;
            }
            if (self.compressed_bytes == 0) {
                if (self.info.total_samples == 0) return null;
                return error.Truncated;
            }

            const decoded = decodeFrame(
                self.compressed[0..self.compressed_bytes],
                self.info,
                self.left,
                self.right,
            ) catch |failure| switch (failure) {
                error.Truncated => if (self.end_of_input)
                    return error.Truncated
                else
                    return error.CompressedBufferTooSmall,
                else => return failure,
            };

            const remaining = self.compressed_bytes - decoded.bytes_consumed;
            std.mem.copyForwards(
                u8,
                self.compressed[0..remaining],
                self.compressed[decoded.bytes_consumed..self.compressed_bytes],
            );
            self.compressed_bytes = remaining;
            self.decoded_samples += decoded.block_size;
            if (self.info.total_samples != 0 and self.decoded_samples > self.info.total_samples) {
                return error.InvalidFrame;
            }
            return decoded;
        }
    };
}

pub fn decodeFrame(input: []const u8, info: StreamInfo, left: []i32, right: []i32) Error!Frame {
    return decodeFrameObserved(input, info, left, right, null);
}

pub fn decodeFrameObserved(input: []const u8, info: StreamInfo, left: []i32, right: []i32, coverage: ?*Coverage) Error!Frame {
    var bits = BitReader.init(input);
    if (try bits.read(15) != frame_sync_code) return error.InvalidFrame;
    _ = try bits.read(1); // blocking strategy; coded number interpretation does not affect decoding.
    const block_code: u4 = @intCast(try bits.read(4));
    const rate_code: u4 = @intCast(try bits.read(4));
    const channel_code: u4 = @intCast(try bits.read(4));
    const depth_code: u3 = @intCast(try bits.read(3));
    if (try bits.read(1) != 0 or block_code == 0 or rate_code == 15 or channel_code > 10 or depth_code == 3) {
        return error.InvalidFrame;
    }
    const coded_number = try readCodedNumber(&bits);
    const block_size = try decodeBlockSize(&bits, block_code);
    const sample_rate = try decodeSampleRate(&bits, rate_code, info.sample_rate);
    const depth = decodeBitDepth(depth_code, info.bits_per_sample) orelse return error.InvalidFrame;
    if (bits.bit_position & 7 != 0) return error.InvalidFrame;
    const header_length = bits.bit_position / 8;
    const stored_header_crc: u8 = @intCast(try bits.read(8));
    if (crc8(input[0..header_length]) != stored_header_crc) return error.InvalidHeaderCrc;

    const channel_count: u4 = if (channel_code <= 7) channel_code + 1 else 2;
    if (coverage) |observed| observed.channel_modes |= @as(u16, 1) << channel_code;
    if (channel_count != info.channels or channel_count > 2) return error.InvalidFrame;
    if (block_size > info.maximum_block_size) return error.InvalidFrame;
    if (left.len < block_size or right.len < block_size) return error.OutputTooSmall;

    const left_depth: u6 = depth + @as(u6, @intFromBool(channel_code == 9));
    const right_depth: u6 = depth + @as(u6, @intFromBool(channel_code == 8 or channel_code == 10));
    try decodeSubframe(&bits, left[0..block_size], left_depth, coverage);
    if (channel_count == 2) {
        try decodeSubframe(&bits, right[0..block_size], right_depth, coverage);
        try restoreStereo(channel_code, left[0..block_size], right[0..block_size]);
    } else {
        @memcpy(right[0..block_size], left[0..block_size]);
    }

    while (bits.bit_position & 7 != 0) {
        if (try bits.read(1) != 0) return error.InvalidFrame;
    }
    const frame_bytes_without_crc = bits.bit_position / 8;
    const stored_frame_crc: u16 = @intCast(try bits.read(16));
    if (crc16(input[0..frame_bytes_without_crc]) != stored_frame_crc) return error.InvalidFrameCrc;
    return .{
        .block_size = block_size,
        .sample_rate = sample_rate,
        .bits_per_sample = depth,
        .channels = channel_count,
        .coded_number = coded_number,
        .bytes_consumed = bits.bit_position / 8,
    };
}

fn decodeSubframe(bits: *BitReader, output: []i32, channel_depth: u6, coverage: ?*Coverage) Error!void {
    if (try bits.read(1) != 0) return error.InvalidSubframe;
    const kind: u6 = @intCast(try bits.read(6));
    const has_wasted = try bits.read(1) != 0;
    if (coverage) |observed| {
        observed.subframe_types |= @as(u64, 1) << kind;
        observed.saw_wasted_bits = observed.saw_wasted_bits or has_wasted;
    }
    const wasted: u6 = if (has_wasted) @intCast((try bits.readUnary()) + 1) else 0;
    if (wasted >= channel_depth) return error.InvalidSubframe;
    const depth: u6 = channel_depth - wasted;

    if (kind == 0) {
        const value = try bits.readSigned(depth);
        @memset(output, value);
    } else if (kind == 1) {
        for (output) |*sample| sample.* = try bits.readSigned(depth);
    } else if (kind >= 8 and kind <= 12) {
        const order: u6 = kind - 8;
        try decodeWarmup(bits, output, depth, order);
        try decodeResidual(bits, output, order, coverage);
        try restoreFixed(output, order);
    } else if (kind >= 32) {
        const order: u6 = kind - 31;
        try decodeWarmup(bits, output, depth, order);
        const precision_minus_one = try bits.read(4);
        if (precision_minus_one == 15) return error.InvalidSubframe;
        const precision: u6 = @intCast(precision_minus_one + 1);
        const shift = try bits.readSigned(5);
        if (shift < 0) return error.InvalidSubframe;
        var coefficients: [32]i32 = undefined;
        for (coefficients[0..order]) |*coefficient| coefficient.* = try bits.readSigned(precision);
        try decodeResidual(bits, output, order, coverage);
        try lpc.restore(output, order, coefficients[0..order], @intCast(shift));
    } else return error.InvalidSubframe;

    if (wasted != 0) {
        for (output) |*sample| try assignSample(sample, @as(i64, sample.*) << @intCast(wasted));
    }
}

fn decodeWarmup(bits: *BitReader, output: []i32, depth: u6, order: u6) Error!void {
    if (order > output.len) return error.InvalidSubframe;
    for (output[0..order]) |*sample| sample.* = try bits.readSigned(depth);
}

fn decodeResidual(bits: *BitReader, output: []i32, predictor_order: u6, coverage: ?*Coverage) Error!void {
    const method = try bits.read(2);
    if (method > 1) return error.InvalidResidual;
    if (coverage) |observed| observed.residual_methods |= @as(u2, 1) << @intCast(method);
    const parameter_bits: u6 = if (method == 0) 4 else 5;
    const escape = (@as(u32, 1) << @intCast(parameter_bits)) - 1;
    const partition_order: u4 = @intCast(try bits.read(4));
    const partitions = @as(usize, 1) << @intCast(partition_order);
    if (output.len % partitions != 0 or output.len / partitions <= predictor_order) return error.InvalidResidual;
    const partition_size = output.len / partitions;
    var sample_index: usize = predictor_order;
    for (0..partitions) |partition| {
        var count = partition_size;
        if (partition == 0) count -= predictor_order;
        const parameter = try bits.read(parameter_bits);
        if (parameter == escape) {
            if (coverage) |observed| observed.saw_escape = true;
            const raw_depth: u6 = @intCast(try bits.read(5));
            for (0..count) |_| {
                output[sample_index] = if (raw_depth == 0) 0 else try bits.readSigned(raw_depth);
                sample_index += 1;
            }
        } else {
            const rice: u5 = @intCast(parameter);
            for (0..count) |_| {
                const quotient = try bits.readUnary();
                if (quotient > (@as(u32, 0x7fff_ffff) >> rice)) return error.InvalidResidual;
                const remainder = try bits.read(rice);
                const folded: u32 = (quotient << rice) | remainder;
                output[sample_index] = if (folded & 1 == 0)
                    @intCast(folded >> 1)
                else
                    -@as(i32, @intCast(folded >> 1)) - 1;
                sample_index += 1;
            }
        }
    }
}

fn restoreFixed(output: []i32, order: u6) Error!void {
    for (output[order..], order..) |*sample, index| {
        const prediction: i64 = switch (order) {
            0 => 0,
            1 => output[index - 1],
            2 => 2 * @as(i64, output[index - 1]) - output[index - 2],
            3 => 3 * @as(i64, output[index - 1]) - 3 * @as(i64, output[index - 2]) + output[index - 3],
            4 => 4 * @as(i64, output[index - 1]) - 6 * @as(i64, output[index - 2]) + 4 * @as(i64, output[index - 3]) - output[index - 4],
            else => unreachable,
        };
        try assignSample(sample, @as(i64, sample.*) + prediction);
    }
}

fn restoreStereo(channel_code: u4, left: []i32, right: []i32) Error!void {
    switch (channel_code) {
        8 => {
            for (left, right) |l, *r| try assignSample(r, @as(i64, l) - r.*);
        },
        9 => {
            for (left, right) |*l, r| try assignSample(l, @as(i64, l.*) + r);
        },
        10 => {
            for (left, right) |*mid, *side| {
                const expanded_mid = (@as(i64, mid.*) << 1) | @as(i64, @intCast(@as(u32, @bitCast(side.*)) & 1));
                const left_sample = (expanded_mid + side.*) >> 1;
                const right_sample = (expanded_mid - side.*) >> 1;
                try assignSample(mid, left_sample);
                try assignSample(side, right_sample);
            }
        },
        else => {},
    }
}

fn assignSample(target: *i32, value: i64) Error!void {
    if (value < minimum_i32 or value > maximum_i32) return error.InvalidSubframe;
    target.* = @intCast(value);
}

fn decodeBlockSize(bits: *BitReader, code: u4) Error!u16 {
    return switch (code) {
        1 => 192,
        2...5 => @as(u16, 144) << @intCast(code),
        6 => @as(u16, @intCast(try bits.read(8))) + 1,
        7 => blk: {
            const stored = try bits.read(16);
            if (stored == 0xffff) return error.InvalidFrame;
            break :blk @as(u16, @intCast(stored)) + 1;
        },
        8...15 => @as(u16, 1) << @intCast(code),
        else => return error.InvalidFrame,
    };
}

fn decodeSampleRate(bits: *BitReader, code: u4, stream_rate: u20) Error!u32 {
    const rate: u32 = switch (code) {
        0 => stream_rate,
        1 => 88_200,
        2 => 176_400,
        3 => 192_000,
        4 => 8_000,
        5 => 16_000,
        6 => 22_050,
        7 => 24_000,
        8 => 32_000,
        9 => 44_100,
        10 => 48_000,
        11 => 96_000,
        12 => (try bits.read(8)) * 1_000,
        13 => try bits.read(16),
        14 => (try bits.read(16)) * 10,
        else => return error.InvalidFrame,
    };
    if (rate == 0) return error.InvalidFrame;
    return rate;
}

fn decodeBitDepth(code: u3, stream_depth: u6) ?u6 {
    return switch (code) {
        0 => stream_depth,
        1 => 8,
        2 => 12,
        4 => 16,
        5 => 20,
        6 => 24,
        7 => 32,
        else => null,
    };
}

fn readCodedNumber(bits: *BitReader) Error!u36 {
    const first: u8 = @intCast(try bits.read(8));
    if (first & 0x80 == 0) return first;
    var count: u3 = 0;
    var marker: u8 = 0x80;
    while (first & marker != 0 and count < 7) : (marker >>= 1) count += 1;
    if (count < 2 or count > 7) return error.InvalidFrame;
    const first_payload_bits: u3 = @intCast(7 - count);
    var value: u64 = first & ((@as(u8, 1) << first_payload_bits) - 1);
    var index: u3 = 1;
    while (index < count) : (index += 1) {
        const byte = try bits.read(8);
        if (byte & 0xc0 != 0x80) return error.InvalidFrame;
        value = (value << 6) | (byte & 0x3f);
    }
    if (value > 0x0f_ffff_ffff) return error.InvalidFrame;
    return @intCast(value);
}

const BitReader = struct {
    input: []const u8,
    bit_position: usize,

    fn init(input: []const u8) BitReader {
        return .{ .input = input, .bit_position = 0 };
    }

    fn read(self: *BitReader, count: u6) Error!u32 {
        if (count > 32 or self.bit_position + count > self.input.len * 8) return error.Truncated;
        var value: u32 = 0;
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            const byte = self.input[self.bit_position / 8];
            const shift: u3 = @intCast(7 - (self.bit_position & 7));
            value = (value << 1) | ((byte >> shift) & 1);
            self.bit_position += 1;
        }
        return value;
    }

    fn readSigned(self: *BitReader, count: u6) Error!i32 {
        if (count == 0 or count > 32) return error.InvalidFrame;
        const unsigned = try self.read(count);
        if (count == 32) return @bitCast(unsigned);
        const sign = @as(u32, 1) << @intCast(count - 1);
        return if (unsigned & sign == 0)
            @intCast(unsigned)
        else
            @intCast(@as(i64, unsigned) - (@as(i64, 1) << @intCast(count)));
    }

    fn readUnary(self: *BitReader) Error!u32 {
        var zeros: u32 = 0;
        while (try self.read(1) == 0) {
            if (zeros == 0x7fff_ffff) return error.InvalidResidual;
            zeros += 1;
        }
        return zeros;
    }
};

fn crc8(input: []const u8) u8 {
    var crc: u8 = 0;
    for (input) |byte| {
        crc ^= byte;
        for (0..8) |_| crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
    }
    return crc;
}

fn crc16(input: []const u8) u16 {
    var crc: u16 = 0;
    for (input) |byte| {
        crc ^= @as(u16, byte) << 8;
        for (0..8) |_| crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x8005 else crc << 1;
    }
    return crc;
}

fn readBe16(input: *const [2]u8) u16 {
    return (@as(u16, input[0]) << 8) | input[1];
}

fn readBe24(input: *const [3]u8) u24 {
    return (@as(u24, input[0]) << 16) | (@as(u24, input[1]) << 8) | input[2];
}

fn readBe64(input: *const [8]u8) u64 {
    var value: u64 = 0;
    for (input) |byte| value = (value << 8) | byte;
    return value;
}

fn parseStreamInfoBlock(block: *const [stream_info_bytes]u8) Error!StreamInfo {
    const minimum_block_size = readBe16(block[0..2]);
    const maximum_block_size = readBe16(block[2..4]);
    if (minimum_block_size < 16 or maximum_block_size < minimum_block_size) {
        return error.InvalidMetadata;
    }
    const stream_fields = readBe64(block[10..18]);
    const channels: u4 = @intCast(((stream_fields >> 41) & 7) + 1);
    if (channels > 2) return error.UnsupportedChannels;
    return .{
        .minimum_block_size = minimum_block_size,
        .maximum_block_size = maximum_block_size,
        .minimum_frame_size = readBe24(block[4..7]),
        .maximum_frame_size = readBe24(block[7..10]),
        .sample_rate = @intCast(stream_fields >> 44),
        .channels = channels,
        .bits_per_sample = @intCast(((stream_fields >> 36) & 31) + 1),
        .total_samples = @intCast(stream_fields & 0x0f_ffff_ffff),
        .first_frame_offset = 0,
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

fn discardExact(reader: anytype, scratch: []u8, bytes: u24) !void {
    var remaining: usize = bytes;
    while (remaining != 0) {
        const count = @min(remaining, scratch.len);
        try readExact(reader, scratch[0..count]);
        remaining -= count;
    }
}

const flac_signature = "fLaC";
const minimum_file_bytes = 8;
const stream_info_bytes = 34;
const frame_sync_code = 0x7ffc;
const minimum_i32: i64 = -0x8000_0000;
const maximum_i32: i64 = 0x7fff_ffff;

test "decode verbatim subframe" {
    const encoded = [_]u8{ 0x02, 0x01, 0xfe, 0x7f, 0x80 };
    var bits = BitReader.init(&encoded);
    var output: [4]i32 = undefined;
    var coverage: Coverage = .{};
    try decodeSubframe(&bits, &output, 8, &coverage);
    try std.testing.expectEqualSlices(i32, &.{ 1, -2, 127, -128 }, &output);
    try std.testing.expect(coverage.subframe_types & (@as(u64, 1) << 1) != 0);
}

test "restore every fixed predictor order and LPC" {
    var order_zero = [_]i32{ 3, -4 };
    try restoreFixed(&order_zero, 0);
    try std.testing.expectEqualSlices(i32, &.{ 3, -4 }, &order_zero);
    var order_one = [_]i32{ 10, 1, 1 };
    try restoreFixed(&order_one, 1);
    try std.testing.expectEqualSlices(i32, &.{ 10, 11, 12 }, &order_one);
    var order_two = [_]i32{ 2, 5, 0, 0 };
    try restoreFixed(&order_two, 2);
    try std.testing.expectEqualSlices(i32, &.{ 2, 5, 8, 11 }, &order_two);
    var order_three = [_]i32{ 0, 1, 4, 0, 0 };
    try restoreFixed(&order_three, 3);
    try std.testing.expectEqualSlices(i32, &.{ 0, 1, 4, 9, 16 }, &order_three);
    var order_four = [_]i32{ 0, 1, 8, 27, 0, 0 };
    try restoreFixed(&order_four, 4);
    try std.testing.expectEqualSlices(i32, &.{ 0, 1, 8, 27, 64, 125 }, &order_four);
    var linear = [_]i32{ 2, 5, 0, 0 };
    try lpc.restore(&linear, 2, &.{ 2, -1 }, 0);
    try std.testing.expectEqualSlices(i32, &.{ 2, 5, 8, 11 }, &linear);
}

test "reject predictor and stereo reconstruction overflow" {
    var fixed = [_]i32{ maximum_i32, 1 };
    try std.testing.expectError(error.InvalidSubframe, restoreFixed(&fixed, 1));
    var linear = [_]i32{ maximum_i32, 1 };
    try std.testing.expectError(error.InvalidSubframe, lpc.restore(&linear, 1, &.{1}, 0));
    var left = [_]i32{maximum_i32};
    var right = [_]i32{-1};
    try std.testing.expectError(error.InvalidSubframe, restoreStereo(8, &left, &right));
}

test "decode Rice2 escaped partition" {
    const encoded = [_]u8{ 0x43, 0xe4, 0x1e, 0x78 };
    var bits = BitReader.init(&encoded);
    var output: [4]i32 = undefined;
    var coverage: Coverage = .{};
    try decodeResidual(&bits, &output, 0, &coverage);
    try std.testing.expectEqualSlices(i32, &.{ 1, -2, 7, -8 }, &output);
    try std.testing.expectEqual(@as(u2, 2), coverage.residual_methods);
    try std.testing.expect(coverage.saw_escape);
}
