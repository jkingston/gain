const std = @import("std");
const protocol = @import("ui_bench_report.zig");

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const path = arguments.next() orelse return error.MissingReportPath;
    if (arguments.next() != null) return error.TooManyArguments;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(@sizeOf(protocol.Report) + 1));
    defer init.gpa.free(bytes);
    if (bytes.len != @sizeOf(protocol.Report)) return error.InvalidReportSize;
    var report: protocol.Report = undefined;
    @memcpy(std.mem.asBytes(&report), bytes);
    std.debug.print("F20 UI: completed {d}, stage {d}, failure {d}, transfers {d}, pixels checked {d}, mismatches {d}\n", .{
        report.completed,
        report.stage,
        report.failure,
        report.transfers,
        report.checked_pixels,
        report.mismatches,
    });
    std.debug.print("Worst ms: full render {d:.3}, live slide {d:.3}, full prepare {d:.3}, DMA {d:.3}, region render {d:.3}, region prepare {d:.3}, combined region job {d:.3}\n", .{
        ms(report.render_ticks),
        ms(report.slide_ticks),
        ms(report.prepare_ticks),
        ms(report.transfer_ticks),
        ms(report.region_render_ticks),
        ms(report.region_prepare_ticks),
        ms(report.region_job_ticks),
    });
    if (report.failure != 0) std.debug.print("Device error: {s}\n", .{std.mem.sliceTo(&report.error_name, 0)});
    try protocol.validate(report);
}

fn ms(ticks: u32) f64 {
    return @as(f64, @floatFromInt(ticks)) / protocol.ticks_per_ms;
}
