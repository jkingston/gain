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
