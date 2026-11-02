const std = @import("std");
const protocol = @import("player_check_report.zig");

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
    std.debug.print("Player: {d} Hz, {d} periods, {d} replays, {d} underruns; heap {d} B, stacks {any}\n", .{
        report.sample_rate,
        report.periods,
        report.iterations,
        report.underruns,
        report.heap_peak,
        report.stack_used,
    });
    std.debug.print("Worst ms: startup {d:.3}, fill {d:.3}, UI {d:.3}, UI gap {d:.3}, IRQ {d:.3}\n", .{
        ms(report.startup_ticks),
        ms(report.maximum_fill_ticks),
        ms(report.maximum_ui_ticks),
        ms(report.maximum_ui_gap_ticks),
        ms(report.maximum_irq_ticks),
    });
    try protocol.validate(report);
}

fn ms(ticks: u32) f64 {
    return @as(f64, @floatFromInt(ticks)) / 6000;
}
