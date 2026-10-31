const std = @import("std");
const gain = @import("gain");
const fixtures = @import("codec_fixtures.zig");
const Frame = gain.pcm_reservoir.StereoFrame;
const Source = gain.media_source.Source(Reader);
var arena: [512 * 1024]u8 align(16) = undefined;
var packet: [65536 + 64]u8 = undefined;
var page: [65025]u8 = undefined;
var floats: [16384]f32 = undefined;
var converted: [8192]Frame = undefined;
var output: [100000]Frame = undefined;
var baseline: [100000]Frame = undefined;
var cache: [65536]u8 = undefined;
var compressed: [256 * 1024]u8 = undefined;
var left: [65535]i32 = undefined;
var right: [65535]i32 = undefined;
const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    fragment: usize = std.math.maxInt(usize),
    reads: usize = 0,
    fail_on_read: ?usize = null,
    pub fn seekTo(self: *Reader, target: u32) !void {
        if (target > self.bytes.len) return error.SeekBounds;
        self.position = target;
    }
    pub fn read(self: *Reader, target: []u8) !usize {
        self.reads += 1;
        if (self.fail_on_read == self.reads) return error.CardRemoved;
        const n = @min(target.len, self.fragment, self.bytes.len - self.position);
        @memcpy(target[0..n], self.bytes[self.position..][0..n]);
        self.position += n;
        return n;
    }
};
const Sink = struct {
    count: usize = 0,
    information: ?gain.media_info.Information = null,
    pushes: usize = 0,
    cancel_on_push: ?usize = null,
    reject_configuration: bool = false,
    fail_reader_on_configure: ?*Reader = null,
    observe_pool: ?*gain.codec_pool.Pool = null,
    live_at_configuration: u32 = 0,
    pub fn configure(self: *Sink, information: gain.media_info.Information) !void {
        if (self.reject_configuration) return error.Cancelled;
        self.information = information;
        if (self.observe_pool) |pool| self.live_at_configuration = pool.statistics.live;
        if (self.fail_reader_on_configure) |reader| reader.fail_on_read = reader.reads + 1;
    }
    pub fn push(self: *Sink, frames: []const Frame) !void {
        self.pushes += 1;
        if (self.cancel_on_push == self.pushes) return error.Cancelled;
        if (frames.len > output.len - self.count) return error.OutputCapacity;
        @memcpy(output[self.count..][0..frames.len], frames);
        self.count += frames.len;
    }
};
fn workspace(pool: *gain.codec_pool.Pool) gain.media_decoder.Workspace {
    return .{
        .packet = .{ .packet = &packet, .page = &page, .pcm = &floats, .frames = &converted, .pool = pool },
        .cache = &cache,
        .compressed = &compressed,
        .left = &left,
        .right = &right,
    };
}
fn decode(case: fixtures.Case, fragment: usize, seek: u64) !Sink {
    var reader = Reader{ .bytes = case.bytes, .fragment = fragment };
    var pool = try gain.codec_pool.Pool.init(&arena);
    var sink = Sink{};
    const information = gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, workspace(&pool), seek) catch |failure| {
        std.debug.print("\n{s}, fragment {d}, seek {d}: {t}\n", .{ case.name, fragment, seek, failure });
        return failure;
    };
    try std.testing.expectEqual(@as(?u64, case.frames), information.total_frames);
    try std.testing.expectEqual(@as(u64, @min(case.frames, seek)), information.start_frame);
    try std.testing.expectEqualStrings(@tagName(case.kind), @tagName(information.kind));
    try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
    try std.testing.expectEqual(case.rate, sink.information.?.sample_rate);
    try std.testing.expectEqual(case.channels, sink.information.?.channels);
    const source_bits = switch (case.kind) {
        .wave, .aiff, .flac, .alac => case.bits,
        else => 32,
    };
    try std.testing.expectEqual(source_bits, sink.information.?.source_bits);
    try std.testing.expectEqual(case.frames - @min(case.frames, seek), sink.count);
    return sink;
}
test "all supported file families decode through the shared canonical PCM producer" {
    for (fixtures.cases) |case| {
        const sink = try decode(case, std.math.maxInt(usize), 0);
        if (case.kind == .alac or case.kind == .flac or case.kind == .wave or case.kind == .aiff) {
            const format = gain.pcm.Sample.Format{ .encoding = .float, .bytes = 4, .valid_bits = 32 };
            for (output[0..sink.count], 0..) |frame, index| {
                const offset = index * case.channels * 4;
                try std.testing.expectEqual(format.decode(case.reference[offset..][0..4]), frame.left);
                try std.testing.expectEqual(if (case.channels == 1) frame.left else format.decode(case.reference[offset + 4 ..][0..4]), frame.right);
            }
        }
        if (case.kind == .aac or case.kind == .alac or case.kind == .vorbis or case.kind == .opus) try std.testing.expectEqualStrings("Gain spike", sink.information.?.title.slice());
    }
}
test "fragmented storage and reset seek retain presentation length and sample order" {
    for (fixtures.cases) |case| {
        const initial = try decode(case, 512, 0);
        @memcpy(baseline[0..initial.count], output[0..initial.count]);
        for ([_]usize{ 1, 7, 511 }) |fragment| {
            const same = try decode(case, fragment, 0);
            try std.testing.expectEqualSlices(Frame, baseline[0..initial.count], output[0..same.count]);
        }
        for ([_]u64{ 1, 4097, case.frames / 2, case.frames - 1, case.frames, case.frames + 1 }) |seek| {
            const after = try decode(case, 31, seek);
            if (case.kind != .aac or std.mem.indexOf(u8, case.name, "nopns") != null)
                try std.testing.expectEqualSlices(Frame, baseline[@intCast(@min(seek, case.frames))..initial.count], output[0..after.count]);
        }
    }
}
test "MP4 wide offsets v1 timing chapters and separated chunks retain independent packet oracle" {
    for ([_]struct { bytes: []const u8, multi: bool }{ .{ .bytes = fixtures.extended, .multi = false }, .{ .bytes = fixtures.multichunk, .multi = true } }) |case| {
        var reader = Reader{ .bytes = case.bytes, .fragment = 3 };
        var source = try Source.init(&reader, case.bytes.len, &cache);
        const track = try gain.mp4.parse(&source);
        var cursor = try gain.mp4.Cursor.init(&track, &source, 0);
        for (fixtures.oracle.aac44, 0..) |expected, index| {
            const current = (try cursor.next(&source)).?;
            try std.testing.expectEqual(if (case.multi) fixtures.oracle.multi_offsets[index] else expected.offset, current.offset);
            try std.testing.expectEqual(expected.size, current.size);
            try std.testing.expectEqual(@as(u64, @intCast(expected.dts)), current.dts);
        }
        try std.testing.expect((try cursor.next(&source)) == null);
        if (!case.multi) {
            const chapters = try gain.mp4.readChapters(&source);
            try std.testing.expectEqual(@as(usize, 2), chapters.count);
            try std.testing.expectEqualStrings("Middle", chapters.entries[1].name[0..chapters.entries[1].len]);
        }
    }
}

test "lossy decoders retain independent reference accuracy and noise substitution energy" {
    for (fixtures.cases) |case| {
        if (case.kind != .aac and case.kind != .mp3 and case.kind != .vorbis and case.kind != .opus) continue;
        const sink = try decode(case, 53, 0);
        var signal: f64 = 0;
        var noise: f64 = 0;
        var actual_energy: f64 = 0;
        for (output[0..sink.count], 0..) |frame, index| {
            for (0..case.channels) |channel| {
                const offset = (index * case.channels + channel) * 4;
                const reference: f32 = @bitCast(std.mem.readInt(u32, case.reference[offset..][0..4], .little));
                // The independent decoder may exceed full scale. The canonical
                // Q1.31 boundary clips these overshoots before output packing.
                const expected: f64 = @max(-1, @min(@as(f64, reference), 2147483647.0 / 2147483648.0));
                const actual = @as(f64, @floatFromInt(if (channel == 0) frame.left else frame.right)) / 2147483648.0;
                const difference = actual - expected;
                signal += @as(f64, expected) * expected;
                noise += difference * difference;
                actual_energy += actual * actual;
            }
        }
        try std.testing.expect(signal > 0);
        // AAC perceptual noise substitution uses decoder-specific random noise.
        // Such files have no sample-for-sample oracle; verify energy, while
        // otherwise identical no-PNS fixtures retain the numerical regression.
        const pns = case.kind == .aac and std.mem.indexOf(u8, case.name, "nopns") == null;
        if (pns) {
            try std.testing.expect(actual_energy > signal * 0.9 and actual_energy < signal * 1.1);
        } else {
            const snr = 10 * std.math.log10(signal / @max(noise, 1e-30));
            const minimum_snr: f64 = if (std.mem.eql(u8, case.name, "layer1")) 110 else 120;
            if (snr < minimum_snr) std.debug.print("{s}: reference SNR {d:.2} dB\n", .{ case.name, snr });
            try std.testing.expect(snr >= minimum_snr);
        }
    }
}
test "cancel and output rejection unwind every live decoder allocation" {
    for (fixtures.cases) |case| {
        for ([_]usize{ 0, 1, 2 }) |stage| {
            var reader = Reader{ .bytes = case.bytes, .fragment = 71 };
            var pool = try gain.codec_pool.Pool.init(&arena);
            var sink = Sink{ .reject_configuration = stage == 0, .cancel_on_push = if (stage == 0) null else stage };
            try std.testing.expectError(error.Cancelled, gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, workspace(&pool), 0));
            try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
            try std.testing.expectEqual(stage, sink.pushes);
        }
        // Reuse the same arena for a fresh session after every cancellation.
        _ = try decode(case, 127, 0);
    }
}
test "storage errors during headers and packets propagate and release C state" {
    for (fixtures.cases) |case| {
        for ([_]usize{ 1, 10, 100 }) |read| {
            var reader = Reader{ .bytes = case.bytes, .fragment = 7, .fail_on_read = read };
            var pool = try gain.codec_pool.Pool.init(&arena);
            var sink = Sink{};
            try std.testing.expectError(error.CardRemoved, gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, workspace(&pool), 0));
            try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
        }
    }
}
test "truncated media fails without retaining decoder state" {
    for (fixtures.cases) |case| {
        for ([_]usize{ 0, 3, 16, case.bytes.len / 2 }) |length| {
            var reader = Reader{ .bytes = case.bytes[0..length], .fragment = 53 };
            var pool = try gain.codec_pool.Pool.init(&arena);
            var sink = Sink{};
            // Keep the declared file length to exercise failures after C init.
            const result = gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, workspace(&pool), 0);
            try std.testing.expectError(error.Truncated, result);
            try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
        }
    }
}
test "overlapping ID3 header and trailer are rejected before offset subtraction" {
    var bytes: [200]u8 = @splat(0);
    @memcpy(bytes[0..10], &[_]u8{ 'I', 'D', '3', 4, 0, 0, 0, 0, 1, 32 }); // 160-byte body.
    @memcpy(bytes[72..75], "TAG");
    var reader = Reader{ .bytes = &bytes };
    var pool = try gain.codec_pool.Pool.init(&arena);
    var sink = Sink{};
    try std.testing.expectError(error.InvalidTag, gain.media_decoder.run(&reader, bytes.len, Sink, &sink, workspace(&pool), 0));
    try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
}

test {
    _ = @import("codec_pipeline_sim.zig");
}

test "scratch capacity and aliases are rejected before any codec or storage work" {
    const case = fixtures.cases[0];
    var reader = Reader{ .bytes = case.bytes };
    var pool = try gain.codec_pool.Pool.init(&arena);
    var sink = Sink{};
    for (0..6) |variant| {
        var scratch = workspace(&pool);
        switch (variant) {
            0 => scratch.packet.packet = packet[0..65536],
            1 => scratch.packet.page = page[0..1],
            2 => scratch.packet.pcm = floats[0..1],
            3 => scratch.packet.frames = converted[0..1],
            4 => scratch.cache = scratch.packet.packet[0..512],
            5 => scratch.right = scratch.left,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidWorkspace, gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, scratch, 0));
        try std.testing.expectEqual(@as(usize, 0), reader.reads);
        try std.testing.expectEqual(@as(u32, 0), pool.statistics.allocations);
    }
}
test "an exhausted decoder pool fails admission without leaked allocations" {
    for (fixtures.cases) |case| {
        if (case.kind != .aac and case.kind != .alac and case.kind != .vorbis and case.kind != .opus) continue;
        var reader = Reader{ .bytes = case.bytes };
        var pool = try gain.codec_pool.Pool.init(arena[0..32]);
        var sink = Sink{};
        try std.testing.expectError(error.OutOfMemory, gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, workspace(&pool), 0));
        try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
        try std.testing.expect(pool.statistics.failures > 0);
    }
}

test "card removal after successful decoder setup unwinds live codec state" {
    for (fixtures.cases) |case| {
        // Small MPEG fixtures fit the decoder's input window before configure.
        if (case.kind == .mp3 and !std.mem.eql(u8, case.name, "stereo-dense")) continue;
        var reader = Reader{ .bytes = case.bytes, .fragment = 71 };
        var pool = try gain.codec_pool.Pool.init(&arena);
        var sink = Sink{ .fail_reader_on_configure = &reader, .observe_pool = &pool };
        var scratch = workspace(&pool);
        scratch.cache = cache[0..512];
        try std.testing.expectError(error.CardRemoved, gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, scratch, 0));
        if (case.kind == .aac or case.kind == .alac or case.kind == .vorbis or case.kind == .opus)
            try std.testing.expect(sink.live_at_configuration > 0);
        try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
    }
}
