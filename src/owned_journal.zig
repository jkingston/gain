//! Two payload banks for bounded, host-provisioned user state. The caller owns
//! schema validation and snapshot memory. Every card transaction uses the DMA
//! bounce; an interrupted payload cannot replace the previous committed bank.
const std = @import("std");
const managed = @import("managed_file.zig");

pub fn Journal(comptime magic: [4]u8, comptime bank_bytes: u32) type {
    return struct {
        const Self = @This();
        origin: u32 = managed.prefix_bytes,
        bank: u1 = 1,
        generation: u32 = 0,
        committed: bool = false,

        pub const allocation_bytes = managed.prefix_bytes + bank_bytes * 2;

        fn offset(self: Self, bank: u1) u32 {
            return self.origin + @as(u32, bank) * bank_bytes;
        }

        fn newer(a: u32, b: u32) bool {
            const delta = a -% b;
            return delta != 0 and delta < 0x80000000;
        }

        pub fn load(self: *Self, reader: anytype, source: u64, scratch: []u8, block: *[512]u8, validator: anytype) !?[]const u8 {
            self.* = .{ .origin = self.origin };
            const Header = struct { generation: u32, length: u32, crc: u32 };
            var headers: [2]?Header = .{ null, null };
            for (0..2) |i| {
                try reader.seekTo(self.offset(@intCast(i)));
                if (try reader.read(block) != block.len) return error.TruncatedUserState;
                if (!std.mem.eql(u8, block[0..4], &magic) or std.mem.readInt(u32, block[4..8], .little) != 1 or std.hash.Crc32.hash(block[0..508]) != std.mem.readInt(u32, block[508..512], .little) or std.mem.readInt(u64, block[24..32], .little) != source) continue;
                const length = std.mem.readInt(u32, block[12..16], .little);
                if (length == 0 or length > bank_bytes - 512 or length > scratch.len) continue;
                headers[i] = .{ .generation = std.mem.readInt(u32, block[8..12], .little), .length = length, .crc = std.mem.readInt(u32, block[16..20], .little) };
            }
            const first: u1 = if (headers[1] != null and (headers[0] == null or newer(headers[1].?.generation, headers[0].?.generation))) 1 else 0;
            for ([_]u1{ first, first ^ 1 }) |bank| {
                const header = headers[bank] orelse continue;
                try reader.seekTo(self.offset(bank) + 512);
                var consumed: usize = 0;
                while (consumed < header.length) {
                    if (try reader.read(block) != block.len) return error.TruncatedUserState;
                    const amount = @min(block.len, header.length - consumed);
                    @memcpy(scratch[consumed..][0..amount], block[0..amount]);
                    consumed += amount;
                }
                const payload = scratch[0..header.length];
                if (std.hash.Crc32.hash(payload) != header.crc or !validator.valid(payload, source)) continue;
                self.bank = bank;
                self.generation = header.generation;
                self.committed = true;
                return payload;
            }
            return null;
        }

        pub fn save(self: *Self, writer: anytype, source: u64, payload: []const u8, block: *[512]u8) !void {
            if (payload.len == 0 or payload.len > bank_bytes - 512) return error.UserStateCapacity;
            const bank = self.bank ^ 1;
            const generation = self.generation +% 1;
            const crc = std.hash.Crc32.hash(payload);
            try writer.seekTo(self.offset(bank) + 512);
            var consumed: usize = 0;
            while (consumed < payload.len) {
                @memset(block, 0);
                const amount = @min(block.len, payload.len - consumed);
                @memcpy(block[0..amount], payload[consumed..][0..amount]);
                try writer.write(block);
                consumed += amount;
            }
            try writer.sync();
            @memset(block, 0);
            @memcpy(block[0..4], &magic);
            std.mem.writeInt(u32, block[4..8], 1, .little);
            std.mem.writeInt(u32, block[8..12], generation, .little);
            std.mem.writeInt(u32, block[12..16], @intCast(payload.len), .little);
            std.mem.writeInt(u32, block[16..20], crc, .little);
            std.mem.writeInt(u64, block[24..32], source, .little);
            std.mem.writeInt(u32, block[508..512], std.hash.Crc32.hash(block[0..508]), .little);
            try writer.seekTo(self.offset(bank));
            try writer.write(block);
            try writer.sync();
            self.bank = bank;
            self.generation = generation;
            self.committed = true;
        }
    };
}

const Memory = struct {
    bytes: []u8,
    dma: *[512]u8,
    at: usize = 0,
    remaining: usize = std.math.maxInt(usize),

    pub fn seekTo(self: *Memory, at: u32) !void {
        if (at > self.bytes.len) return error.Bounds;
        self.at = at;
    }

    pub fn read(self: *Memory, output: []u8) !usize {
        if (output.ptr != @as([*]u8, @ptrCast(self.dma)) or output.len != 512) return error.CachedDmaBuffer;
        @memcpy(output, self.bytes[self.at..][0..output.len]);
        self.at += output.len;
        return output.len;
    }

    pub fn write(self: *Memory, bytes: []const u8) !void {
        if (bytes.ptr != @as([*]const u8, @ptrCast(self.dma)) or bytes.len != 512) return error.CachedDmaBuffer;
        const amount = @min(bytes.len, self.remaining);
        @memcpy(self.bytes[self.at..][0..amount], bytes[0..amount]);
        self.at += amount;
        self.remaining -= amount;
        if (amount != bytes.len) return error.Interrupted;
    }

    pub fn sync(_: *Memory) !void {}
};

test "owned journals retain committed payload through every torn header and enforce DMA/source/schema" {
    const Test = Journal("GUTS".*, 4096);
    const a = std.testing.allocator;
    const card = try a.alloc(u8, Test.allocation_bytes);
    defer a.free(card);
    @memset(card, 0);
    var block: [512]u8 = undefined;
    var reader_buffer: [2048]u8 = undefined;
    var old: [1024]u8 = @splat(17);
    var replacement: [2048]u8 = @splat(21);
    var memory = Memory{ .bytes = card, .dma = &block };
    var journal = Test{};
    const Validator = struct {
        pub fn valid(_: @This(), bytes: []const u8, _: u64) bool {
            return bytes[0] == 17 or bytes[0] == 21;
        }
    };
    try journal.save(&memory, 7, &old, &block);
    const baseline = try a.dupe(u8, card);
    defer a.free(baseline);
    for (0..512) |cut| {
        @memcpy(card, baseline);
        memory = .{ .bytes = card, .dma = &block, .remaining = replacement.len + cut };
        var interrupted = journal;
        try std.testing.expectError(error.Interrupted, interrupted.save(&memory, 7, &replacement, &block));
        var reader = Test{};
        try std.testing.expectEqualSlices(u8, &old, (try reader.load(&memory, 7, &reader_buffer, &block, Validator{})).?);
    }
    for (0..4) |cut| {
        @memcpy(card, baseline);
        memory = .{ .bytes = card, .dma = &block, .remaining = cut * 512 };
        var interrupted = journal;
        try std.testing.expectError(error.Interrupted, interrupted.save(&memory, 7, &replacement, &block));
        var reader = Test{};
        try std.testing.expectEqualSlices(u8, &old, (try reader.load(&memory, 7, &reader_buffer, &block, Validator{})).?);
    }
    @memcpy(card, baseline);
    memory = .{ .bytes = card, .dma = &block };
    try journal.save(&memory, 7, &replacement, &block);
    var reader = Test{};
    try std.testing.expectEqualSlices(u8, &replacement, (try reader.load(&memory, 7, &reader_buffer, &block, Validator{})).?);
    try std.testing.expect((try reader.load(&memory, 8, &reader_buffer, &block, Validator{})) == null);
}
