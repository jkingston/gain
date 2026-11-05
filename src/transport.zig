//! Output-side pause and position policy. Silence keeps the DAC clock locked;
//! PCM and codec state remain intact. Position advances only on DMA completion.
const std = @import("std");
const audio = @import("audio_output.zig");
const pcm = @import("pcm_reservoir.zig");
const sample = @import("pcm.zig");

/// A seqlock built from native 32-bit atomics; no 64-bit atomic runtime is
/// required on MIPS. The output task is the sole writer; readers must run at
/// lower priority so they cannot spin while preempting an in-progress write.
pub const Position = struct {
    generation: std.atomic.Value(u32) = .init(0),
    low: std.atomic.Value(u32) = .init(0),
    high: std.atomic.Value(u32) = .init(0),

    pub fn store(self: *Position, value: u64) void {
        _ = self.generation.fetchAdd(1, .acq_rel);
        self.low.store(@truncate(value), .monotonic);
        self.high.store(@truncate(value >> 32), .monotonic);
        _ = self.generation.fetchAdd(1, .release);
    }

    pub fn load(self: *const Position) u64 {
        while (true) {
            const before = self.generation.load(.acquire);
            if (before & 1 != 0) continue;
            const low = self.low.load(.monotonic);
            const high = self.high.load(.monotonic);
            const after = self.generation.load(.acquire);
            if (before == after) return @as(u64, high) << 32 | low;
        }
    }
};

pub const Timeline = struct {
    frames: [4]u32 = @splat(0),
    played: Position = .{},

    pub fn queue(self: *Timeline, slot: u8, frames: u32) void {
        self.frames[slot] = frames;
    }

    pub fn complete(self: *Timeline, slot: u8) void {
        self.played.store(self.played.load() + self.frames[slot]);
        self.frames[slot] = 0;
    }
};

pub fn render(reservoir: *pcm.Ring, bytes: []u8, plan: audio.Plan, gain: u32, quantizer: *sample.Sample.Quantizer, dither: bool, paused: bool) !audio.Render {
    if (paused) {
        if (bytes.len != plan.bytes or @intFromPtr(bytes.ptr) & 3 != 0) return error.InvalidOutputBuffer;
        @memset(bytes, 0);
        return .{ .frames = 0, .underrun = false };
    }
    return if (dither) audio.renderPeriodDithered(reservoir, bytes, plan, gain, quantizer) else audio.renderPeriod(reservoir, bytes, plan, gain);
}

test "pause preserves exact PCM, queued progress and quantizer state across arbitrary holds" {
    var frames: [960]pcm.StereoFrame = undefined;
    for (&frames, 0..) |*frame, i| frame.* = .{ .left = @bitCast(@as(u32, @truncate(i *% 31337))), .right = @bitCast(@as(u32, @truncate(i *% 617))) };
    var ring = try pcm.Ring.initFilled(&frames, frames.len);
    const plan = try audio.Plan.init(48000, .signed_24_in_u32);
    var bytes: [3840]u8 align(4) = undefined;
    var expected: [3840]u8 align(4) = undefined;
    var quantizer: sample.Sample.Quantizer = .{};
    var reference_quantizer = quantizer;
    var timeline: Timeline = .{};
    timeline.played.store(0xfffffff0);
    for (0..1000) |i| {
        const result = try render(&ring, &bytes, plan, audio.unity_gain_q24, &quantizer, true, true);
        try std.testing.expectEqual(0, result.frames);
        try std.testing.expectEqual(960, ring.available());
        try std.testing.expect(std.mem.allEqual(u8, &bytes, 0));
        timeline.queue(@intCast(i % 3), result.frames);
        timeline.complete(@intCast(i % 3));
    }
    try std.testing.expectEqual(0xfffffff0, timeline.played.load());
    var reference = try pcm.Ring.initFilled(&frames, frames.len);
    _ = try audio.renderPeriodDithered(&reference, &expected, plan, audio.unity_gain_q24, &reference_quantizer);
    const result = try render(&ring, &bytes, plan, audio.unity_gain_q24, &quantizer, true, false);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
    timeline.queue(0, result.frames);
    try std.testing.expectEqual(0xfffffff0, timeline.played.load());
    timeline.complete(0);
    try std.testing.expectEqual(@as(u64, 0xfffffff0) + 480, timeline.played.load());
}

test "seeded pause and DMA wraps preserve every frame and the completed cursor" {
    const lifecycle = @import("playback.zig");
    var source: [2048]pcm.StereoFrame = undefined;
    for (&source, 0..) |*frame, i| frame.* = .{ .left = @as(i32, @intCast(i)) << 16, .right = -(@as(i32, @intCast(i)) << 16) };
    var ring = try pcm.Ring.initFilled(&source, source.len);
    const plan = try audio.Plan.initWithPeriod(8000, .signed_16_packed, 1000);
    var buffers: [3][32]u8 align(4) = undefined;
    var timeline: Timeline = .{};
    var quantizer: sample.Sample.Quantizer = .{};
    var dma = try lifecycle.State.init(.{ .buffer_count = 3, .descriptor_count = 120, .total_chunks = 0xffffffff });
    for (0..3) |i| {
        const got = try render(&ring, &buffers[i], plan, audio.unity_gain_q24, &quantizer, false, false);
        timeline.queue(@intCast(i), got.frames);
    }
    var random = std.Random.DefaultPrng.init(0x5041555345);
    var expected: usize = 0;
    for (0..10000) |_| {
        const slot: u8 = @intCast(dma.chunks_completed % 3);
        const frames = timeline.frames[slot];
        for (0..frames) |i| {
            const word = std.mem.readInt(u32, buffers[slot][i * 4 ..][0..4], .little);
            const left: i16 = @bitCast(@as(u16, @truncate(word)));
            const right: i16 = @bitCast(@as(u16, @truncate(word >> 16)));
            try std.testing.expectEqual(@as(i16, @intCast(expected)), left);
            try std.testing.expectEqual(-@as(i16, @intCast(expected)), right);
            expected += 1;
        }
        const transition = try dma.advance(dma.nextDescriptor());
        timeline.complete(slot);
        try std.testing.expectEqual(expected, timeline.played.load());
        if (expected == source.len) break;
        const refill = transition.refill.?;
        const paused = random.random().boolean();
        const before = ring.available();
        const got = try render(&ring, &buffers[refill.slot], plan, audio.unity_gain_q24, &quantizer, false, paused);
        if (paused) try std.testing.expectEqual(before, ring.available());
        timeline.queue(refill.slot, got.frames);
        try dma.completeRefill(refill);
    }
    try std.testing.expectEqual(source.len, expected);
}
