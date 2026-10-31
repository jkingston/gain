//! Fixed little-endian report shared by the RAM benchmark and host reader.
const std = @import("std");
pub const report_address = 0xa0700000;
pub const magic = 0x47554931;
pub const final_stage = 8;
pub const expected_transfers = 213;
pub const expected_checked_pixels = 844800;
pub const ticks_per_ms = 6000;
pub const Report = extern struct {
    magic: u32 = magic,
    completed: u32 = 0,
    failure: u32 = 0,
    stage: u32 = 0,
    transfers: u32 = 0,
    build_ticks: u32 = 0,
    render_ticks: u32 = 0,
    slide_ticks: u32 = 0,
    prepare_ticks: u32 = 0,
    transfer_ticks: u32 = 0,
    mismatches: u32 = 0,
    checked_pixels: u32 = 0,
    first_bad: u32 = 0xffffffff,
    expected: u32 = 0,
    actual: u32 = 0,
    region_render_ticks: u32 = 0,
    region_prepare_ticks: u32 = 0,
    region_job_ticks: u32 = 0,
    error_name: [64]u8 = @splat(0),
};
comptime {
    if (@sizeOf(Report) != 136) @compileError("update run_ui_bench.sh report length");
}
/// Non-concurrent release ceilings. Full snapshot copying happens before
/// playback starts. Region render+prepare must stay within the 3 ms UI budget.
pub fn validate(report: Report) !void {
    if (report.magic != magic or report.completed != 1 or report.stage != final_stage or report.failure != 0 or report.transfers != expected_transfers or report.checked_pixels != expected_checked_pixels or report.mismatches != 0) return error.QualificationFailed;
    if (report.render_ticks > 3 * ticks_per_ms or report.slide_ticks > 3 * ticks_per_ms or report.prepare_ticks > 5 * ticks_per_ms or report.region_job_ticks > 3 * ticks_per_ms or report.transfer_ticks > 18 * ticks_per_ms) return error.PerformanceRegression;
}
test "hardware release gate rejects incomplete pixel and timing failures" {
    var report = Report{ .completed = 1, .stage = final_stage, .transfers = expected_transfers, .checked_pixels = expected_checked_pixels };
    try validate(report);
    report.mismatches = 1;
    try std.testing.expectError(error.QualificationFailed, validate(report));
    report.mismatches = 0;
    report.completed = 0;
    try std.testing.expectError(error.QualificationFailed, validate(report));
    report.completed = 1;
    report.failure = 1;
    try std.testing.expectError(error.QualificationFailed, validate(report));
    report.failure = 0;
    report.region_job_ticks = 3 * ticks_per_ms + 1;
    try std.testing.expectError(error.PerformanceRegression, validate(report));
    report.region_job_ticks = 0;
    report.slide_ticks = 3 * ticks_per_ms + 1;
    try std.testing.expectError(error.PerformanceRegression, validate(report));
    report.slide_ticks = 0;
    report.prepare_ticks = 5 * ticks_per_ms + 1;
    try std.testing.expectError(error.PerformanceRegression, validate(report));
}
