pub const magic = "GAINBNCH".*;
pub const version = 2;
pub const report_address = 0xa070_0000;
pub const selection_address = 0xa06f_f000;
pub const source_address = 0x8080_0000;
pub const source_bytes = 209_519;
pub const timer_hz = 6_000_000;
pub const refill_interval_ticks = 512_000;
pub const refill_target_ticks = refill_interval_ticks * 70 / 100;
pub const refill_ceiling_ticks = refill_interval_ticks * 75 / 100;
pub const case_count = @typeInfo(Case).@"enum".field_names.len;
pub const coherency_failure = 0x8000_0001;

pub fn caseBit(case: Case) u32 {
    return @as(u32, 1) << @intCast(@backingInt(case));
}

pub fn caseCompleted(mask: u32, case: Case) bool {
    return mask & caseBit(case) != 0;
}

pub const Case = enum(u32) {
    decode_frames,
    stream_uncached,
    stream_cached,
    lpc_order_4,
    lpc_order_8,
    lpc_order_16,
    lpc_order_24,
    lpc_order_32,
    sd_initialize,
    sd_mount,
    sd_open,
    sd_stream_uncached,
    sd_stream_cached,
    sd_stream_readahead,
};

pub const Entry = extern struct {
    case: u32 = 0,
    observations: u32 = 0,
    minimum_ticks: u32 = 0,
    median_ticks: u32 = 0,
    p95_ticks: u32 = 0,
    maximum_ticks: u32 = 0,
    auxiliary_ticks: u32 = 0,
    checksum: u32 = 0,
    error_code: u32 = 0,
};

pub const Report = extern struct {
    magic_bytes: [8]u8 = magic,
    report_version: u32 = version,
    timer_frequency: u32 = timer_hz,
    completed_case_mask: u32 = 0,
    failure_code: u32 = 0,
    entries: [case_count]Entry = @splat(.{}),
};

comptime {
    if (@sizeOf(Report) != 528) @compileError("update the host transfer size with the report layout");
}

test "track sparse completed cases" {
    const std = @import("std");
    const mask = caseBit(.decode_frames) | caseBit(.lpc_order_4) | caseBit(.sd_open);
    try std.testing.expect(caseCompleted(mask, .decode_frames));
    try std.testing.expect(!caseCompleted(mask, .stream_cached));
    try std.testing.expect(caseCompleted(mask, .lpc_order_4));
    try std.testing.expect(caseCompleted(mask, .sd_open));
}
