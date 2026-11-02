//! Two-bank catalogue publication in an existing file. Header is committed last;
//! a failed new generation cannot invalidate the previous committed bank.
const std = @import("std");
const codec = @import("catalog_codec.zig");
const library = @import("library.zig");

pub const header_bytes = 512;

pub const Header = struct { generation: u64, length: u32, checksum: u32, source: u64, bank: u1 };

pub fn parseHeader(bytes: *const [header_bytes]u8, bank: u1, bank_bytes: u32) ?Header {
    if (!std.mem.eql(u8, bytes[0..4], "GCAT") or std.mem.readInt(u32, bytes[4..8], .little) != codec.schema or std.hash.Crc32.hash(bytes[0..508]) != std.mem.readInt(u32, bytes[508..512], .little)) return null;
    const length = std.mem.readInt(u32, bytes[16..20], .little);
    if (bank_bytes <= header_bytes or length == 0 or length > bank_bytes - header_bytes) return null;
    return .{
        .generation = std.mem.readInt(u64, bytes[8..16], .little),
        .length = length,
        .checksum = std.mem.readInt(u32, bytes[20..24], .little),
        .source = std.mem.readInt(u64, bytes[24..32], .little),
        .bank = bank,
    };
}

pub fn encodeHeader(header: Header, out: *[512]u8) void {
    @memset(out, 0);
    @memcpy(out[0..4], "GCAT");
    std.mem.writeInt(u32, out[4..8], codec.schema, .little);
    std.mem.writeInt(u64, out[8..16], header.generation, .little);
    std.mem.writeInt(u32, out[16..20], header.length, .little);
    std.mem.writeInt(u32, out[20..24], header.checksum, .little);
    std.mem.writeInt(u64, out[24..32], header.source, .little);
    std.mem.writeInt(u32, out[508..512], std.hash.Crc32.hash(out[0..508]), .little);
}

pub fn save(writer: anytype, catalog: *const library.Catalog, previous: ?Header, bank_bytes: u32, buffer: []u8) !Header {
    if (bank_bytes <= header_bytes or bank_bytes % 512 != 0 or buffer.len < 512 or buffer.len % 512 != 0) return error.InvalidAllocation;
    const bank: u1 = if (previous) |old| old.bank ^ 1 else 0;
    const base = 4096 + @as(u32, bank) * bank_bytes;
    try writer.seekTo(base + header_bytes);
    var stream = Buffered(@TypeOf(writer)).init(writer, buffer, bank_bytes - header_bytes);
    try codec.encode(&stream, catalog.*);
    try stream.finish();
    try writer.sync();
    const result = Header{ .generation = catalog.generation, .source = catalog.source, .length = stream.length, .checksum = stream.crc.final(), .bank = bank };
    const block: *[512]u8 = @ptrCast(buffer.ptr);
    encodeHeader(result, block);
    try writer.seekTo(base);
    try writer.write(block);
    try writer.sync();
    return result;
}

fn Buffered(comptime W: type) type {
    return struct {
        const Self = @This();
        writer: W,
        buffer: []u8,
        used: usize = 0,
        length: u32 = 0,
        limit: u32,
        crc: std.hash.Crc32 = std.hash.Crc32.init(),

        fn init(writer: W, buffer: []u8, limit: u32) Self {
            return .{ .writer = writer, .buffer = buffer, .limit = limit };
        }

        pub fn write(self: *Self, input: []const u8) !void {
            if (input.len > self.limit - self.length) return error.CatalogueTooLarge;
            self.crc.update(input);
            self.length += @intCast(input.len);
            var done: usize = 0;
            while (done < input.len) {
                const n = @min(input.len - done, self.buffer.len - self.used);
                @memcpy(self.buffer[self.used..][0..n], input[done..][0..n]);
                done += n;
                self.used += n;
                if (self.used == self.buffer.len) {
                    try self.writer.write(self.buffer);
                    self.used = 0;
                }
            }
        }

        fn finish(self: *Self) !void {
            if (self.used == 0) return;
            const n = (self.used + 511) & ~@as(usize, 511);
            @memset(self.buffer[self.used..n], 0);
            try self.writer.write(self.buffer[0..n]);
            self.used = 0;
        }
    };
}

const TestDisk = struct {
    bytes: [4096 + 8192]u8 = @splat(0),
    position: usize = 0,
    operation: usize = 0,
    fail_at: ?usize = null,
    tear: usize = 0,

    fn seekTo(self: *@This(), at: u32) !void {
        if (at > self.bytes.len) return error.OutOfBounds;
        self.position = at;
    }

    fn write(self: *@This(), data: []const u8) !void {
        if (self.position + data.len > self.bytes.len) return error.OutOfBounds;
        defer self.operation += 1;
        if (self.fail_at == self.operation) {
            const n = @min(self.tear, data.len);
            @memcpy(self.bytes[self.position..][0..n], data[0..n]);
            return error.PowerLoss;
        }
        @memcpy(self.bytes[self.position..][0..data.len], data);
        self.position += data.len;
    }

    fn sync(self: *@This()) !void {
        defer self.operation += 1;
        if (self.fail_at == self.operation) return error.PowerLoss;
    }

    fn valid(self: *@This(), bank: u1) ?Header {
        const at: usize = 4096 + @as(usize, bank) * 4096;
        const h = parseHeader(self.bytes[at..][0..512], bank, 4096) orelse return null;
        if (std.hash.Crc32.hash(self.bytes[at + 512 ..][0..h.length]) != h.checksum) return null;
        return h;
    }
};

test "every interrupted publication preserves the previous catalogue bank" {
    var original: TestDisk = .{};
    var buffer: [1024]u8 align(4) = undefined;
    var catalog = library.Catalog{ .source = 17, .generation = 1 };
    const before = try save(&original, &catalog, null, 4096, &buffer);
    try std.testing.expectEqual(1, original.valid(0).?.generation);
    const protected = original.bytes[4096..8192].*;
    catalog.generation = 2;
    var successful = original;
    successful.operation = 0;
    _ = try save(&successful, &catalog, before, 4096, &buffer);
    try std.testing.expectEqual(2, successful.valid(1).?.generation);
    for (0..successful.operation) |fail| for ([_]usize{ 0, 1, 17, 256, 511 }) |tear| {
        var disk = original;
        disk.operation = 0;
        disk.fail_at = fail;
        disk.tear = tear;
        try std.testing.expectError(error.PowerLoss, save(&disk, &catalog, before, 4096, &buffer));
        try std.testing.expectEqualSlices(u8, &protected, disk.bytes[4096..8192]);
        try std.testing.expectEqual(1, disk.valid(0).?.generation);
        if (disk.valid(1)) |next| try std.testing.expectEqual(2, next.generation);
    };
}

test "catalogue publication rejects malformed allocations and corrupt payloads" {
    var disk: TestDisk = .{};
    var buffer: [1024]u8 align(4) = undefined;
    const catalog = library.Catalog{ .source = 18, .generation = 1 };
    try std.testing.expectError(error.InvalidAllocation, save(&disk, &catalog, null, 512, &buffer));
    try std.testing.expectError(error.InvalidAllocation, save(&disk, &catalog, null, 4096, buffer[0..511]));
    _ = try save(&disk, &catalog, null, 4096, &buffer);
    disk.bytes[4096 + 512 + 1] ^= 1;
    try std.testing.expect(disk.valid(0) == null);
    const header: *[512]u8 = disk.bytes[4096..][0..512];
    for (0..512) |i| {
        header[i] ^= 1;
        try std.testing.expect(parseHeader(header, 0, 4096) == null);
        header[i] ^= 1;
    }
}
