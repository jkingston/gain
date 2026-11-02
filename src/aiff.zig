//! AIFF / uncompressed AIFF-C. Apple AIFF-C specification, 1991-08-26.
//! Input is left at the first sample. SSND before COMM requires seekTo(u32).
const std = @import("std");
const pcm = @import("pcm.zig");

pub const Info = struct { plan: pcm.Plan, data_offset: u32, data_bytes: u32 };
pub const Error = error{ NotAiff, Truncated, InvalidChunk, InvalidFormat, MissingFormat, MissingData, MissingVersion, UnsupportedCompression, UnsupportedRate, SeekRequired };

pub fn parse(reader: anytype) !Info {
    var header: [12]u8 = undefined;
    try exact(reader, &header);
    const compressed = std.mem.eql(u8, header[8..12], "AIFC");
    if (!std.mem.eql(u8, header[0..4], "FORM") or (!compressed and !std.mem.eql(u8, header[8..12], "AIFF"))) return error.NotAiff;
    const form_bytes = be(u32, header[4..8]);
    if (form_bytes < 4) return error.InvalidChunk;
    const limit: u64 = @as(u64, form_bytes) + 8;
    var position: u64 = 12;
    var plan: ?pcm.Plan = null;
    var audio: ?struct { offset: u32, bytes: u32 } = null;
    var version = !compressed;
    while (position + 8 <= limit) {
        var chunk: [8]u8 = undefined;
        try exact(reader, &chunk);
        position += 8;
        const size = be(u32, chunk[4..8]);
        const end = position + size;
        const padded = end + (size & 1);
        if (padded > limit or padded > std.math.maxInt(u32)) return error.InvalidChunk;
        var consumed: u32 = 0;
        if (std.mem.eql(u8, chunk[0..4], "COMM")) {
            if (plan != null or size < (if (compressed) @as(u32, 24) else 18)) return error.InvalidFormat;
            var common: [22]u8 = undefined;
            consumed = if (compressed) 22 else 18;
            try exact(reader, common[0..consumed]);
            const bits = be(u16, common[6..8]);
            if (bits == 0 or bits > 64) return error.InvalidFormat;
            var format = pcm.Sample.Format{ .bytes = @intCast((@as(u32, bits) + 7) / 8), .valid_bits = @intCast(bits), .endian = .big };
            if (compressed) {
                const code = common[18..22];
                if (std.mem.eql(u8, code, "sowt")) format.endian = .little else if (std.mem.eql(u8, code, "fl32") or std.mem.eql(u8, code, "FL32")) {
                    if (bits != 32) return error.InvalidFormat;
                    format.encoding = .float;
                } else if (std.mem.eql(u8, code, "fl64") or std.mem.eql(u8, code, "FL64")) {
                    if (bits != 64) return error.InvalidFormat;
                    format.encoding = .float;
                } else if (!std.mem.eql(u8, code, "NONE") and !std.mem.eql(u8, code, "twos")) return error.UnsupportedCompression;
                // Validate the even-sized Pascal compression-name field.
                var length: [1]u8 = undefined;
                try exact(reader, &length);
                consumed += 1;
                const name_size: u32 = (1 + @as(u32, length[0]) + 1) & ~@as(u32, 1);
                if (22 + name_size > size) return error.InvalidFormat;
            }
            plan = try pcm.Plan.fromFormat(try sampleRate(common[8..18]), be(u16, common[0..2]), format, be(u32, common[2..6]));
        } else if (std.mem.eql(u8, chunk[0..4], "FVER")) {
            if (!compressed or size != 4 or version) return error.InvalidFormat;
            var value: [4]u8 = undefined;
            try exact(reader, &value);
            consumed = 4;
            if (be(u32, &value) != 0xa2805140) return error.InvalidFormat;
            version = true;
        } else if (std.mem.eql(u8, chunk[0..4], "SSND")) {
            if (audio != null or size < 8) return error.InvalidChunk;
            var sound: [8]u8 = undefined;
            try exact(reader, &sound);
            consumed = 8;
            const offset = be(u32, sound[0..4]);
            if (offset > size - 8 or position + 8 + offset > std.math.maxInt(u32)) return error.InvalidChunk;
            audio = .{ .offset = @intCast(position + 8 + offset), .bytes = size - 8 - offset };
            if (plan != null and version) {
                try discard(reader, offset);
                return validate(plan.?, audio.?.offset, audio.?.bytes);
            }
        }
        // Seekable storage skips large unknown/data chunks without reading them.
        if (comptime @hasDecl(@TypeOf(reader.*), "seekTo")) try reader.seekTo(@intCast(padded)) else try discard(reader, @intCast(padded - position - consumed));
        position = padded;
        if (plan != null and audio != null and version) break;
    }
    if (!version) return error.MissingVersion;
    const parsed = plan orelse return error.MissingFormat;
    const data = audio orelse return error.MissingData;
    const info = try validate(parsed, data.offset, data.bytes);
    if (comptime @hasDecl(@TypeOf(reader.*), "seekTo")) try reader.seekTo(data.offset) else return error.SeekRequired;
    return info;
}

fn validate(plan: pcm.Plan, offset: u32, bytes: u32) !Info {
    if (@as(u64, plan.frames) * plan.sourceBytesPerFrame() > bytes) return error.Truncated;
    return .{ .plan = plan, .data_offset = offset, .data_bytes = bytes };
}

fn sampleRate(bytes: []const u8) Error!u32 {
    const sign_exponent = be(u16, bytes[0..2]);
    const exponent: i32 = @as(i32, sign_exponent) - 16383;
    const mantissa = be(u64, bytes[2..10]);
    // Reject signs, fractions and non-canonical extended encodings rather than
    // silently playing at a rounded, incorrect rate.
    if (exponent < 0 or exponent > 18 or mantissa >> 63 != 1) return error.UnsupportedRate;
    const shift: u6 = @intCast(63 - exponent);
    if (mantissa & ((@as(u64, 1) << shift) - 1) != 0) return error.UnsupportedRate;
    const hz = mantissa >> shift;
    if (hz == 0 or hz > 384000) return error.UnsupportedRate;
    return @intCast(hz);
}

fn be(comptime T: type, bytes: []const u8) T {
    var value: T = 0;
    for (bytes) |byte| value = (value << 8) | byte;
    return value;
}

fn exact(reader: anytype, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try reader.read(bytes[offset..]);
        if (count == 0) return error.Truncated;
        offset += count;
    }
}

fn discard(reader: anytype, count: u32) !void {
    var scratch: [512]u8 = undefined;
    var remaining = count;
    while (remaining != 0) {
        const size = @min(remaining, scratch.len);
        try exact(reader, scratch[0..size]);
        remaining -= @intCast(size);
    }
}

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn read(self: *@This(), bytes: []u8) !usize {
        const count = @min(@as(usize, 3), @min(bytes.len, self.bytes.len - self.position));
        @memcpy(bytes[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }

    pub fn seekTo(self: *@This(), target: u32) !void {
        if (target > self.bytes.len) return error.Truncated;
        self.position = target;
    }
};

const fixture = "FORM" ++ "\x00\x00\x00\x32" ++ "AIFF" ++ "COMM" ++ "\x00\x00\x00\x12" ++ "\x00\x01\x00\x00\x00\x02\x00\x10" ++ "\x40\x0e\xac\x44\x00\x00\x00\x00\x00\x00" ++ "SSND" ++ "\x00\x00\x00\x0c" ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x7f\xff\x80\x00";

test "AIFF choppy reads convert mono big endian to exact stereo DMA samples" {
    var reader = Reader{ .bytes = fixture };
    const info = try parse(&reader);
    try std.testing.expectEqual(@as(u32, 44100), info.plan.sample_rate);
    var stream = pcm.Stream(Reader).fromPlan(&reader, info.plan);
    var output: [12]u8 = undefined;
    const fill = try stream.fill(&output);
    try std.testing.expect(fill.end and fill.frames == 2);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x7f, 0xff, 0x7f, 0, 0x80, 0, 0x80, 0, 0, 0, 0 }, &output);
}

test "AIFF accepts SSND before COMM and seeks back to its first sample" {
    var file: [fixture.len]u8 = undefined;
    @memcpy(file[0..12], fixture[0..12]);
    @memcpy(file[12..32], fixture[38..58]);
    @memcpy(file[32..58], fixture[12..38]);
    var reader = Reader{ .bytes = &file };
    const info = try parse(&reader);
    try std.testing.expectEqual(@as(u32, 32 - 4), info.data_offset);
    try std.testing.expectEqual(@as(usize, info.data_offset), reader.position);
}

test "every AIFF truncation is rejected and malformed rates never round" {
    for (0..fixture.len) |length| {
        var reader = Reader{ .bytes = fixture[0..length] };
        if (parse(&reader)) |info| {
            var stream = pcm.Stream(Reader).fromPlan(&reader, info.plan);
            var output: [8]u8 = undefined;
            try std.testing.expectError(error.Truncated, stream.fill(&output));
        } else |_| {}
    }
    try std.testing.expectError(error.UnsupportedRate, sampleRate(&.{ 0x40, 0x0e, 0xac, 0x44, 0, 0, 0, 0, 0, 1 }));
}

test "AIFF-C integer and IEEE float modes enforce version, compression and precision" {
    for ([_][]const u8{ "NONE", "twos", "sowt", "fl32", "fl64" }) |compression| {
        var file: [80]u8 = @splat(0);
        const double = std.mem.eql(u8, compression, "fl64");
        const floating = compression[0] == 'f';
        const sample_bytes: u32 = if (double) 8 else if (floating) 4 else 2;
        const length = 72 + sample_bytes;
        @memcpy(file[0..4], "FORM");
        std.mem.writeInt(u32, file[4..8], length - 8, .big);
        @memcpy(file[8..16], "AIFCFVER");
        std.mem.writeInt(u32, file[16..20], 4, .big);
        std.mem.writeInt(u32, file[20..24], 0xa2805140, .big);
        @memcpy(file[24..28], "COMM");
        std.mem.writeInt(u32, file[28..32], 24, .big);
        std.mem.writeInt(u16, file[32..34], 1, .big);
        std.mem.writeInt(u32, file[34..38], 1, .big);
        std.mem.writeInt(u16, file[38..40], @intCast(sample_bytes * 8), .big);
        @memcpy(file[40..50], "\x40\x0e\xbb\x80\x00\x00\x00\x00\x00\x00");
        @memcpy(file[50..54], compression);
        @memcpy(file[56..60], "SSND");
        std.mem.writeInt(u32, file[60..64], sample_bytes + 8, .big);
        if (double) std.mem.writeInt(u64, file[72..80], @bitCast(@as(f64, 0.5)), .big) else if (floating) std.mem.writeInt(u32, file[72..76], @bitCast(@as(f32, 0.5)), .big) else if (std.mem.eql(u8, compression, "sowt")) {
            @memcpy(file[72..74], &[_]u8{ 0, 0x40 });
        } else @memcpy(file[72..74], &[_]u8{ 0x40, 0 });
        var reader = Reader{ .bytes = file[0..length] };
        const info = try parse(&reader);
        try std.testing.expectEqual(@as(u32, 48000), info.plan.sample_rate);
        var stream = pcm.Stream(Reader).fromPlan(&reader, info.plan);
        var output: [8]u8 = undefined;
        _ = try stream.fill(&output);
        if (floating) {
            const left = std.mem.readInt(u32, output[0..4], .little);
            try std.testing.expect(left >= 4194303 and left <= 4194305);
            try std.testing.expectEqualSlices(u8, output[0..4], output[4..8]);
        } else try std.testing.expectEqualSlices(u8, &.{ 0, 0x40, 0, 0x40, 0, 0, 0, 0 }, &output);
        file[20] = 0;
        reader = .{ .bytes = file[0..length] };
        try std.testing.expectError(error.InvalidFormat, parse(&reader));
    }
}
