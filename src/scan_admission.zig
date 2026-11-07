//! One admission rule for every background SD job, including cover reads.
//! A conservative PCM reserve; it is not a bound on every SD card latency.
const std = @import("std");

pub const reserve_ms = 500;

pub const Conditions = struct {
    started: bool,
    cancelled: bool,
    sample_rate: u32,
    pcm_frames: usize,
};

pub fn admit(c: Conditions) bool {
    return c.started and !c.cancelled and c.sample_rate != 0 and
        c.pcm_frames >= @as(u64, c.sample_rate) * reserve_ms / 1000;
}

/// Refill before borrowing the card, but stop speculative read-ahead once PCM
/// is safe. Container table seeks can repeatedly invalidate the compressed
/// window; waiting for that whole window to fill can starve visible artwork.
pub fn refill(storage: anytype) void {
    while (storage.fillInput()) {
        if (admit(storage.backgroundConditions())) break;
    }
}

test "deterministic PCM simulation reproduces early SD work starving output and protects startup with the real admission rule" {
    // The codec needs card service to continue. A 120 ms background card job
    // started with only 110 ms left drains the actual reservoir before it can
    // refill; input/UI priority cannot preempt an in-flight card operation.
    const pcm = @import("pcm_reservoir.zig");

    const Model = struct {
        storage: [48000]pcm.StereoFrame = undefined,
        output: [3840]u8 align(4) = undefined,
        decoded: [960]pcm.StereoFrame = @splat(.{ .left = 1, .right = 2 }),

        fn run(self: *@This(), legacy: bool) !struct { underruns: u32, jobs: u32 } {
            @memset(&self.storage, .{ .left = 1, .right = 2 });
            var ring = try pcm.Ring.initFilled(&self.storage, 4800);
            const output = @import("audio_output.zig");

            const plan = try output.Plan.initWithPeriod(48000, .signed_24_in_u32, 10000);
            var busy: u32 = 0;
            var jobs: u32 = 0;
            var underruns: u32 = 0;
            for (0..500) |_| {
                if ((try output.renderPeriod(&ring, &self.output, plan, output.unity_gain_q24)).underrun) underruns += 1;
                if (busy > 0) {
                    busy -= 1;
                } else {
                    _ = ring.write(&self.decoded);
                    // A seek may drain compressed input while PCM is still
                    // below high water. All background jobs must use the same
                    // admission test, regardless of who requested the work.
                    if (jobs == 0 and (legacy or admit(.{
                        .started = true,
                        .cancelled = false,
                        .sample_rate = 48000,
                        .pcm_frames = ring.available(),
                    }))) {
                        busy = 12;
                        jobs += 1;
                    }
                }
            }
            return .{ .underruns = underruns, .jobs = jobs };
        }
    };

    const model = try std.testing.allocator.create(Model);
    defer std.testing.allocator.destroy(model);
    const old = try model.run(true);
    try std.testing.expect(old.underruns > 0);
    const fixed = try model.run(false);
    try std.testing.expectEqual(0, fixed.underruns);
    try std.testing.expectEqual(1, fixed.jobs);
}

test "background card work never starts while preparing, stopped or without a known sample rate" {
    try std.testing.expect(!admit(.{ .started = false, .cancelled = false, .sample_rate = 48000, .pcm_frames = 48000 }));
    try std.testing.expect(!admit(.{ .started = true, .cancelled = true, .sample_rate = 48000, .pcm_frames = 48000 }));
    try std.testing.expect(!admit(.{ .started = true, .cancelled = false, .sample_rate = 0, .pcm_frames = 48000 }));
}

test "deterministic container seeks cannot starve cover reads behind speculative compressed refill" {
    const pcm = @import("pcm_reservoir.zig");
    const output = @import("audio_output.zig");
    const Model = struct {
        const Self = @This();
        const Input = @import("input_stream.zig").Stream(Reader, Self);
        const limit_ms = 2000;
        const burst_bytes = 32 * 1024;

        const Reader = struct {
            position: u32 = 0,

            pub fn seekTo(self: *@This(), position: u32) !void {
                self.position = position;
            }

            pub fn read(self: *@This(), bytes: []u8) !usize {
                @memset(bytes, 0x73);
                self.position += @intCast(bytes.len);
                return bytes.len;
            }
        };

        reader: Reader = .{},
        compressed: [256 * 1024]u8 = undefined,
        burst: [burst_bytes]u8 = undefined,
        input: Input = undefined,
        samples: [48000]pcm.StereoFrame = undefined,
        decoded: [1536]pcm.StereoFrame = @splat(.{ .left = 1, .right = 2 }),
        period: [3072]u8 align(4) = undefined,
        reservoir: pcm.Ring = undefined,
        elapsed_ms: u32 = 0,
        reads: u32 = 0,
        jobs: u32 = 0,
        underruns: u32 = 0,
        first_job_ms: ?u32 = null,

        fn advance(self: *Self, milliseconds: u32) !void {
            const plan = try output.Plan.initWithPeriod(48000, .signed_24_in_u32, 8000);
            for (0..milliseconds / 8) |_| {
                if ((try output.renderPeriod(&self.reservoir, &self.period, plan, output.unity_gain_q24)).underrun) self.underruns += 1;
            }
            self.elapsed_ms += milliseconds;
        }

        pub fn backgroundConditions(self: *Self) Conditions {
            return .{ .started = true, .cancelled = false, .sample_rate = 48000, .pcm_frames = self.reservoir.available() };
        }

        pub fn fillInput(self: *Self) bool {
            if (self.elapsed_ms >= limit_ms or !self.input.producerReady(burst_bytes)) return false;
            _ = self.input.produce(&self.burst) catch unreachable;
            self.advance(8) catch unreachable;
            self.reads += 1;
            _ = self.reservoir.write(&self.decoded);
            if (self.reads % 3 == 0) {
                // The higher-priority codec alternates packet/table windows
                // before speculative compressed read-ahead reaches capacity.
                self.input.target = if (self.input.producer_position < 1024 * 1024) 2 * 1024 * 1024 else 0;
                _ = self.input.requested.fetchAdd(1, .release);
            }
            return true;
        }

        pub fn cancelled(_: *Self) bool {
            return false;
        }
        pub fn wakeInput(_: *Self) void {}

        fn run(self: *Self, legacy: bool) !void {
            self.input = try Input.init(&self.reader, 8 * 1024 * 1024, &self.compressed, self);
            @memset(&self.samples, .{ .left = 1, .right = 2 });
            self.reservoir = try pcm.Ring.initFilled(&self.samples, 4800);
            while (self.elapsed_ms < limit_ms) {
                if (legacy) {
                    while (self.fillInput()) {}
                } else refill(self);
                if (self.elapsed_ms >= limit_ms) break;
                if (admit(self.backgroundConditions())) {
                    if (self.first_job_ms == null) self.first_job_ms = self.elapsed_ms;
                    self.jobs += 1;
                    try self.advance(16);
                }
            }
        }
    };

    const legacy = try std.testing.allocator.create(Model);
    defer std.testing.allocator.destroy(legacy);
    legacy.* = .{};
    try legacy.run(true);
    try std.testing.expectEqual(0, legacy.underruns);
    try std.testing.expectEqual(0, legacy.jobs);
    const fixed = try std.testing.allocator.create(Model);
    defer std.testing.allocator.destroy(fixed);
    fixed.* = .{};
    try fixed.run(false);
    try std.testing.expectEqual(0, fixed.underruns);
    try std.testing.expect(fixed.jobs >= 10);
    try std.testing.expect(fixed.first_job_ms.? < 500);
}
