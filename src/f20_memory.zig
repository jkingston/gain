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

pub const firmware = Region{ .start = 0x4000, .bytes = 0x280000 - 0x4000 };
// Zero-initialized globals occupy the gap after USB DMA and before read-ahead.
// Kept separate from the SD boot payload; every startup zeros this region.
pub const firmware_bss = Region{ .start = 0x2a0000, .bytes = 0x20000 };
pub const lcd_descriptors = Region{ .start = 0x2e0000, .bytes = 0x1000 };
pub const sd_control = Region{ .start = 0x2e1000, .bytes = 0x1000 };
pub const filesystem_sector = Region{ .start = 0x2e2000, .bytes = 512 };
pub const read_ahead = Region{ .start = 0x2c0000, .bytes = 2 * 64 * 1024 };
pub const audio_descriptors = Region{ .start = 0x2e5000, .bytes = 4096 };
// Two uncached identity-mapped pages, owned by the USB controller.
pub const usb_dma = Region{ .start = 0x280000, .bytes = @import("x1000_dma.zig").window_bytes };
pub const canvas = Region{ .start = 0x300000, .bytes = 320 * 240 * 2 };
pub const display_snapshot = Region{ .start = 0x340000, .bytes = 320 * 240 * 2 };
pub const display_next = Region{ .start = 0x3a0000, .bytes = 320 * 240 * 2 };
pub const display_staging = Region{ .start = 0x380000, .bytes = 320 * 42 * 2 };
pub const flac_left = Region{ .start = 0x400000, .bytes = 65535 * 4 };
pub const flac_right = Region{ .start = 0x440000, .bytes = 65535 * 4 };
pub const flac_compressed = Region{ .start = 0x480000, .bytes = 256 * 1024 };
pub const decoder_arena = Region{ .start = 0x500000, .bytes = 2 * 1024 * 1024 };
pub const fault_capsule = Region{ .start = 0x700000, .bytes = 4096 };
pub const compressed_ring = Region{ .start = 0x800000, .bytes = 4 * 1024 * 1024 };
pub const pcm_reservoir = Region{ .start = 0xc00000, .bytes = 192000 * 8 };
// The producer publishes at most 8192 frames per callback. FLAC keeps its
// full 65535-sample left/right planes and converts large blocks in batches.
pub const decoded_frames = Region{ .start = 0xe00000, .bytes = 8192 * 8 };
// Every supported fixed-quantum period fits in 16 KiB, including 192 kHz
// stereo 24-bit output. Font memory never aliases active DMA payloads.
pub const audio_buffer_capacity = 16 * 1024;
pub const audio_buffers = Region{ .start = 0x1000000, .bytes = 4 * audio_buffer_capacity };
pub const text_code = Region{ .start = audio_buffers.end(), .bytes = 1024 * 1024 };
pub const text_heap = Region{ .start = text_code.end(), .bytes = 960 * 1024 };
pub const text_workspace = Region{ .start = 0xd78000, .bytes = 0x88000 };
// This gap is above the final display snapshot and below decoder channel RAM.
pub const text_aux_heap = Region{ .start = 0x3c6000, .bytes = 0x3a000 };
pub const text_cache = Region{ .start = 0x4c0000, .bytes = 256 * 1024 };
pub const catalog_a = Region{ .start = 0x1200000, .bytes = 6 * 1024 * 1024 };
pub const catalog_b = Region{ .start = catalog_a.end(), .bytes = 6 * 1024 * 1024 };
pub const task_stacks = Region{ .start = 0x1f00000, .bytes = 768 * 1024 };
pub const output_stack = Region{ .start = task_stacks.start, .bytes = 32 * 1024 };
pub const ui_stack = Region{ .start = output_stack.end(), .bytes = 32 * 1024 };
pub const control_stack = Region{ .start = ui_stack.end(), .bytes = 32 * 1024 };
pub const codec_stack = Region{ .start = control_stack.end(), .bytes = 352 * 1024 };
pub const storage_stack = Region{ .start = codec_stack.end(), .bytes = 320 * 1024 };
pub const storage_burst = Region{ .start = read_ahead.start, .bytes = 64 * 1024 };
pub const decoder_cache = Region{ .start = storage_burst.end(), .bytes = 64 * 1024 };
pub const codec_packet = Region{ .start = compressed_ring.start, .bytes = 65536 + 64 };
pub const codec_page = Region{ .start = compressed_ring.start + 128 * 1024, .bytes = 65025 };
pub const codec_float_pcm = Region{ .start = compressed_ring.start + 192 * 1024, .bytes = 16384 * 4 };
pub const stream_input = Region{ .start = codec_float_pcm.end(), .bytes = compressed_ring.end() - codec_float_pcm.end() };
pub const interrupt_stack = Region{ .start = 0x1fdc000, .bytes = 8192 };
// Keep ROM recovery state below all stacks so an overflow cannot destroy it.
pub const rom_context = Region{ .start = 0x2e4000, .bytes = 4096 };
pub const boot_stack = Region{ .start = 0x1fe0000, .bytes = 0x1f000 };
// Concurrent scanner owns these gaps; none alias decoder or playback input.
// Separate temporary locator maps keep the 1.5 MiB scanner workspace below
// its measured worst case. The 128 KiB below this reservation stays available
// to the previously qualified RAM loader.
pub const scan_maps = Region{ .start = 0x1e20000, .bytes = 0xe0000 };
pub const scan_scratch = Region{ .start = 0xe80000, .bytes = 0x180000 };
pub const scan_io = Region{ .start = 0x740000, .bytes = 0x20000 };
pub const scan_views = Region{ .start = 0x780000, .bytes = 0x80000 };
pub const scan_artwork = Region{ .start = 0x704000, .bytes = 0x3c000 };
pub const cover_cache = Region{ .start = 0xe10000, .bytes = 0x70000 };
pub const regions = [_]Region{
    firmware,
    firmware_bss,
    lcd_descriptors,
    sd_control,
    filesystem_sector,
    read_ahead,
    audio_descriptors,
    usb_dma,
    canvas,
    display_snapshot,
    display_next,
    display_staging,
    flac_left,
    flac_right,
    flac_compressed,
    decoder_arena,
    fault_capsule,
    compressed_ring,
    pcm_reservoir,
    decoded_frames,
    audio_buffers,
    text_code,
    text_heap,
    text_aux_heap,
    text_workspace,
    text_cache,
    catalog_a,
    catalog_b,
    task_stacks,
    interrupt_stack,
    rom_context,
    boot_stack,
    scan_scratch,
    scan_io,
    scan_views,
    scan_artwork,
    cover_cache,
    scan_maps,
};

comptime {
    @setEvalBranchQuota(4000);
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

test "ROM recovery context stays below every CPU stack" {
    try std.testing.expect(rom_context.end() <= task_stacks.start);
}

test "all board sample rates and output formats fit isolated DMA buffers" {
    const output = @import("audio_output.zig");
    const board = @import("f20_v27.zig");
    inline for (std.enums.values(board.audio.SampleRate)) |rate| {
        inline for (std.enums.values(@import("pcm.zig").OutputFormat)) |format| {
            const plan = try output.Plan.init(@backingInt(rate), format);
            try std.testing.expect(plan.bytes <= audio_buffer_capacity);
        }
    }
    try std.testing.expectEqual(catalog_a.start, text_heap.end());
    try std.testing.expect(pcm_reservoir.end() <= text_workspace.start);
    try std.testing.expectEqual(decoded_frames.start, text_workspace.end());
}
