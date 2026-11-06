//! Numeric track boundaries for one continuous PCM stream. The codec publishes
//! a marker before its first frame, output applies gain at that exact sample,
//! and UI retires markers only when DMA has completed the corresponding audio.
const std = @import("std");
const audio = @import("audio_output.zig");
const pcm = @import("pcm_reservoir.zig");
const sample = @import("pcm.zig");
const media = @import("media_info.zig");

pub const capacity = 64;

/// Contains no borrowed catalogue strings. A storage adapter opens this file;
/// the UI resolves its occurrence against its current immutable library view.
pub const Track = struct {
    occurrence: u32 = 0,
    revision: u32 = 0,
    length: u32 = 0,
    gain_q24: u32 = audio.unity_gain_q24,
    source_identity: u64 = 0,

    pub fn valid(self: Track) bool {
        return self.occurrence != 0 and self.length >= 4 and self.gain_q24 <= audio.maximum_gain_q24;
    }
};

/// A codec-to-storage handoff. The codec cannot issue a second open while the
/// storage owner is replacing its reader and input ring. Results are published
/// only after those operations finish; a stale completion cannot acknowledge a
/// later request, including across generation wrap.
pub const SourceSwitch = struct {
    requested: std.atomic.Value(u32) = .init(0),
    acknowledged: std.atomic.Value(u32) = .init(0),
    previous: Track = .{},
    next: ?Track = null,

    pub const Request = struct { generation: u32, previous: Track };

    pub fn request(self: *SourceSwitch, previous: Track) !u32 {
        const generation = self.requested.load(.monotonic);
        if (self.acknowledged.load(.acquire) != generation) return error.SourceSwitchBusy;
        self.previous = previous;
        const next = generation +% 1;
        self.requested.store(next, .release);
        return next;
    }

    pub fn pending(self: *const SourceSwitch) ?Request {
        const generation = self.requested.load(.acquire);
        if (generation == self.acknowledged.load(.monotonic)) return null;
        return .{ .generation = generation, .previous = self.previous };
    }

    pub fn complete(self: *SourceSwitch, generation: u32, next: ?Track) bool {
        if (self.requested.load(.acquire) != generation or self.acknowledged.load(.monotonic) == generation) return false;
        self.next = next;
        self.acknowledged.store(generation, .release);
        return true;
    }

    pub fn ready(self: *const SourceSwitch, generation: u32) bool {
        return self.acknowledged.load(.acquire) == generation;
    }

    pub fn result(self: *const SourceSwitch, generation: u32) ?Track {
        std.debug.assert(self.ready(generation));
        return self.next;
    }
};

/// A seek at/past an actual EOF may decode no PCM. Before output is prepared,
/// retry once at the last real presentation frame. Estimates are never used to
/// trim or fabricate PCM, and a corrupt/empty source cannot create a retry loop.
pub const EndSeek = struct {
    clamped: bool = false,

    pub fn retry(self: *EndSeek, requested: u64, total: ?u64, produced: u64, output_prepared: bool) ?u64 {
        if (self.clamped or requested == 0 or produced != 0 or output_prepared) return null;
        const frames = total orelse return null;
        if (frames == 0 or requested < frames) return null;
        self.clamped = true;
        return frames - 1;
    }
};

pub const Marker = struct {
    track: Track,
    sequence: u64,
    start_frame: u64,
    total_frames: ?u64,
    sample_rate: u32,
    format: sample.OutputFormat,
    source_bits: u8,

    pub fn init(track: Track, sequence: u64, information: media.Information) Marker {
        return .{
            .track = track,
            .sequence = sequence,
            .start_frame = information.start_frame,
            .total_frames = information.total_frames,
            .sample_rate = information.sample_rate,
            .format = information.output_format,
            .source_bits = information.source_bits,
        };
    }

    pub fn position(self: Marker, completed: u64) u64 {
        const frame = self.start_frame +| (completed -| self.sequence);
        return if (self.total_frames) |total| @min(frame, total) else frame;
    }
};

/// The codec is the only producer. UI is the only reclaimer. Output copies each
/// immutable record before UI can reclaim it (DMA completion follows rendering).
/// All publication counters use native 32-bit atomics on the F20.
pub const Markers = struct {
    records: [capacity]Marker = undefined,
    written: std.atomic.Value(u32) = .init(0),
    retired: std.atomic.Value(u32) = .init(0),
    copied: std.atomic.Value(u32) = .init(0),
    last_sequence: ?u64 = null,

    /// Codec-only recovery before output preparation. No renderer or UI may
    /// have copied a marker; image-sized/default record arrays stay untouched.
    pub fn resetBeforeStart(self: *Markers) !void {
        if (self.copied.load(.acquire) != 0 or self.retired.load(.acquire) != 0) return error.MarkerInUse;
        self.written.store(0, .release);
        self.last_sequence = null;
    }

    pub fn free(self: *const Markers) usize {
        return capacity - (self.written.load(.acquire) -% self.retired.load(.acquire));
    }

    pub fn append(self: *Markers, marker: Marker) !void {
        if (marker.track.gain_q24 > audio.maximum_gain_q24 or marker.sample_rate == 0 or (marker.total_frames != null and marker.start_frame > marker.total_frames.?)) return error.InvalidStreamMarker;
        if (self.last_sequence) |previous| if (marker.sequence < previous) return error.NonMonotonicMarker;
        const written = self.written.load(.monotonic);
        if (written -% self.retired.load(.acquire) == capacity) return error.MarkerBackpressure;
        self.records[written % capacity] = marker;
        self.last_sequence = marker.sequence;
        self.written.store(written +% 1, .release);
    }

    fn get(self: *const Markers, sequence: u32) ?Marker {
        if (sequence == self.written.load(.acquire)) return null;
        std.debug.assert(sequence -% self.retired.load(.acquire) < capacity);
        return self.records[sequence % capacity];
    }
};

pub const Audible = struct {
    next: u32 = 0,
    current: ?Marker = null,

    pub fn total(self: *const Audible, markers: *const Markers, final_frames: ?u64) ?u64 {
        const marker = self.current orelse return null;
        if (marker.total_frames) |frames| return frames;
        const end = if (markers.get(self.next)) |following| following.sequence else final_frames orelse return null;
        return marker.start_frame +| (end -| marker.sequence);
    }

    /// Rendering acknowledges its copied frontier separately from DMA. This
    /// also prevents retirement at an exact period edge or during an initially
    /// paused start before output has copied the next marker.
    pub fn advance(self: *Audible, markers: *Markers, completed: u64) ?Marker {
        if (self.next == markers.copied.load(.acquire)) return null;
        const marker = markers.get(self.next) orelse return null;
        if (marker.sequence > completed) return null;
        self.current = marker;
        self.next +%= 1;
        markers.retired.store(self.next, .release);
        return marker;
    }
};

pub const Renderer = struct {
    next: u32 = 0,
    current: ?Marker = null,
    position: u64 = 0,
    quantizer: sample.Sample.Quantizer = .{},

    /// Each bounded span ends at a track boundary, including boundaries inside
    /// a DMA period. Pause consumes neither PCM nor dither state. The source
    /// bit-depth and ReplayGain change with the track, never one period early.
    pub fn render(self: *Renderer, markers: *Markers, reservoir: *pcm.Ring, bytes: []u8, plan: audio.Plan, paused: bool) !audio.Render {
        if (bytes.len != plan.bytes or @intFromPtr(bytes.ptr) & 3 != 0) return error.InvalidOutputBuffer;
        if (paused) {
            @memset(bytes, 0);
            return .{ .frames = 0, .underrun = false };
        }
        var rendered: u32 = 0;
        while (rendered < plan.frames) {
            // Acquire the PCM frontier before reading markers. A marker is
            // published before its PCM; newly arriving samples are left for
            // the next span rather than consumed with an obsolete gain.
            const available = reservoir.available();
            while (markers.get(self.next)) |marker| {
                if (marker.sequence > self.position) break;
                self.current = marker;
                self.next +%= 1;
            }
            markers.copied.store(self.next, .release);
            const marker = self.current orelse return error.MissingStreamMarker;
            if (marker.sample_rate != plan.sample_rate or marker.format != plan.format) return error.StreamFormatChanged;
            if (available == 0) {
                @memset(bytes[@as(usize, rendered) * plan.format.bytesPerFrame() ..], 0);
                return .{ .frames = rendered, .underrun = true };
            }
            var count: u32 = @intCast(@min(plan.frames - rendered, available));
            if (markers.get(self.next)) |following| count = @intCast(@min(count, following.sequence - self.position));
            std.debug.assert(count != 0);
            const span = audio.Plan{ .sample_rate = plan.sample_rate, .format = plan.format, .frames = count, .bytes = count * plan.format.bytesPerFrame() };
            const offset = @as(usize, rendered) * plan.format.bytesPerFrame();
            const output = bytes[offset..][0..span.bytes];
            const result = if (marker.source_bits > 24) try audio.renderPeriodDithered(reservoir, output, span, marker.track.gain_q24, &self.quantizer) else try audio.renderPeriod(reservoir, output, span, marker.track.gain_q24);
            std.debug.assert(!result.underrun);
            rendered += count;
            self.position += count;
        }
        return .{ .frames = rendered, .underrun = false };
    }
};

fn testMarker(occurrence: u32, sequence: u64, gain: u32, bits: u8) Marker {
    return Marker.init(.{ .occurrence = occurrence, .gain_q24 = gain }, sequence, .{ .kind = .wave, .sample_rate = 48000, .channels = 2, .output_format = .signed_24_in_u32, .source_bits = bits });
}

test "non-period boundaries preserve every sample and apply each track gain exactly once" {
    const transport = @import("transport.zig");
    var source: [8000]pcm.StereoFrame = undefined;
    for (&source, 0..) |*frame, i| frame.* = .{ .left = @as(i32, @intCast(i * 136)) << 8, .right = -(@as(i32, @intCast(i * 72)) << 8) };
    var storage: [4096]pcm.StereoFrame = undefined;
    var bytes: [3840]u8 align(4) = undefined;
    const plan = try audio.Plan.init(48000, .signed_24_in_u32);
    for (0..100) |seed| {
        var ring = try pcm.Ring.init(&storage);
        var random = std.Random.DefaultPrng.init(seed);
        var written: usize = 0;
        var consumed: usize = 0;
        var markers = Markers{};
        try markers.append(testMarker(101, 0, audio.unity_gain_q24, 24));
        try markers.append(testMarker(102, 1537, audio.unity_gain_q24 / 2, 24));
        try markers.append(testMarker(103, 4079, audio.unity_gain_q24, 24));
        var renderer = Renderer{};
        var audible = Audible{};
        var timeline = transport.Timeline{};
        while (consumed < source.len) {
            while (ring.available() < @min(plan.frames * 2, source.len - consumed) and written < source.len) {
                const boundary = if (written < 1537) 1537 else if (written < 4079) 4079 else source.len;
                const chunk = @min(boundary - written, 1 + random.random().uintLessThan(usize, 1024));
                written += ring.write(source[written..][0..chunk]);
            }
            const result = try renderer.render(&markers, &ring, &bytes, plan, false);
            if (consumed + plan.frames <= source.len) try std.testing.expect(!result.underrun);
            for (0..result.frames) |i| {
                const position = consumed + i;
                const shift: u5 = if (position >= 1537 and position < 4079) 9 else 8;
                try std.testing.expectEqual(@as(u32, @bitCast(source[position].left >> shift)) & 0xffffff, std.mem.readInt(u32, bytes[i * 8 ..][0..4], .little));
                try std.testing.expectEqual(@as(u32, @bitCast(source[position].right >> shift)) & 0xffffff, std.mem.readInt(u32, bytes[i * 8 + 4 ..][0..4], .little));
            }
            const before = timeline.played.load();
            timeline.queue(0, result.frames);
            try std.testing.expectEqual(before, timeline.played.load());
            timeline.complete(0);
            consumed += result.frames;
            while (audible.advance(&markers, timeline.played.load())) |_| {}
            const expected: u32 = if (consumed < 1537) 101 else if (consumed < 4079) 102 else 103;
            try std.testing.expectEqual(expected, audible.current.?.track.occurrence);
        }
        try std.testing.expectEqual(source.len, consumed);
    }
}

test "pause and track changes preserve quantizer state and full precision source dither" {
    var frames: [960]pcm.StereoFrame = undefined;
    for (&frames, 0..) |*frame, i| frame.* = .{ .left = @bitCast(@as(u32, @truncate(i *% 31337))), .right = @bitCast(@as(u32, @truncate(i *% 617))) };
    var ring = try pcm.Ring.initFilled(&frames, frames.len);
    var reference = try pcm.Ring.initFilled(&frames, frames.len);
    const plan = try audio.Plan.init(48000, .signed_24_in_u32);
    var bytes: [3840]u8 align(4) = undefined;
    var expected: [3840]u8 align(4) = undefined;
    var renderer = Renderer{};
    var markers = Markers{};
    try markers.append(testMarker(1, 0, audio.unity_gain_q24, 32));
    try markers.append(testMarker(2, 37, audio.unity_gain_q24, 32));
    for (0..1000) |_| {
        const got = try renderer.render(&markers, &ring, &bytes, plan, true);
        try std.testing.expectEqual(0, got.frames);
        try std.testing.expectEqual(960, ring.available());
        try std.testing.expectEqual(0, renderer.position);
    }
    var quantizer: sample.Sample.Quantizer = .{};
    _ = try audio.renderPeriodDithered(&reference, &expected, plan, audio.unity_gain_q24, &quantizer);
    _ = try renderer.render(&markers, &ring, &bytes, plan, false);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
    try std.testing.expectEqual(quantizer.random, renderer.quantizer.random);
}

test "marker backpressure retains current audio and recycled records survive 32-bit sequence wrap" {
    var markers = Markers{};
    markers.written.store(0xfffffff0, .monotonic);
    markers.retired.store(0xfffffff0, .monotonic);
    markers.copied.store(0xfffffff0, .monotonic);
    var audible = Audible{ .next = 0xfffffff0 };
    var renderer = Renderer{ .next = 0xfffffff0 };
    const frame: [1]pcm.StereoFrame = @splat(.{ .left = 0, .right = 0 });
    var storage: [1]pcm.StereoFrame = undefined;
    var ring = try pcm.Ring.init(&storage);
    const plan = try audio.Plan.initWithPeriod(48000, .signed_24_in_u32, 125);
    var bytes: [48]u8 align(4) = undefined;
    for (0..64) |i| try markers.append(testMarker(@intCast(i + 1), i, audio.unity_gain_q24, 24));
    try std.testing.expectError(error.MarkerBackpressure, markers.append(testMarker(65, 64, audio.unity_gain_q24, 24)));
    for (0..64) |i| {
        _ = ring.write(&frame);
        _ = try renderer.render(&markers, &ring, &bytes, plan, false);
        _ = audible.advance(&markers, i);
    }
    try std.testing.expectEqual(capacity, markers.free());
    try markers.append(testMarker(65, 64, audio.unity_gain_q24, 24));
    try std.testing.expectEqual(capacity - 1, markers.free());
}

test "an initially paused start and an exact period boundary cannot retire an unread marker" {
    var storage: [960]pcm.StereoFrame = @splat(.{ .left = 0, .right = 0 });
    var ring = try pcm.Ring.initFilled(&storage, storage.len);
    var markers = Markers{};
    try markers.append(testMarker(1, 0, audio.unity_gain_q24, 24));
    try markers.append(testMarker(2, 480, audio.unity_gain_q24, 24));
    var renderer = Renderer{};
    var audible = Audible{};
    var bytes: [3840]u8 align(4) = undefined;
    const plan = try audio.Plan.init(48000, .signed_24_in_u32);
    _ = try renderer.render(&markers, &ring, &bytes, plan, true);
    try std.testing.expectEqual(null, audible.advance(&markers, 0));
    _ = try renderer.render(&markers, &ring, &bytes, plan, false);
    try std.testing.expectEqual(1, audible.advance(&markers, 480).?.track.occurrence);
    try std.testing.expectEqual(null, audible.advance(&markers, 480));
    _ = try renderer.render(&markers, &ring, &bytes, plan, false);
    try std.testing.expectEqual(2, audible.advance(&markers, 480).?.track.occurrence);
}

test "threaded codec publication and DMA completion preserve gain and occurrence through recycled markers" {
    const frame_count = 100_003;
    const track_frames = 17;
    const Harness = struct {
        frames: [1024]pcm.StereoFrame = undefined,
        ring: pcm.Ring = undefined,
        markers: Markers = .{},
        finished: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),
        stop: std.atomic.Value(bool) = .init(false),

        fn produce(self: *@This()) void {
            var position: u32 = 0;
            var published: ?u32 = null;
            while (position < frame_count and !self.stop.load(.acquire)) {
                if (position % track_frames == 0 and published != position) {
                    const track = position / track_frames;
                    const gain = if (track % 2 == 0) audio.unity_gain_q24 else audio.unity_gain_q24 / 2;
                    while (true) {
                        self.markers.append(testMarker(track + 1, position, gain, 24)) catch |failure| {
                            if (failure != error.MarkerBackpressure) {
                                self.failed.store(true, .release);
                                return;
                            }
                            if (self.stop.load(.acquire)) return;
                            std.Thread.yield() catch {};
                            continue;
                        };
                        published = position;
                        break;
                    }
                }
                var batch: [13]pcm.StereoFrame = undefined;
                const count = @min(batch.len, track_frames - position % track_frames, frame_count - position);
                for (batch[0..count], position..) |*frame, i| frame.* = .{ .left = @as(i32, @intCast(i * 16)) << 8, .right = -(@as(i32, @intCast(i * 16)) << 8) };
                position += @intCast(self.ring.write(batch[0..count]));
                std.Thread.yield() catch {};
            }
            self.finished.store(true, .release);
        }
    };
    var harness = Harness{};
    harness.ring = try pcm.Ring.init(&harness.frames);
    const producer = try std.Thread.spawn(.{}, Harness.produce, .{&harness});
    defer {
        harness.stop.store(true, .release);
        producer.join();
    }
    var renderer = Renderer{};
    var audible = Audible{};
    var bytes: [3840]u8 align(4) = undefined;
    const plan = try audio.Plan.init(48000, .signed_24_in_u32);
    var consumed: usize = 0;
    var passed = true;
    while (consumed < frame_count) {
        while (harness.ring.available() < plan.frames and !harness.finished.load(.acquire) and !harness.failed.load(.acquire)) std.Thread.yield() catch {};
        if (harness.failed.load(.acquire)) break;
        const got = try renderer.render(&harness.markers, &harness.ring, &bytes, plan, false);
        for (0..got.frames) |i| {
            const position = consumed + i;
            const value = position * (if ((position / track_frames) % 2 == 0) @as(usize, 16) else 8);
            passed = passed and value == std.mem.readInt(u32, bytes[i * 8 ..][0..4], .little);
            passed = passed and (@as(u32, @bitCast(-@as(i32, @intCast(value)))) & 0xffffff) == std.mem.readInt(u32, bytes[i * 8 + 4 ..][0..4], .little);
        }
        consumed += got.frames;
        while (audible.advance(&harness.markers, consumed)) |_| {}
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!harness.failed.load(.acquire));
    try std.testing.expect(passed);
    try std.testing.expectEqual(frame_count, consumed);
    try std.testing.expectEqual((frame_count - 1) / track_frames + 1, audible.current.?.track.occurrence);
}

test "metadata position is local to the audible track and unknown lengths become known at the next boundary" {
    var markers = Markers{};
    var first = testMarker(1, 0, audio.unity_gain_q24, 24);
    first.start_frame = 1000;
    try markers.append(first);
    try markers.append(testMarker(2, 1537, audio.unity_gain_q24, 24));
    markers.copied.store(2, .release);
    var audible = Audible{};
    const marker = audible.advance(&markers, 1500).?;
    try std.testing.expectEqual(2500, marker.position(1500));
    try std.testing.expectEqual(2537, audible.total(&markers, null).?);
    const second = audible.advance(&markers, 1537).?;
    try std.testing.expectEqual(0, second.position(1537));
    try std.testing.expectEqual(99, audible.total(&markers, 1636).?);
}

test "a changed native rate rejects the boundary before consuming its PCM" {
    var storage: [960]pcm.StereoFrame = @splat(.{ .left = 0, .right = 0 });
    var ring = try pcm.Ring.initFilled(&storage, storage.len);
    var markers = Markers{};
    try markers.append(testMarker(1, 0, audio.unity_gain_q24, 24));
    var changed = testMarker(2, 37, audio.unity_gain_q24, 24);
    changed.sample_rate = 96000;
    try markers.append(changed);
    var renderer = Renderer{};
    var bytes: [3840]u8 align(4) = undefined;
    const plan = try audio.Plan.init(48000, .signed_24_in_u32);
    try std.testing.expectError(error.StreamFormatChanged, renderer.render(&markers, &ring, &bytes, plan, false));
    try std.testing.expectEqual(37, renderer.position);
    try std.testing.expectEqual(storage.len - 37, ring.available());
}

test "source handoff publishes replacement only after storage acknowledgement and rejects stale completions" {
    var source = SourceSwitch{};
    source.requested.store(0xfffffffe, .monotonic);
    source.acknowledged.store(0xfffffffe, .monotonic);
    const first = Track{ .occurrence = 17, .length = 1000 };
    const second = Track{ .occurrence = 18, .length = 2000 };
    const third = Track{ .occurrence = 19, .length = 3000 };
    try std.testing.expectEqual(null, source.pending());
    const a = try source.request(first);
    try std.testing.expect(!source.ready(a));
    try std.testing.expectError(error.SourceSwitchBusy, source.request(first));
    const pending = source.pending().?;
    try std.testing.expectEqual(first, pending.previous);
    try std.testing.expectEqual(a, pending.generation);
    try std.testing.expect(!source.complete(a -% 1, third));
    try std.testing.expect(!source.ready(a));
    try std.testing.expect(source.complete(a, second));
    try std.testing.expect(source.ready(a));
    try std.testing.expectEqual(second, source.result(a).?);
    try std.testing.expectEqual(null, source.pending());
    const b = try source.request(second);
    try std.testing.expectEqual(0, b);
    try std.testing.expect(!source.complete(a, third));
    try std.testing.expect(!source.ready(b));
    try std.testing.expect(source.complete(b, null));
    try std.testing.expectEqual(null, source.result(b));
}

test "final DMA completion exposes every short boundary even when the UI missed the entire last period" {
    const transport = @import("transport.zig");
    var storage: [480]pcm.StereoFrame = @splat(.{ .left = 0, .right = 0 });
    var ring = try pcm.Ring.initFilled(&storage, storage.len);
    var markers = Markers{};
    try markers.append(testMarker(17, 0, audio.unity_gain_q24, 24));
    try markers.append(testMarker(18, 153, audio.unity_gain_q24, 24));
    try markers.append(testMarker(19, 407, audio.unity_gain_q24, 24));
    var renderer = Renderer{};
    var audible = Audible{};
    var timeline = transport.Timeline{};
    var bytes: [3840]u8 align(4) = undefined;
    const plan = try audio.Plan.init(48000, .signed_24_in_u32);
    const rendered = try renderer.render(&markers, &ring, &bytes, plan, false);
    timeline.queue(0, rendered.frames);
    try std.testing.expectEqual(17, audible.advance(&markers, 0).?.track.occurrence);
    try std.testing.expectEqual(null, audible.advance(&markers, 0));
    // No UI poll occurs after this completion. The joined-player final drain
    // must adopt 18 and 19 before EOF chooses any successor from the queue.
    timeline.complete(0);
    try std.testing.expectEqual(18, audible.advance(&markers, timeline.played.load()).?.track.occurrence);
    try std.testing.expectEqual(19, audible.advance(&markers, timeline.played.load()).?.track.occurrence);
    try std.testing.expectEqual(null, audible.advance(&markers, timeline.played.load()));
    try std.testing.expectEqual(19, audible.current.?.track.occurrence);
}

test "mixed source precisions and ReplayGain change at the boundary with one continuous quantizer" {
    var frames: [480]pcm.StereoFrame = undefined;
    for (&frames, 0..) |*frame, i| frame.* = .{ .left = @bitCast(@as(u32, @truncate(i *% 982451653))), .right = @bitCast(@as(u32, @truncate(i *% 32452843))) };
    var ring = try pcm.Ring.initFilled(&frames, frames.len);
    var reference = try pcm.Ring.initFilled(&frames, frames.len);
    var markers = Markers{};
    try markers.append(testMarker(1, 0, audio.unity_gain_q24, 16));
    try markers.append(testMarker(2, 37, audio.unity_gain_q24 / 2, 32));
    try markers.append(testMarker(3, 90, audio.unity_gain_q24, 24));
    var renderer = Renderer{};
    var bytes: [3840]u8 align(4) = undefined;
    var expected: [3840]u8 align(4) = undefined;
    var quantizer: sample.Sample.Quantizer = .{};
    const plan = try audio.Plan.init(48000, .signed_24_in_u32);
    _ = try audio.renderPeriod(&reference, expected[0 .. 37 * 8], .{ .sample_rate = 48000, .format = .signed_24_in_u32, .frames = 37, .bytes = 37 * 8 }, audio.unity_gain_q24);
    _ = try audio.renderPeriodDithered(&reference, expected[37 * 8 .. 90 * 8], .{ .sample_rate = 48000, .format = .signed_24_in_u32, .frames = 53, .bytes = 53 * 8 }, audio.unity_gain_q24 / 2, &quantizer);
    _ = try audio.renderPeriod(&reference, expected[90 * 8 ..], .{ .sample_rate = 48000, .format = .signed_24_in_u32, .frames = 390, .bytes = 390 * 8 }, audio.unity_gain_q24);
    const got = try renderer.render(&markers, &ring, &bytes, plan, false);
    try std.testing.expect(!got.underrun);
    try std.testing.expectEqual(480, got.frames);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
    try std.testing.expectEqual(quantizer.random, renderer.quantizer.random);
}

test "an out-of-range seek retries at the actual last frame only once and never masks an empty or corrupt source" {
    var recovery = EndSeek{};
    try std.testing.expectEqual(null, recovery.retry(100, 1000, 900, false));
    try std.testing.expectEqual(null, recovery.retry(100, 1000, 0, false));
    try std.testing.expectEqual(null, recovery.retry(1000, null, 0, false));
    try std.testing.expectEqual(null, recovery.retry(1000, 0, 0, false));
    try std.testing.expectEqual(null, recovery.retry(0, 1000, 0, false));
    try std.testing.expectEqual(null, recovery.retry(2000, 1000, 0, true));
    try std.testing.expectEqual(999, recovery.retry(2000, 1000, 0, false).?);
    try std.testing.expect(recovery.clamped);
    try std.testing.expectEqual(null, recovery.retry(2000, 1000, 0, false));
    var exact_end = EndSeek{};
    try std.testing.expectEqual(999, exact_end.retry(1000, 1000, 0, false).?);
}

test "zero-PCM seek recovery discards only unconsumed markers before publishing the last valid frame" {
    var markers = Markers{};
    var rejected = testMarker(17, 0, audio.unity_gain_q24, 24);
    rejected.start_frame = 1000;
    rejected.total_frames = 1000;
    try markers.append(rejected);
    var recovery = EndSeek{};
    const target = recovery.retry(2000, 1000, 0, false).?;
    try markers.resetBeforeStart();
    var replacement = rejected;
    replacement.start_frame = target;
    try markers.append(replacement);
    var storage: [1]pcm.StereoFrame = .{.{ .left = 1234 << 8, .right = -1234 << 8 }};
    var ring = try pcm.Ring.initFilled(&storage, 1);
    var renderer = Renderer{};
    var bytes: [3840]u8 align(4) = undefined;
    const plan = try audio.Plan.init(48000, .signed_24_in_u32);
    const rendered = try renderer.render(&markers, &ring, &bytes, plan, false);
    try std.testing.expectEqual(1, rendered.frames);
    try std.testing.expectEqual(1234, std.mem.readInt(u32, bytes[0..4], .little));
    var audible = Audible{};
    const marker = audible.advance(&markers, 1).?;
    try std.testing.expectEqual(1000, marker.position(1));
    try std.testing.expectError(error.MarkerInUse, markers.resetBeforeStart());
}
