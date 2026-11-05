const std = @import("std");
pub const engine = @import("text/engine.zig");
test {
    std.testing.refAllDecls(engine);
    _ = @import("text/cache.zig");
    _ = @import("text/worker_service.zig");
    _ = @import("text/pack.zig");
    _ = @import("text/component.zig");
    _ = @import("text/runtime.zig");
    _ = @import("file_seek_index.zig");
}

const abi = @import("text/contract.zig");
const fixture = @import("font_fixture").pack;
var memory: [960 * 1024]u8 align(16) = undefined;
var auxiliary: [232 * 1024]u8 align(16) = undefined;
const workspace = abi.Workspace{ .primary = &memory, .primary_bytes = memory.len, .auxiliary = &auxiliary, .auxiliary_bytes = auxiliary.len };
const Fixture = struct {
    reads: usize = 0,
    polls: usize = 0,
    cancel: bool = false,
    fn read(context: *anyopaque, at: u32, output: [*]u8, count: u32) callconv(.c) u32 {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.reads += 1;
        if (@as(u64, at) + count > fixture.len) return 0;
        @memcpy(output[0..count], fixture[at..][0..count]);
        return count;
    }
    fn poll(context: *anyopaque) callconv(.c) bool {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.polls += 1;
        return self.cancel;
    }
};

test "multilingual shaping, cluster ellipsis, cancellation and media remount use a fixed pool" {
    var source: Fixture = .{};
    const input = abi.Source{ .context = &source, .bytes = fixture.len, .read = Fixture.read, .poll = Fixture.poll };
    try std.testing.expectEqual(abi.Result.ready, engine.api.initialize(&input, &workspace));
    defer engine.api.shutdown();
    const samples = try std.json.parseFromSlice([]const struct { language: []const u8, text: []const u8 }, std.testing.allocator, @import("font_fixture").samples, .{});
    defer samples.deinit();
    var label: abi.Label = .{};
    for (samples.value) |sample| {
        const request = try abi.Request.init(sample.text, .reading, 288, .automatic, true);
        const result = engine.api.prepare(&request, &label);
        if (result != .ready or label.missing != 0) std.debug.print("text {s}: {s}, missing {d}\n", .{ sample.language, @tagName(result), label.missing });
        try std.testing.expectEqual(abi.Result.ready, result);
        try std.testing.expectEqual(@as(u16, 0), label.missing);
        var allocation: abi.Statistics = .{};
        engine.api.statistics(&allocation);
        try std.testing.expectEqual(@as(u32, 0), allocation.heap_failures);
        try std.testing.expect(label.width > 0 and label.width <= 288 and label.height <= 48);
        try std.testing.expect(std.mem.indexOfNone(u8, &label.pixels, &.{0}) != null);
        for ([_]u16{ 0, 5, 20, 60 }) |width| {
            const narrow = try abi.Request.init(sample.text, .reading, width, .automatic, true);
            try std.testing.expectEqual(abi.Result.ready, engine.api.prepare(&narrow, &label));
            try std.testing.expect(label.width <= width);
        }
    }
    source.cancel = true;
    const request = try abi.Request.init("日本語", .body, 288, .automatic, true);
    try std.testing.expectEqual(abi.Result.cancelled, engine.api.prepare(&request, &label));
    source.cancel = false;
    engine.api.shutdown();
    try std.testing.expectEqual(abi.Result.ready, engine.api.initialize(&input, &workspace));
    try std.testing.expectEqual(abi.Result.ready, engine.api.prepare(&request, &label));
    try std.testing.expect(source.reads > 0 and source.polls > source.reads);
}

const c = @import("text_c");

test "Unicode 17 official grapheme boundaries preserve emoji, marks and Indic conjuncts" {
    var lines = std.mem.splitScalar(u8, @import("font_fixture").graphemes, '\n');
    var cases: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        var state: i32 = 0;
        var previous: ?i32 = null;
        while (tokens.next()) |boundary| {
            const token = tokens.next() orelse break;
            const cp = try std.fmt.parseInt(i32, token, 16);
            if (previous) |p| try std.testing.expectEqual(std.mem.eql(u8, boundary, "÷"), c.utf8proc_grapheme_break_stateful(p, cp, &state));
            previous = cp;
        }
        cases += 1;
    }
    try std.testing.expect(cases > 700);
}

test "Unicode 17 official bidi levels and visual run ordering" {
    var source: Fixture = .{};
    const input = abi.Source{ .context = &source, .bytes = fixture.len, .read = Fixture.read, .poll = Fixture.poll };
    try std.testing.expectEqual(abi.Result.ready, engine.api.initialize(&input, &workspace));
    defer engine.api.shutdown();
    var lines = std.mem.splitScalar(u8, @import("font_fixture").bidi, '\n');
    var cases: usize = 0;
    while (lines.next()) |raw| {
        const clean = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (clean.len == 0) continue;
        var fields = std.mem.splitScalar(u8, clean, ';');
        var points: [512]u32 = undefined;
        var length: usize = 0;
        var tokens = std.mem.tokenizeAny(u8, fields.next().?, " \t");
        while (tokens.next()) |token| {
            if (length == points.len) return error.InvalidTestVector;
            points[length] = try std.fmt.parseInt(u32, token, 16);
            length += 1;
        }
        const direction = try std.fmt.parseInt(u8, std.mem.trim(u8, fields.next().?, " \t"), 10);
        const base = try std.fmt.parseInt(u8, std.mem.trim(u8, fields.next().?, " \t"), 10);
        var levels: [512]?u8 = @splat(null);
        var level_tokens = std.mem.tokenizeAny(u8, fields.next().?, " \t");
        var level_count: usize = 0;
        while (level_tokens.next()) |token| {
            levels[level_count] = if (std.mem.eql(u8, token, "x")) null else try std.fmt.parseInt(u8, token, 10);
            level_count += 1;
        }
        try std.testing.expectEqual(length, level_count);
        var expected: [512]usize = undefined;
        var order_count: usize = 0;
        var order_tokens = std.mem.tokenizeAny(u8, fields.next().?, " \t");
        while (order_tokens.next()) |token| {
            expected[order_count] = try std.fmt.parseInt(usize, token, 10);
            order_count += 1;
        }
        const seq = c.SBCodepointSequence{ .stringEncoding = c.SBStringEncodingUTF32, .stringBuffer = &points, .stringLength = length };
        const algorithm = c.SBAlgorithmCreate(&seq) orelse return error.OutOfMemory;
        defer c.SBAlgorithmRelease(algorithm);
        const paragraph = c.SBAlgorithmCreateParagraph(algorithm, 0, length, if (direction == 2) c.SBLevelDefaultLTR else direction) orelse return error.OutOfMemory;
        defer c.SBParagraphRelease(paragraph);
        try std.testing.expectEqual(base, c.SBParagraphGetBaseLevel(paragraph));
        const line = c.SBParagraphCreateLine(paragraph, 0, length) orelse return error.OutOfMemory;
        defer c.SBLineRelease(line);
        var actual: [512]usize = undefined;
        var count: usize = 0;
        for (c.SBLineGetRunsPtr(line)[0..c.SBLineGetRunCount(line)]) |run| {
            for (0..run.length) |j| {
                const logical = run.offset + if (run.level & 1 == 0) j else run.length - 1 - j;
                if (levels[logical]) |level| {
                    try std.testing.expectEqual(level, run.level);
                    actual[count] = logical;
                    count += 1;
                }
            }
        }
        try std.testing.expectEqualSlices(usize, expected[0..order_count], actual[0..count]);
        cases += 1;
    }
    try std.testing.expect(cases > 90_000);
}

test "pack failures, invalid UTF-8 and cancellation leave the previous mount recoverable" {
    var source: Fixture = .{};
    var input = abi.Source{ .context = &source, .bytes = fixture.len, .read = Fixture.read, .poll = Fixture.poll };
    try std.testing.expectEqual(abi.Result.ready, engine.api.initialize(&input, &workspace));
    var label: abi.Label = .{};
    var invalid: abi.Request = .{ .length = 1 };
    invalid.text[0] = 0xff;
    try std.testing.expectEqual(abi.Result.invalid_text, engine.api.prepare(&invalid, &label));
    input.bytes = 1;
    try std.testing.expectEqual(abi.Result.invalid_pack, engine.api.initialize(&input, &workspace));
    input.bytes = fixture.len;
    try std.testing.expectEqual(abi.Result.ready, engine.api.initialize(&input, &workspace));
    const request = try abi.Request.init("الموسيقى العربية", .reading, 100, .automatic, true);
    try std.testing.expectEqual(abi.Result.ready, engine.api.prepare(&request, &label));
    try std.testing.expectEqual(@as(u8, 1), label.rtl);
    try std.testing.expectEqual(@as(u8, 1), label.truncated);
    var first = label;
    try std.testing.expectEqual(abi.Result.ready, engine.api.prepare(&request, &label));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&first), std.mem.asBytes(&label));
    var stats: abi.Statistics = .{};
    engine.api.statistics(&stats);
    try std.testing.expect(stats.heap_peak < memory.len + auxiliary.len and stats.heap_failures == 0);
    engine.api.shutdown();
}

test "framework glyph IDs and positions match direct HarfBuzz for joined scripts and emoji" {
    var source: Fixture = .{};
    const input = abi.Source{ .context = &source, .bytes = fixture.len, .read = Fixture.read, .poll = Fixture.poll };
    try std.testing.expectEqual(abi.Result.ready, engine.api.initialize(&input, &workspace));
    defer engine.api.shutdown();
    var label: abi.Label = .{};
    for ([_][]const u8{ "العربية", "فارسی", "עברית", "क्ष", "தமிழ்", "ดนตรีไทย", "👩‍🎤" }) |value| {
        for (std.enums.values(abi.Role)) |role| {
            const request = try abi.Request.init(value, role, 320, .automatic, false);
            try std.testing.expectEqual(abi.Result.ready, engine.api.prepare(&request, &label));
            try std.testing.expectEqual(@as(u16, 0), label.missing);
            try engine.testing.expectDirectShaping(value, role);
        }
    }
}

test "large contextual tables remain exact across role changes without exhausting or retaining the arenas" {
    // The fixture keeps this real font's complete GSUB / GPOS (about 925 kB)
    // tables. Its four source characters expand to hundreds of positioned
    // glyphs; reusing the old heavy face across sizes reproduced pool failure.
    var source: Fixture = .{};
    const input = abi.Source{ .context = &source, .bytes = fixture.len, .read = Fixture.read, .poll = Fixture.poll };
    try std.testing.expectEqual(abi.Result.ready, engine.api.initialize(&input, &workspace));
    defer engine.api.shutdown();
    var label: abi.Label = .{};
    for (0..3) |_| for (std.enums.values(abi.Role)) |role| {
        const request = try abi.Request.init("𛰀𛰁𛰂𛰃", role, 288, .automatic, true);
        try std.testing.expectEqual(abi.Result.ready, engine.api.prepare(&request, &label));
        try std.testing.expectEqual(@as(u16, 0), label.missing);
        var statistics: abi.Statistics = .{};
        engine.api.statistics(&statistics);
        try std.testing.expectEqual(@as(u32, 0), statistics.heap_failures);
        try std.testing.expect(statistics.heap_peak <= memory.len + auxiliary.len);
        try std.testing.expect(statistics.heap_live < auxiliary.len / 2);
    };
}
