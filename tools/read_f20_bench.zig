const std = @import("std");
const protocol = @import("f20_bench_report.zig");

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const path = arguments.next() orelse return error.MissingReportPath;
    if (arguments.next() != null) return error.TooManyArguments;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.gpa,
        .limited(@sizeOf(protocol.Report) + 1),
    );
    defer init.gpa.free(bytes);
    if (bytes.len != @sizeOf(protocol.Report)) return error.InvalidReportSize;

    var report: protocol.Report = undefined;
    @memcpy(std.mem.asBytes(&report), bytes);
    if (!std.mem.eql(u8, &report.magic_bytes, &protocol.magic) or
        report.report_version != protocol.version or
        report.timer_frequency == 0)
    {
        return error.InvalidReport;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "F20 FLAC benchmark: {d}/{d} cases completed, timer {d} Hz\n" ++
            "case                         n    min ms  median ms     p95 ms     max ms   storage ms  budget   checksum\n",
        .{ @popCount(report.completed_case_mask), protocol.case_count, report.timer_frequency },
    );
    var benchmark_failed = false;
    for (report.entries, 0..) |entry, index| {
        const case: protocol.Case = @fromBackingInt(@intCast(index));
        if (!protocol.caseCompleted(report.completed_case_mask, case)) continue;
        if (entry.error_code != 0) {
            try stdout.print("{s:<28} ERROR {d}\n", .{ @tagName(case), entry.error_code });
            benchmark_failed = true;
            continue;
        }
        try stdout.print("{s:<28} {d:>3} {d:>9.3} {d:>10.3} {d:>10.3} {d:>10.3} {d:>12.3} {d:>7.2}% {x:0>8}\n", .{
            @tagName(case),
            entry.observations,
            milliseconds(entry.minimum_ticks, report.timer_frequency),
            milliseconds(entry.median_ticks, report.timer_frequency),
            milliseconds(entry.p95_ticks, report.timer_frequency),
            milliseconds(entry.maximum_ticks, report.timer_frequency),
            milliseconds(entry.auxiliary_ticks, report.timer_frequency),
            refillBudget(entry.maximum_ticks),
            entry.checksum,
        });
    }
    if (report.failure_code != 0) {
        if (report.failure_code == protocol.coherency_failure) {
            try stdout.writeAll("cached and uncached output aliases differ; cached DMA output is unsafe\n");
        } else {
            try stdout.print("benchmark completed with error code {d}\n", .{report.failure_code});
        }
    }
    const stream = report.entries[@backingInt(protocol.Case.stream_uncached)];
    if (stream.observations != 0 and stream.maximum_ticks > protocol.refill_ceiling_ticks) {
        try stdout.print("stream refill exceeds the 75% release ceiling ({d:.2}%)\n", .{
            refillBudget(stream.maximum_ticks),
        });
        try stdout.flush();
        return error.PerformanceRegression;
    }
    try stdout.flush();
    if (benchmark_failed) return error.BenchmarkFailed;
}

fn milliseconds(ticks: u32, frequency: u32) f64 {
    return @as(f64, @floatFromInt(ticks)) * 1000.0 / @as(f64, @floatFromInt(frequency));
}

fn refillBudget(ticks: u32) f64 {
    return @as(f64, @floatFromInt(ticks)) * 100.0 /
        @as(f64, @floatFromInt(protocol.refill_interval_ticks));
}
