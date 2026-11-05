//! Read-only MBR/GPT selection for 512-byte SD media. All arithmetic is widened
//! before narrowing to the controller's 32-bit LBA range (up to 2 TiB).
const std = @import("std");
pub const Partition = struct { start: u32, sectors: u32 };
const basic_data = [_]u8{ 0xa2, 0xa0, 0xd0, 0xeb, 0xe5, 0xb9, 0x33, 0x44, 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7 };
fn int(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

pub fn locate(device: anytype, scratch: *[512]u8) !Partition {
    try device.readBlocks(0, scratch);
    if (int(u16, scratch, 510) != 0xaa55) return error.InvalidPartition;
    if (@import("exfat.zig").isBoot(scratch) or (int(u16, scratch, 11) == 512 and std.math.isPowerOfTwo(scratch[13]) and scratch[16] != 0))
        return .{ .start = 0, .sectors = std.math.maxInt(u32) };
    for (0..4) |i| {
        const at = 446 + i * 16;
        const partition_type = scratch[at + 4];
        if (partition_type == 0xee) return gpt(device, scratch);
        if (partition_type != 7 and partition_type != 0xb and partition_type != 0xc) continue;
        const start = int(u32, scratch, at + 8);
        const sectors = int(u32, scratch, at + 12);
        if (start == 0 or sectors == 0 or @as(u64, start) + sectors > @as(u64, std.math.maxInt(u32)) + 1) return error.InvalidPartition;
        return .{ .start = start, .sectors = sectors };
    }
    return error.InvalidPartition;
}

fn gpt(device: anytype, scratch: *[512]u8) !Partition {
    try device.readBlocks(1, scratch);
    if (!std.mem.eql(u8, scratch[0..8], "EFI PART") or int(u32, scratch, 8) != 0x10000) return error.InvalidGpt;
    const size = int(u32, scratch, 12);
    if (size < 92 or size > 512 or int(u32, scratch, 20) != 0 or int(u64, scratch, 24) != 1) return error.InvalidGpt;
    const expected = int(u32, scratch, 16);
    @memset(scratch[16..20], 0);
    if (std.hash.Crc32.hash(scratch[0..size]) != expected) return error.InvalidGpt;
    const first = int(u64, scratch, 40);
    const last = int(u64, scratch, 48);
    const table = int(u64, scratch, 72);
    const count = int(u32, scratch, 80);
    const entry_bytes = int(u32, scratch, 84);
    const table_crc = int(u32, scratch, 88);
    if (first < 34 or first > last or last > std.math.maxInt(u32) or table < 2 or count == 0 or count > 4096 or
        entry_bytes < 128 or entry_bytes > 512 or !std.math.isPowerOfTwo(entry_bytes) or table + (@as(u64, count) * entry_bytes + 511) / 512 > first) return error.InvalidGpt;
    var checksum = std.hash.Crc32.init();
    var remaining: u64 = @as(u64, count) * entry_bytes;
    var lba: u32 = @intCast(table);
    var selected: ?Partition = null;
    while (remaining != 0) : (lba += 1) {
        try device.readBlocks(lba, scratch);
        const bytes: usize = @intCast(@min(remaining, 512));
        checksum.update(scratch[0..bytes]);
        var at: usize = 0;
        while (at < bytes) : (at += entry_bytes) {
            if (!std.mem.eql(u8, scratch[at..][0..16], &basic_data)) continue;
            const start = int(u64, scratch, at + 32);
            const end = int(u64, scratch, at + 40);
            if (start < first or start > end or end > last or end - start >= std.math.maxInt(u32)) return error.InvalidGpt;
            if (selected == null) selected = .{ .start = @intCast(start), .sectors = @intCast(end - start + 1) };
        }
        remaining -= bytes;
    }
    if (checksum.final() != table_crc) return error.InvalidGpt;
    return selected orelse error.InvalidPartition;
}
