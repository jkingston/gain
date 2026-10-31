//! F20 physical RAM ownership. Cached/uncached aliases refer to the same bytes.
const std = @import("std");
pub const ram_bytes = 32 * 1024 * 1024;
pub const Region = struct {
    start: u32,
    bytes: u32,
    pub fn cached(self: Region) usize {
        return 0x80000000 + self.start;
    }
    pub fn uncached(self: Region) usize {
        return 0xa0000000 + self.start;
    }
    pub fn end(self: Region) u32 {
        return self.start + self.bytes;
    }
    pub fn cachedTop(self: Region) usize {
        return self.cached() + self.bytes;
    }
    pub fn cachedSlice(self: Region, comptime T: type) []T {
        return @as([*]T, @ptrFromInt(self.cached()))[0 .. self.bytes / @sizeOf(T)];
    }
    pub fn uncachedSlice(self: Region, comptime T: type) []T {
        return @as([*]T, @ptrFromInt(self.uncached()))[0 .. self.bytes / @sizeOf(T)];
    }
};
pub const firmware = Region{ .start = 0x4000, .bytes = 0x200000 - 0x4000 };
pub const lcd_descriptors = Region{ .start = 0x201000, .bytes = 0x1000 };
pub const sd_control = Region{ .start = 0x202000, .bytes = 0x1000 };
pub const filesystem_sector = Region{ .start = 0x203000, .bytes = 512 };
pub const read_ahead = Region{ .start = 0x210000, .bytes = 2 * 64 * 1024 };
pub const audio_descriptors = Region{ .start = 0x230000, .bytes = 4096 };
pub const canvas = Region{ .start = 0x300000, .bytes = 320 * 240 * 2 };
pub const display_snapshot = Region{ .start = 0x340000, .bytes = 320 * 240 * 2 };
pub const display_staging = Region{ .start = 0x380000, .bytes = 320 * 42 * 2 };
pub const flac_left = Region{ .start = 0x400000, .bytes = 65535 * 4 };
pub const flac_right = Region{ .start = 0x440000, .bytes = 65535 * 4 };
pub const flac_compressed = Region{ .start = 0x480000, .bytes = 256 * 1024 };
pub const decoder_arena = Region{ .start = 0x500000, .bytes = 2 * 1024 * 1024 };
pub const compressed_ring = Region{ .start = 0x800000, .bytes = 4 * 1024 * 1024 };
pub const pcm_reservoir = Region{ .start = 0xc00000, .bytes = 192000 * 8 };
pub const decoded_frames = Region{ .start = 0xe00000, .bytes = 65535 * 8 };
// Fixed addresses retain the established DMA reservations. Fixed-quantum
// output uses only Plan.bytes at the start of each buffer.
pub const audio_buffers = Region{ .start = 0x1000000, .bytes = 4 * 512 * 1024 };
pub const audio_buffer_capacity = 512 * 1024;
pub const task_stacks = Region{ .start = 0x1f00000, .bytes = 512 * 1024 };
pub const output_stack = Region{ .start = task_stacks.start, .bytes = 32 * 1024 };
pub const ui_stack = Region{ .start = output_stack.end(), .bytes = 32 * 1024 };
pub const control_stack = Region{ .start = ui_stack.end(), .bytes = 32 * 1024 };
pub const codec_stack = Region{ .start = control_stack.end(), .bytes = 352 * 1024 };
pub const storage_stack = Region{ .start = codec_stack.end(), .bytes = 64 * 1024 };
pub const storage_burst = Region{ .start = read_ahead.start, .bytes = 64 * 1024 };
pub const decoder_cache = Region{ .start = storage_burst.end(), .bytes = 64 * 1024 };
pub const codec_packet = Region{ .start = compressed_ring.start, .bytes = 65536 + 64 };
pub const codec_page = Region{ .start = compressed_ring.start + 128 * 1024, .bytes = 65025 };
pub const codec_float_pcm = Region{ .start = compressed_ring.start + 192 * 1024, .bytes = 16384 * 4 };
pub const stream_input = Region{ .start = codec_float_pcm.end(), .bytes = compressed_ring.end() - codec_float_pcm.end() };
pub const interrupt_stack = Region{ .start = 0x1fdc000, .bytes = 8192 };
pub const boot_stack = Region{ .start = 0x1fe0000, .bytes = 0x1f000 };
pub const regions = [_]Region{ firmware, lcd_descriptors, sd_control, filesystem_sector, read_ahead, audio_descriptors, canvas, display_snapshot, display_staging, flac_left, flac_right, flac_compressed, decoder_arena, compressed_ring, pcm_reservoir, decoded_frames, audio_buffers, task_stacks, interrupt_stack, boot_stack };
comptime {
    for (regions, 0..) |region, i| {
        if (region.end() > ram_bytes or region.start & 3 != 0 or region.bytes == 0) @compileError("invalid F20 RAM reservation");
        for (regions[i + 1 ..]) |other| {
            if (region.start < other.end() and other.start < region.end()) @compileError("F20 RAM reservations overlap");
        }
    }
    const Group = struct { parent: Region, children: []const Region };
    for ([_]Group{
        .{ .parent = task_stacks, .children = &.{ output_stack, ui_stack, control_stack, codec_stack, storage_stack } },
        .{ .parent = read_ahead, .children = &.{ storage_burst, decoder_cache } },
        .{ .parent = compressed_ring, .children = &.{ codec_packet, codec_page, codec_float_pcm, stream_input } },
    }) |group| {
        for (group.children, 0..) |child, i| {
            if (child.start < group.parent.start or child.end() > group.parent.end() or
                child.bytes == 0 or child.start & 15 != 0) @compileError("invalid F20 subregion");
            for (group.children[i + 1 ..]) |other| {
                if (child.start < other.end() and other.start < child.end()) @compileError("F20 subregions overlap");
            }
        }
    }
}
test "DMA aliases resolve to the same physical RAM reservation" {
    inline for (regions) |region| try std.testing.expectEqual(region.cached() & 0x1fffffff, region.uncached() & 0x1fffffff);
}

test "stream workspace slices retain byte capacity and DMA alignment" {
    try std.testing.expectEqual(@as(usize, 16384), codec_float_pcm.cachedSlice(f32).len);
    try std.testing.expectEqual(@as(usize, 65536), storage_burst.uncachedSlice(u8).len);
    try std.testing.expectEqual(@as(usize, 65536 + 64), codec_packet.cachedSlice(u8).len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(storage_burst.uncachedSlice(u8).ptr) & 15);
    try std.testing.expectEqual(task_stacks.cachedTop(), storage_stack.cachedTop());
    try std.testing.expectEqual(@as(u32, 4 * audio_buffer_capacity), audio_buffers.bytes);
}
