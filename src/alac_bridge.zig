//! Zig adapter for the pinned Apple ALAC decoder's non-virtual Itanium C++ ABI.
//! Upstream sources stay unchanged. Each audio element is checked before calling
//! Decode, which stops after that element's channels in the upstream release build.
const std = @import("std");
const types = @import("c_alac_types");
const bits_abi = @import("c_alac_bits");

const Error = error{ DecoderInit, DecodeFailed };
const maximum_frames = 4096;

const Core = extern struct {
    config: types.ALACSpecificConfig,
    active_elements: u16,
    mix_u: ?[*]i32,
    mix_v: ?[*]i32,
    predictor: ?[*]i32,
    shifted: ?[*]u16,
};

const construct = @extern(*const fn (*Core) callconv(.c) void, .{ .name = "_ZN11ALACDecoderC1Ev" });
const destroy = @extern(*const fn (*Core) callconv(.c) void, .{ .name = "_ZN11ALACDecoderD1Ev" });
const initialize = @extern(*const fn (*Core, *anyopaque, u32) callconv(.c) i32, .{ .name = "_ZN11ALACDecoder4InitEPvj" });
const decodeElement = @extern(*const fn (*Core, *bits_abi.BitBuffer, [*]u8, u32, u32, *u32) callconv(.c) i32, .{
    .name = "_ZN11ALACDecoder6DecodeEP9BitBufferPhjjPj",
});

comptime {
    // ALACDecoder has no bases or virtual functions. These layouts are also
    // checked against Clang's record layout for the pinned upstream header.
    const pointer_bytes = @sizeOf(usize);
    if (@sizeOf(types.ALACSpecificConfig) != 24 or @offsetOf(Core, "mix_u") != (if (pointer_bytes == 4) @as(usize, 28) else 32) or @sizeOf(Core) != (if (pointer_bytes == 4) @as(usize, 44) else 64)) @compileError("Unsupported ALAC C++ ABI");
}

pub const Decoder = struct {
    core: Core,
    bytes: [maximum_frames * 2 * 3]u8 align(4) = undefined,

    pub fn init(configuration: []const u8) Error!Decoder {
        if (configuration.len != 24 or configuration[9] < 1 or configuration[9] > 2 or (configuration[5] != 16 and configuration[5] != 24)) return error.DecoderInit;
        const frames = std.mem.readInt(u32, configuration[0..4], .big);
        if (frames == 0 or frames > maximum_frames) return error.DecoderInit;
        var self: Decoder = undefined;
        construct(&self.core);
        errdefer destroy(&self.core);
        var cookie: [24]u8 align(4) = undefined;
        @memcpy(&cookie, configuration);
        if (initialize(&self.core, &cookie, cookie.len) != 0) return error.DecoderInit;
        return self;
    }

    pub fn deinit(self: *Decoder) void {
        destroy(&self.core);
        self.* = undefined;
    }

    pub fn decode(self: *Decoder, input: []const u8, output: []f32) Error!usize {
        const channels = self.core.config.numChannels;
        if (self.core.config.frameLength * channels > output.len) return error.DecodeFailed;
        var cursor = Cursor{ .bytes = input };
        var channel: usize = 0;
        var frames: ?u32 = null;
        while (channel < channels) {
            const start = cursor.position;
            const tag = try cursor.read(3);
            switch (tag) {
                0, 1, 3 => {
                    const element_channels: u32 = if (tag == 1) 2 else 1;
                    if (element_channels > channels - channel) return error.DecodeFailed;
                    const count = try validateElement(&cursor, self.core.config, element_channels);
                    if (frames) |previous| if (previous != count) return error.DecodeFailed;
                    var bits = bits_abi.BitBuffer{
                        .cur = @constCast(input.ptr + start / 8),
                        .end = @constCast(input.ptr + input.len),
                        .bitIndex = @intCast(start % 8),
                        .byteSize = @intCast(input.len),
                    };

                    var decoded: u32 = 0;
                    if (decodeElement(&self.core, &bits, &self.bytes, self.core.config.frameLength, element_channels, &decoded) != 0 or decoded != count) return error.DecodeFailed;
                    const address = @intFromPtr(bits.cur);
                    if (address < @intFromPtr(input.ptr) or address > @intFromPtr(input.ptr) + input.len or bits.bitIndex > 7) return error.DecodeFailed;
                    cursor.position = (address - @intFromPtr(input.ptr)) * 8 + bits.bitIndex;
                    for (0..count) |frame| for (0..element_channels) |offset| {
                        const sample = frame * element_channels + offset;
                        output[frame * channels + channel + offset] = if (self.core.config.bitDepth == 16)
                            @as(f32, @floatFromInt(std.mem.readInt(i16, self.bytes[sample * 2 ..][0..2], .little))) / 32768.0
                        else
                            @as(f32, @floatFromInt(std.mem.readInt(i24, self.bytes[sample * 3 ..][0..3], .little))) / 8388608.0;
                    };
                    frames = count;
                    channel += element_channels;
                },
                4 => {
                    _ = try cursor.read(4); // Data stream instance tag.
                    const aligned = try cursor.read(1);
                    var bytes = try cursor.read(8);
                    if (bytes == 255) bytes += try cursor.read(8);
                    if (aligned != 0) try cursor.skip((8 - cursor.position % 8) % 8);
                    try cursor.skip(bytes * 8);
                },
                6 => {
                    var bytes = try cursor.read(4);
                    if (bytes == 15) bytes = 14 + try cursor.read(8);
                    try cursor.skip(bytes * 8);
                },
                else => return error.DecodeFailed,
            }
        }
        return frames orelse error.DecodeFailed;
    }
};

const Cursor = struct {
    bytes: []const u8,
    position: usize = 0,

    fn skip(self: *Cursor, count: usize) Error!void {
        if (self.position > self.bytes.len * 8 or count > self.bytes.len * 8 - self.position) return error.DecodeFailed;
        self.position += count;
    }

    fn read(self: *Cursor, count: u6) Error!u32 {
        if (count > 32) return error.DecodeFailed;
        const start = self.position;
        try self.skip(count);
        var value: u32 = 0;
        for (start..self.position) |bit| value = (value << 1) | ((self.bytes[bit / 8] >> @as(u3, @intCast(7 - bit % 8))) & 1);
        return value;
    }
};

fn validateElement(cursor: *Cursor, config: types.ALACSpecificConfig, channels: u32) Error!u32 {
    _ = try cursor.read(4); // Audio element instance tag.
    if (try cursor.read(12) != 0) return error.DecodeFailed;
    const partial = try cursor.read(1);
    const shifted = try cursor.read(2);
    const escape = try cursor.read(1);
    if (shifted == 3 or shifted * 8 >= config.bitDepth) return error.DecodeFailed;
    const frames = if (partial != 0) try cursor.read(32) else config.frameLength;
    if (frames == 0 or frames > config.frameLength) return error.DecodeFailed;
    if (escape != 0) {
        try cursor.skip(@as(usize, frames) * channels * config.bitDepth);
    } else {
        const mixing = try cursor.read(8);
        _ = try cursor.read(8);
        if (mixing > 31) return error.DecodeFailed;
        for (0..channels) |_| {
            _ = try cursor.read(8); // Predictor mode and denominator shift.
            const order = (try cursor.read(8)) & 31;
            // Order 31 is the delta mode; other orders prime order+1 samples.
            if (order != 31 and order >= frames) return error.DecodeFailed;
            try cursor.skip(order * 16);
        }
        try cursor.skip(@as(usize, frames) * channels * shifted * 8);
    }
    return frames;
}

// The upstream predictor computes 1 << (shift-1), including for shift=0.
// Dispatch those cases here before entering upstream C; all ordinary nonzero
// denominators keep the library's optimized 4/8-coefficient paths.
extern fn gain_upstream_unpc_block([*]i32, [*]i32, i32, ?[*]i16, i32, u32, u32) callconv(.c) void;

export fn unpc_block(input: [*]i32, output: [*]i32, count: i32, coefficients: ?[*]i16, order: i32, bits: u32, denominator: u32) void {
    if (count <= 0) return;
    const length: usize = @intCast(count);
    if (order == 0) {
        if (input != output) @memcpy(output[0..length], input[0..length]);
        return;
    }
    if (order != 31 and denominator != 0) {
        gain_upstream_unpc_block(input, output, count, coefficients, order, bits, denominator);
        return;
    }
    const shift: u5 = @intCast(32 - bits);
    output[0] = input[0];
    if (order == 31) {
        for (1..length) |i| output[i] = ((input[i] +% output[i - 1]) << shift) >> shift;
        return;
    }
    const active: usize = @intCast(order);
    const coefs = coefficients.?;
    for (1..@min(active + 1, length)) |i| output[i] = ((input[i] +% output[i - 1]) << shift) >> shift;
    for (@min(active + 1, length)..length) |i| {
        const top = output[i - active - 1];
        var sum: i32 = 0;
        for (0..active) |k| sum +%= @as(i32, coefs[k]) *% (output[i - k - 1] -% top);
        const residual = input[i];
        output[i] = ((residual +% top +% sum) << shift) >> shift;
        var remaining = residual;
        var k = active;
        while (k != 0 and residual != 0) {
            k -= 1;
            const difference = top -% output[i - k - 1];
            const sign: i32 = if (difference > 0) 1 else if (difference < 0) -1 else 0;
            const adjustment = if (residual > 0) sign else -sign;
            coefs[k] -%= @as(i16, @intCast(adjustment));
            remaining -%= @as(i32, @intCast(active - k)) *% (adjustment *% difference);
            if ((residual > 0 and remaining <= 0) or (residual < 0 and remaining >= 0)) break;
        }
    }
}

const PacketBuilder = struct {
    bytes: [256]u8 = @splat(0),
    position: usize = 0,

    fn write(self: *PacketBuilder, value: u32, width: u6) void {
        for (0..width) |bit| {
            const shift: u5 = @intCast(width - bit - 1);
            self.bytes[self.position / 8] |= @as(u8, @intCast((value >> shift) & 1)) << @as(u3, @intCast(7 - self.position % 8));
            self.position += 1;
        }
    }

    fn element(self: *PacketBuilder, tag: u3, frames: u32, samples: []const i16) void {
        self.write(tag, 3);
        self.write(0, 4);
        self.write(0, 12);
        self.write(1, 1); // Partial frame.
        self.write(0, 2);
        self.write(1, 1); // Uncompressed samples.
        self.write(frames, 32);
        for (samples) |sample| self.write(@as(u16, @bitCast(sample)), 16);
    }

    fn packet(self: *PacketBuilder) []const u8 {
        return self.bytes[0 .. (self.position + 7) / 8];
    }
};

fn testConfiguration(channels: u8) [24]u8 {
    var cookie: [24]u8 = @splat(0);
    std.mem.writeInt(u32, cookie[0..4], 4, .big);
    cookie[5] = 16;
    cookie[6] = 40;
    cookie[7] = 10;
    cookie[8] = 14;
    cookie[9] = channels;
    std.mem.writeInt(u32, cookie[20..24], 44100, .big);
    return cookie;
}

test "ALAC Zig checks reject zero and oversized partial frames before upstream decode" {
    var arena: [64 * 1024]u8 align(16) = undefined;
    var pool = try @import("codec_pool.zig").Pool.init(&arena);
    const binding = pool.bind();
    defer binding.end();
    const configuration = testConfiguration(2);
    var decoder = try Decoder.init(&configuration);
    defer decoder.deinit();
    var output: [8]f32 = @splat(123.0);
    for ([_]u32{ 0, 5, 0xffffffff }) |frames| {
        var builder = PacketBuilder{};
        builder.element(1, frames, &.{});
        try std.testing.expectError(error.DecodeFailed, decoder.decode(builder.packet(), &output));
        for (output) |sample| try std.testing.expectEqual(@as(f32, 123.0), sample);
    }
}

test "ALAC validates every element in two-mono stereo and skips metadata without losing alignment" {
    var arena: [64 * 1024]u8 align(16) = undefined;
    var pool = try @import("codec_pool.zig").Pool.init(&arena);
    const binding = pool.bind();
    defer binding.end();
    const configuration = testConfiguration(2);
    var decoder = try Decoder.init(&configuration);
    defer decoder.deinit();
    var builder = PacketBuilder{};
    builder.write(6, 3); // Extended fill length 15+0-1 = 14 bytes.
    builder.write(15, 4);
    builder.write(0, 8);
    for (0..14) |_| builder.write(0xff, 8);
    builder.write(4, 3); // Unaligned data stream element.
    builder.write(0, 4);
    builder.write(0, 1);
    builder.write(1, 8);
    builder.write(0x55, 8);
    builder.element(0, 4, &.{ -32768, -1, 0, 32767 });
    builder.element(0, 4, &.{ 32767, 0, -1, -32768 });
    builder.write(7, 3);
    var output: [8]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try decoder.decode(builder.packet(), &output));
    const expected = [_]i16{ -32768, 32767, -1, 0, 0, -1, 32767, -32768 };
    for (output, expected) |actual, sample| try std.testing.expectEqual(@as(f32, @floatFromInt(sample)) / 32768.0, actual);

    var invalid = PacketBuilder{};
    invalid.element(0, 4, &.{ 0, 0, 0, 0 });
    invalid.element(0, 5, &.{}); // Must check the second element too.
    try std.testing.expectError(error.DecodeFailed, decoder.decode(invalid.packet(), &output));
}

test "ALAC denominator-zero delta and predictor paths define wrapping arithmetic" {
    var input = [_]i32{ 32767, 1, -1, -32768, 1 };
    var output: [5]i32 = undefined;
    unpc_block(&input, &output, input.len, null, 31, 16, 0);
    try std.testing.expectEqualSlices(i32, &.{ 32767, -32768, 32767, -1, 0 }, &output);
    // In-place delta mode is used by the upstream decoder before prediction.
    unpc_block(&input, &input, input.len, null, 31, 16, 0);
    try std.testing.expectEqualSlices(i32, &output, &input);
    var residual = [_]i32{ 10, 1, 2, -3, 4 };
    var coefficients = [_]i16{1};
    unpc_block(&residual, &output, residual.len, &coefficients, 1, 16, 0);
    try std.testing.expectEqualSlices(i32, &.{ 10, 11, 13, 12, 16 }, &output);
    try std.testing.expectEqual(@as(i16, 0), coefficients[0]);
}
