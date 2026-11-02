//! Versioned RAM-only player qualification report; no persisted device state.
const std = @import("std");

pub const address = 0xa0700000;
pub const magic = 0x47415031;
pub const version = 1;
pub const timer_hz = 6_000_000;

pub const Report = extern struct {
    signature: u32 = magic,
    revision: u32 = version,
    complete: u32 = 0,
    mode: u32 = 0,
    error_code: u32 = 0,
    sample_rate: u32 = 0,
    frames_low: u32 = 0,
    frames_high: u32 = 0,
    periods: u32 = 0,
    underruns: u32 = 0,
    heap_peak: u32 = 0,
    storage_steps: u32 = 0,
    ui_polls: u32 = 0,
    maximum_fill_ticks: u32 = 0,
    startup_ticks: u32 = 0,
    maximum_ui_ticks: u32 = 0,
    maximum_ui_gap_ticks: u32 = 0,
    maximum_irq_ticks: u32 = 0,
    stack_used: [5]u32 = @splat(0),
    exit: u32 = 0,
    iterations: u32 = 0,
    elapsed_ticks: u32 = 0,
    cause: u32 = 0,
    epc: u32 = 0,
    error_length: u32 = 0,
    pcm_checksum: u32 = 2166136261,
    volume_changes: u32 = 0,
    minimum_fifo: u32 = 0,
};

comptime {
    if (@sizeOf(Report) != 128) @compileError("player report ABI changed");
}

pub fn validate(report: Report) !void {
    if (report.signature != magic or report.revision != version or report.complete != 1) return error.IncompleteReport;
    if (report.error_code != 0 or report.cause != 0) return error.PlayerFailure;
    if (report.underruns != 0 or report.periods == 0 or report.ui_polls < 2) return error.PlaybackFailure;
    const period = timer_hz / (if (report.sample_rate == 11025) @as(u32, 25) else if (report.sample_rate == 22050) @as(u32, 50) else @as(u32, 100));
    if (report.maximum_fill_ticks > period / 4) return error.FillBudget;
    if (report.heap_peak > 256 * 1024) return error.HeapBudget;
    if (report.startup_ticks > timer_hz / 2) return error.StartupBudget;
    if (report.maximum_ui_ticks > timer_hz / 100 or report.maximum_ui_gap_ticks > timer_hz * 35 / 1000) return error.UiBudget;
    if (report.maximum_irq_ticks > timer_hz / 20_000) return error.InterruptBudget;
    const capacities = [_]u32{ 32 * 1024, 32 * 1024, 32 * 1024, 352 * 1024, 64 * 1024 };
    for (report.stack_used, capacities) |used, capacity| if (used == 0 or used > capacity - 4096) return error.StackBudget;
}

test "qualification rejects incomplete, failed and over-budget measurements" {
    var report = Report{ .complete = 1, .sample_rate = 48000, .periods = 1, .ui_polls = 2, .stack_used = @splat(1024) };
    try validate(report);
    inline for (.{
        .{ "complete", 0, error.IncompleteReport },
        .{ "underruns", 1, error.PlaybackFailure },
        .{ "error_code", 1, error.PlayerFailure },
        .{ "maximum_fill_ticks", 15001, error.FillBudget },
        .{ "heap_peak", 262145, error.HeapBudget },
        .{ "startup_ticks", 3000001, error.StartupBudget },
        .{ "maximum_ui_ticks", 60001, error.UiBudget },
        .{ "maximum_ui_gap_ticks", 210001, error.UiBudget },
        .{ "maximum_irq_ticks", 301, error.InterruptBudget },
    }) |mutation| {
        var bad = report;
        @field(bad, mutation[0]) = mutation[1];
        try std.testing.expectError(mutation[2], validate(bad));
    }
    report.stack_used[0] = 32 * 1024 - 4095;
    try std.testing.expectError(error.StackBudget, validate(report));
}
