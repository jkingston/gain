pub const Encoding = enum {
    pcm_integer,
    ieee_float,
};

pub const Info = struct {
    encoding: Encoding,
    channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
    valid_bits_per_sample: u16,
    channel_mask: u32,
    data_offset: u32,
    data_bytes: u32,
};

pub const Error = error{
    Truncated,
    NotWave,
    MissingFormat,
    MissingData,
    UnsupportedFormat,
    InvalidFormat,
    InvalidChunk,
};

/// Parses RIFF/WAVE from the reader's current position and leaves it at the
/// first audio byte. The reader needs only `read([]u8) !usize`.
pub fn parse(reader: anytype) !Info {
    var header: [12]u8 = undefined;
    try readExact(reader, &header);
    if (!equal(header[0..4], "RIFF") or !equal(header[8..12], "WAVE")) return error.NotWave;

    const riff_bytes = read32(&header, 4);
    if (riff_bytes < 4) return error.InvalidChunk;
    var remaining: u64 = riff_bytes - 4;
    var position: u64 = 12;
    var format: ?Format = null;

    while (remaining >= 8) {
        var chunk_header: [8]u8 = undefined;
        try readExact(reader, &chunk_header);
        remaining -= 8;
        position += 8;
        const chunk_bytes = read32(&chunk_header, 4);
        if (chunk_bytes > remaining) return error.InvalidChunk;

        if (equal(chunk_header[0..4], "fmt ")) {
            format = try parseFormat(reader, chunk_bytes);
        } else if (equal(chunk_header[0..4], "data")) {
            const parsed = format orelse return error.MissingFormat;
            if (position > maximum_u32) return error.InvalidChunk;
            return parsed.info(@intCast(position), chunk_bytes);
        } else {
            try discard(reader, chunk_bytes);
        }
        remaining -= chunk_bytes;
        position += chunk_bytes;

        if (chunk_bytes & 1 != 0) {
            if (remaining == 0) return error.InvalidChunk;
            var padding: [1]u8 = undefined;
            try readExact(reader, &padding);
            remaining -= 1;
            position += 1;
        }
    }
    return error.MissingData;
}

const Format = struct {
    encoding: Encoding,
    channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
    valid_bits_per_sample: u16,
    channel_mask: u32,

    fn info(self: Format, data_offset: u32, data_bytes: u32) Error!Info {
        if (self.channels == 0 or self.sample_rate == 0 or self.bits_per_sample == 0 or
            self.block_align == 0 or self.valid_bits_per_sample == 0 or
            self.valid_bits_per_sample > self.bits_per_sample)
        {
            return error.InvalidFormat;
        }
        const expected_alignment = (@as(u32, self.channels) * self.bits_per_sample + 7) / 8;
        if (expected_alignment != self.block_align or
            @as(u64, self.sample_rate) * self.block_align != self.byte_rate or
            data_bytes % self.block_align != 0)
        {
            return error.InvalidFormat;
        }
        return .{
            .encoding = self.encoding,
            .channels = self.channels,
            .sample_rate = self.sample_rate,
            .byte_rate = self.byte_rate,
            .block_align = self.block_align,
            .bits_per_sample = self.bits_per_sample,
            .valid_bits_per_sample = self.valid_bits_per_sample,
            .channel_mask = self.channel_mask,
            .data_offset = data_offset,
            .data_bytes = data_bytes,
        };
    }
};

fn parseFormat(reader: anytype, chunk_bytes: u32) !Format {
    if (chunk_bytes < 16) return error.InvalidFormat;
    var bytes: [40]u8 = @splat(0);
    const kept = @min(@as(usize, chunk_bytes), bytes.len);
    try readExact(reader, bytes[0..kept]);
    if (chunk_bytes > kept) try discard(reader, chunk_bytes - @as(u32, @intCast(kept)));

    const tag = read16(&bytes, 0);
    const channels = read16(&bytes, 2);
    const sample_rate = read32(&bytes, 4);
    const byte_rate = read32(&bytes, 8);
    const block_align = read16(&bytes, 12);
    const bits_per_sample = read16(&bytes, 14);

    var encoding: Encoding = undefined;
    var valid_bits = bits_per_sample;
    var channel_mask: u32 = 0;
    switch (tag) {
        wave_format_pcm => encoding = .pcm_integer,
        wave_format_ieee_float => encoding = .ieee_float,
        wave_format_extensible => {
            if (chunk_bytes < 40 or read16(&bytes, 16) < 22 or !standardSubformatGuid(bytes[24..40])) {
                return error.InvalidFormat;
            }
            valid_bits = read16(&bytes, 18);
            channel_mask = read32(&bytes, 20);
            encoding = switch (read16(&bytes, 24)) {
                wave_format_pcm => .pcm_integer,
                wave_format_ieee_float => .ieee_float,
                else => return error.UnsupportedFormat,
            };
        },
        else => return error.UnsupportedFormat,
    }
    return .{
        .encoding = encoding,
        .channels = channels,
        .sample_rate = sample_rate,
        .byte_rate = byte_rate,
        .block_align = block_align,
        .bits_per_sample = bits_per_sample,
        .valid_bits_per_sample = valid_bits,
        .channel_mask = channel_mask,
    };
}

fn standardSubformatGuid(bytes: []const u8) bool {
    const tail = [_]u8{ 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 };
    return bytes[2] == 0 and bytes[3] == 0 and equal(bytes[4..16], &tail);
}

fn readExact(reader: anytype, output: []u8) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        const count = try reader.read(output[offset..]);
        if (count == 0) return error.Truncated;
        offset += count;
    }
}

fn discard(reader: anytype, count: u32) !void {
    var buffer: [64]u8 = undefined;
    var remaining = count;
    while (remaining != 0) {
        const amount = @min(@as(usize, remaining), buffer.len);
        try readExact(reader, buffer[0..amount]);
        remaining -= @intCast(amount);
    }
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | @as(u16, bytes[offset + 1]) << 8;
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        @as(u32, bytes[offset + 1]) << 8 |
        @as(u32, bytes[offset + 2]) << 16 |
        @as(u32, bytes[offset + 3]) << 24;
}

const wave_format_pcm = 0x0001;
const wave_format_ieee_float = 0x0003;
const wave_format_extensible = 0xfffe;
const maximum_u32 = 0xffff_ffff;
