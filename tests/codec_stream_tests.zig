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
    bytes_read: usize = 0,
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
        self.bytes_read += n;
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
    for ([_]struct { bytes: []const u8, multi: bool }{ .{
        .bytes = fixtures.extended,
        .multi = false,
    }, .{ .bytes = fixtures.multichunk, .multi = true } }) |case| {
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
    for (0..7) |variant| {
        var scratch = workspace(&pool);
        switch (variant) {
            0 => scratch.packet.packet = packet[0..65536],
            1 => scratch.packet.page = page[0..1],
            2 => scratch.packet.pcm = floats[0..1],
            3 => scratch.packet.frames = converted[0..1],
            4 => scratch.cache = scratch.packet.packet[0..512],
            5 => scratch.right = scratch.left,
            6 => scratch.seek_index = @ptrCast(&arena),
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

const SeekSink = struct {
    destination: []Frame,
    count: usize = 0,
    stop_when_full: bool = false,
    information: ?gain.media_info.Information = null,

    pub fn configure(self: *@This(), information: gain.media_info.Information) !void {
        self.information = information;
    }
    pub fn push(self: *@This(), frames: []const Frame) !void {
        const count = @min(frames.len, self.destination.len - self.count);
        @memcpy(self.destination[self.count..][0..count], frames[0..count]);
        self.count += count;
        if (self.count == self.destination.len and self.stop_when_full) return error.Cancelled;
        if (count != frames.len) return error.OutputCapacity;
    }
};

fn decodeSeekWindow(bytes: []const u8, index: ?*gain.media_decoder.SeekIndex, identity: u64, target: u64, destination: []Frame, fragment: usize, stop: bool) !usize {
    var reader = Reader{ .bytes = bytes, .fragment = fragment };
    var pool = try gain.codec_pool.Pool.init(&arena);
    var sink = SeekSink{ .destination = destination, .stop_when_full = stop };
    var memory = workspace(&pool);
    memory.seek_index = index;
    memory.seek_source = identity;
    _ = gain.media_decoder.run(&reader, bytes.len, SeekSink, &sink, memory, target) catch |failure| {
        if (!stop or failure != error.Cancelled) return failure;
    };
    try std.testing.expectEqual(48000, sink.information.?.sample_rate);
    try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
    if (stop) try std.testing.expectEqual(destination.len, sink.count);
    return reader.bytes_read;
}

test "cold bisection and cached decoder checkpoints match sequential PCM at distant and adjacent positions" {
    const cases = .{
        @embedFile("fixtures/codecs/seek-12s.flac"),
        @embedFile("fixtures/codecs/seek-12s.mp3"),
        @embedFile("fixtures/codecs/seek-12s.opus"),
        @embedFile("fixtures/codecs/seek-12s.ogg"),
    };
    const reference = try std.testing.allocator.alloc(Frame, 600000);
    defer std.testing.allocator.free(reference);
    var window: [8192]Frame = undefined;
    inline for (cases, 0..) |bytes, kind| {
        var index = gain.media_decoder.SeekIndex{};
        const identity = kind + 1;
        _ = try decodeSeekWindow(bytes, &index, identity, 0, reference, 512, false);
        try std.testing.expect(index.count != 0);
        for ([_]u64{ 1, 48000, 6 * 48000 + 37, 11 * 48000 + 13 }) |target| {
            // Cold and warm paths use the same exact PCM oracle; the reference
            // starts at the presentation origin, including encoder trim.
            _ = try decodeSeekWindow(bytes, null, 0, target, &window, 511, true);
            try std.testing.expectEqualSlices(Frame, reference[@intCast(target)..][0..window.len], &window);
            _ = try decodeSeekWindow(bytes, &index, identity, target, &window, 7, true);
            try std.testing.expectEqualSlices(Frame, reference[@intCast(target)..][0..window.len], &window);
        }
        const sequential_reads = try decodeSeekWindow(bytes, &index, identity, 0, reference, 512, false);
        const warm_reads = try decodeSeekWindow(bytes, &index, identity, 11 * 48000, &window, 512, true);
        try std.testing.expect(warm_reads < sequential_reads);
        // A replacement of equal size still invalidates every learned offset.
        _ = try decodeSeekWindow(bytes, &index, identity + 100, 0, &window, 512, true);
        try std.testing.expectEqual(identity + 100, index.source);
    }
}

test "FLAC embedded seek table is validated against independent frame headers before use" {
    const original = @embedFile("fixtures/codecs/seek-12s.flac");
    const table = @embedFile("fixtures/codecs/seek-table.seektable");
    const info = try gain.flac.parseStreamInfo(original);
    const bytes = try std.testing.allocator.alloc(u8, original.len + table.len);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..info.first_frame_offset], original[0..info.first_frame_offset]);
    var offset: usize = 4;
    while (bytes[offset] & 128 == 0) offset += 4 + std.mem.readInt(u24, bytes[offset + 1 ..][0..3], .big);
    bytes[offset] &= 127;
    @memcpy(bytes[info.first_frame_offset..][0..table.len], table);
    @memcpy(bytes[info.first_frame_offset + table.len ..], original[info.first_frame_offset..]);
    const reference = try std.testing.allocator.alloc(Frame, 600000);
    defer std.testing.allocator.free(reference);
    var window: [8192]Frame = undefined;
    _ = try decodeSeekWindow(original, null, 0, 0, reference, 512, false);
    const target = 11 * 48000 + 37;
    _ = try decodeSeekWindow(bytes, null, 0, target, &window, 17, true);
    try std.testing.expectEqualSlices(Frame, reference[target..][0..window.len], &window);
    // A plausible but false table offset must not shift the presentation time.
    bytes[info.first_frame_offset + 4 + 18 * 5 + 15] ^= 3;
    _ = try decodeSeekWindow(bytes, null, 0, target, &window, 512, true);
    try std.testing.expectEqualSlices(Frame, reference[target..][0..window.len], &window);
}

test "real decoders reuse one pool across gapless track boundaries in the production PCM ring and renderer" {
    const audio = gain.audio_output;
    const sequence = gain.stream_sequence;
    const SequenceSink = struct {
        ring: gain.pcm_reservoir.Ring,
        reference: []const Frame,
        plan: audio.Plan,
        markers: sequence.Markers = .{},
        renderer: sequence.Renderer = .{},
        audible: sequence.Audible = .{},
        timeline: gain.transport.Timeline = .{},
        bytes: [15360]u8 align(4) = undefined,
        quantizer: gain.pcm.Sample.Quantizer = .{},
        produced: u64 = 0,
        consumed: usize = 0,
        occurrence: u32 = 1,
        configured: bool = false,
        source_bits: u8 = 0,

        pub fn configure(self: *@This(), incoming: gain.media_info.Information) !void {
            if (self.configured) return;
            var information = incoming;
            information.output_format = .signed_24_in_u32;
            self.source_bits = information.source_bits;
            try self.markers.append(sequence.Marker.init(.{ .occurrence = self.occurrence }, self.produced, information));
            self.configured = true;
        }
        pub fn push(self: *@This(), frames: []const Frame) !void {
            var done: usize = 0;
            while (done < frames.len) {
                const count = self.ring.write(frames[done..]);
                self.produced += count;
                done += count;
                while (self.ring.available() >= self.plan.frames * 2) try self.consume(false);
                if (count == 0) try self.consume(false);
            }
        }
        fn consume(self: *@This(), final: bool) !void {
            const expected_frames = @min(self.ring.available(), self.plan.frames);
            if (!final) try std.testing.expectEqual(self.plan.frames, expected_frames);
            const result = try self.renderer.render(&self.markers, &self.ring, self.bytes[0..self.plan.bytes], self.plan, false);
            try std.testing.expectEqual(expected_frames, result.frames);
            try std.testing.expectEqual(expected_frames < self.plan.frames, result.underrun);
            for (0..result.frames) |i| {
                const frame = self.reference[(self.consumed + i) % self.reference.len];
                const left_sample = if (self.source_bits > 24) self.quantizer.to24(frame.left, true) else frame.left >> 8;
                const right_sample = if (self.source_bits > 24) self.quantizer.to24(frame.right, true) else frame.right >> 8;
                try std.testing.expectEqual(@as(u32, @bitCast(left_sample)) & 0xffffff, std.mem.readInt(u32, self.bytes[i * 8 ..][0..4], .little));
                try std.testing.expectEqual(@as(u32, @bitCast(right_sample)) & 0xffffff, std.mem.readInt(u32, self.bytes[i * 8 + 4 ..][0..4], .little));
            }
            self.timeline.queue(0, result.frames);
            self.timeline.complete(0);
            self.consumed += result.frames;
            while (self.audible.advance(&self.markers, self.timeline.played.load())) |_| {}
            // At an exact period edge B may not have been rendered/copied yet;
            // metadata must not retire a marker that output has not acquired.
            if (self.consumed != self.reference.len) try std.testing.expectEqual(if (self.consumed > self.reference.len) @as(u32, 2) else 1, self.audible.current.?.track.occurrence);
        }
    };
    var storage: [8192]Frame = undefined;
    for (fixtures.cases) |case| {
        _ = try decode(case, 512, 0);
        @memcpy(baseline[0..case.frames], output[0..case.frames]);
        var pool = try gain.codec_pool.Pool.init(&arena);
        var sink = SequenceSink{ .ring = try gain.pcm_reservoir.Ring.init(&storage), .reference = baseline[0..case.frames], .plan = try audio.Plan.init(case.rate, .signed_24_in_u32) };
        for (0..2) |track| {
            var reader = Reader{ .bytes = case.bytes, .fragment = 71 };
            sink.occurrence = @intCast(track + 1);
            sink.configured = false;
            const information = try gain.media_decoder.run(&reader, case.bytes.len, SequenceSink, &sink, workspace(&pool), 0);
            try std.testing.expectEqual(case.frames, information.total_frames.?);
            try std.testing.expectEqual(@as(u32, 0), pool.statistics.live);
            try std.testing.expectEqual((track + 1) * case.frames, sink.produced);
        }
        while (sink.ring.available() != 0) try sink.consume(true);
        try std.testing.expectEqual(case.frames * 2, sink.consumed);
        try std.testing.expectEqual(sink.produced, sink.timeline.played.load());
        try std.testing.expectEqual(sink.quantizer.random, sink.renderer.quantizer.random);
    }
}

test "cancelled cold seeks release decoder state and retain retryable checkpoint caches" {
    const cases = .{
        @embedFile("fixtures/codecs/seek-12s.flac"),
        @embedFile("fixtures/codecs/seek-12s.mp3"),
        @embedFile("fixtures/codecs/seek-12s.opus"),
        @embedFile("fixtures/codecs/seek-12s.ogg"),
    };
    var window: [8192]Frame = undefined;
    inline for (cases, 0..) |bytes, identity| {
        var index = gain.media_decoder.SeekIndex{};
        for ([_]usize{ 3, 37, 4000 }) |read| {
            var reader = Reader{ .bytes = bytes, .fragment = 7, .fail_on_read = read };
            var pool = try gain.codec_pool.Pool.init(&arena);
            var sink = SeekSink{ .destination = &window, .stop_when_full = true };
            var memory = workspace(&pool);
            memory.seek_index = &index;
            memory.seek_source = identity + 1;
            try std.testing.expectError(error.CardRemoved, gain.media_decoder.run(&reader, bytes.len, SeekSink, &sink, memory, 11 * 48000));
            try std.testing.expectEqual(0, pool.statistics.live);
        }
        _ = try decodeSeekWindow(bytes, &index, identity + 1, 11 * 48000, &window, 512, true);
    }
}

test "FLAC startup skips bounded large metadata without transferring artwork through the decoder" {
    const original = @embedFile("fixtures/codecs/seek-12s.flac");
    const info = try gain.flac.parseStreamInfo(original);
    const padding_bytes = 1024 * 1024;
    const bytes = try std.testing.allocator.alloc(u8, original.len + 4 + padding_bytes);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..info.first_frame_offset], original[0..info.first_frame_offset]);
    var offset: usize = 4;
    while (bytes[offset] & 128 == 0) offset += 4 + std.mem.readInt(u24, bytes[offset + 1 ..][0..3], .big);
    bytes[offset] &= 127;
    const start = info.first_frame_offset;
    bytes[start] = 0x81; // Last metadata block: PADDING.
    std.mem.writeInt(u24, bytes[start + 1 ..][0..3], padding_bytes, .big);
    @memset(bytes[start + 4 ..][0..padding_bytes], 0);
    @memcpy(bytes[start + 4 + padding_bytes ..], original[start..]);
    var window: [8192]Frame = undefined;
    const reads = try decodeSeekWindow(bytes, null, 0, 0, &window, 512, true);
    try std.testing.expect(reads < 65536);
    var bad = Reader{ .bytes = bytes[0 .. start + 4] };
    var pool = try gain.codec_pool.Pool.init(&arena);
    var sink = Sink{};
    try std.testing.expectError(error.Truncated, gain.media_decoder.run(&bad, bad.bytes.len, Sink, &sink, workspace(&pool), 0));
}

test "single-stream Ogg exposes exact footer duration before producing PCM and chains remain unknown" {
    const HeaderSink = struct {
        information: ?gain.media_info.Information = null,
        pub fn configure(self: *@This(), information: gain.media_info.Information) !void {
            self.information = information;
            return error.Cancelled;
        }
        pub fn push(_: *@This(), _: []const Frame) !void {
            return error.UnexpectedPcm;
        }
    };
    for (fixtures.cases) |case| {
        if (case.kind != .opus and case.kind != .vorbis) continue;
        var reader = Reader{ .bytes = case.bytes, .fragment = 31 };
        var pool = try gain.codec_pool.Pool.init(&arena);
        var sink = HeaderSink{};
        try std.testing.expectError(error.Cancelled, gain.media_decoder.run(&reader, case.bytes.len, HeaderSink, &sink, workspace(&pool), 0));
        try std.testing.expectEqual(0, pool.statistics.live);
        if (std.mem.indexOf(u8, case.name, "chain") == null) {
            try std.testing.expectEqual(@as(?u64, case.frames), sink.information.?.total_frames);
        } else try std.testing.expectEqual(null, sink.information.?.total_frames);
    }
}

test "Ogg footer probing retains split capture words, validates full CRC and rejects another serial" {
    const Memory = struct {
        bytes: []const u8,
        length: u64,
        pub fn read(self: *@This(), offset: u64, out: []u8) !void {
            if (offset > self.length or out.len > self.length - offset) return error.Truncated;
            @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
        }
    };
    var bytes: [65536]u8 = undefined;
    for ([_]usize{ 1, 254, 255, 256, 997, 998, 999, 1000, 1001, 1015, 1024, 4096, 65024 }) |body| {
        @memset(&bytes, 0);
        const segments = body / 255 + 1;
        const size = 27 + segments + body;
        const page_bytes = bytes[64..][0..size];
        @memcpy(page_bytes[0..4], "OggS");
        page_bytes[5] = 4;
        std.mem.writeInt(u64, page_bytes[6..14], 48000, .little);
        std.mem.writeInt(u32, page_bytes[14..18], 17, .little);
        std.mem.writeInt(u32, page_bytes[18..22], 3, .little);
        page_bytes[26] = @intCast(segments);
        @memset(page_bytes[27..][0 .. segments - 1], 255);
        page_bytes[27 + segments - 1] = @intCast(body % 255);
        @memset(page_bytes[27 + segments ..], 0x63);
        std.mem.writeInt(u32, page_bytes[22..26], gain.ogg.crc(0, page_bytes), .little);
        var memory = Memory{ .bytes = &bytes, .length = size + 64 };
        try std.testing.expectEqual(@as(?u64, 48000), try gain.ogg.finalGranule(&memory, 17));
        try std.testing.expectEqual(null, try gain.ogg.finalGranule(&memory, 18));
        page_bytes[size - 1] ^= 1;
        try std.testing.expectEqual(null, try gain.ogg.finalGranule(&memory, 17));
    }
}

test "past-end seek recovery reuses the decoder pool and returns the actual last sample" {
    for (fixtures.cases) |case| {
        const original = try decode(case, 512, 0);
        const last_sample = output[original.count - 1];
        var reader = Reader{ .bytes = case.bytes, .fragment = 31 };
        var pool = try gain.codec_pool.Pool.init(&arena);
        var sink = Sink{};
        const requested = case.frames + 4096;
        const end = try gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, workspace(&pool), requested);
        try std.testing.expectEqual(0, sink.count);
        try std.testing.expectEqual(0, pool.statistics.live);
        var recovery = gain.stream_sequence.EndSeek{};
        const target = recovery.retry(requested, end.total_frames, sink.count, false).?;
        try std.testing.expectEqual(case.frames - 1, target);
        sink = .{};
        const after = try gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, workspace(&pool), target);
        try std.testing.expectEqual(1, sink.count);
        try std.testing.expectEqual(target, after.start_frame);
        try std.testing.expectEqual(0, pool.statistics.live);
        if (case.kind != .aac or std.mem.indexOf(u8, case.name, "nopns") != null) try std.testing.expectEqual(last_sample, output[0]);
        try std.testing.expectEqual(null, recovery.retry(requested, end.total_frames, 0, false));
        sink = .{ .reject_configuration = true };
        try std.testing.expectError(error.Cancelled, gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, workspace(&pool), target));
        try std.testing.expectEqual(0, pool.statistics.live);
    }
}
