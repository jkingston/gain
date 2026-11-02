const std = @import("std");
const playback = @import("playback");
const controls = @import("playback_controls");

const maximum_fifo_frames = 64;
const maximum_latency_samples = 128;

const TieOrder = enum {
    refill_before_audio,
    audio_before_refill,
};

const Handoff = union(enum) {
    linked,
    software_restart: u16,
};

const Config = struct {
    buffers: u8,
    descriptors: u8,
    frames_per_buffer: u16,
    chunks: u32,
    fifo_frames: u8,
    handoff: Handoff = .linked,
    notify_every_descriptors: u8 = 1,
};

const LatencyPlan = struct {
    values: [maximum_latency_samples]u16 = @splat(0),
    count: u8 = 0,
    fallback: u16 = 0,

    fn constant(frames: u16) LatencyPlan {
        return .{ .fallback = frames };
    }

    fn delayFor(self: LatencyPlan, chunk: u32) u16 {
        if (chunk < self.count) return self.values[chunk];
        return self.fallback;
    }
};

const Failure = union(enum) {
    invalid_config,
    scheduler: playback.Error,
    underrun: struct { tick: u32, emitted_frames: u32 },
    sample_order: struct { tick: u32, expected: u32, actual: u32 },
    stalled,
};

const Metrics = struct {
    ticks: u32,
    emitted_frames: u32,
    descriptor_events: u32,
    descriptor_wraps: u32,
    refills_completed: u32,
    minimum_ready_buffers: u8,
};

const Result = union(enum) {
    passed: Metrics,
    failed: Failure,
};

const PendingRefill = struct {
    active: bool = false,
    refill: playback.Refill = .{ .slot = 0, .chunk = 0 },
    complete_tick: u32 = 0,
};

const Fifo = struct {
    frames: [maximum_fifo_frames]u32 = undefined,
    head: u8 = 0,
    length: u8 = 0,

    fn push(self: *Fifo, capacity: u8, frame: u32) void {
        std.debug.assert(self.length < capacity);
        const index = (self.head + self.length) % maximum_fifo_frames;
        self.frames[index] = frame;
        self.length += 1;
    }

    fn pop(self: *Fifo) ?u32 {
        if (self.length == 0) return null;
        const frame = self.frames[self.head];
        self.head = (self.head + 1) % maximum_fifo_frames;
        self.length -= 1;
        return frame;
    }
};

const Simulator = struct {
    config: Config,
    latency: LatencyPlan,
    state: playback.State,
    pending: [playback.maximum_buffers]PendingRefill = @splat(.{}),
    buffer_chunks: [playback.maximum_buffers]u32 = @splat(0),
    fifo: Fifo = .{},
    tick: u32 = 0,
    dma_chunk: u32 = 0,
    emitted: u32 = 0,
    expected_frame: u32 = 0,
    source_offset: u16 = 0,
    restart_ready_tick: u32 = 0,
    descriptor_events: u32 = 0,
    descriptor_wraps: u32 = 0,
    refills_completed: u32 = 0,
    minimum_ready_buffers: u8 = playback.maximum_buffers,

    fn init(config: Config, latency: LatencyPlan) ?Simulator {
        if (config.fifo_frames == 0 or config.fifo_frames > maximum_fifo_frames or
            config.frames_per_buffer == 0 or config.notify_every_descriptors == 0)
        {
            return null;
        }
        const state = playback.State.init(.{
            .buffer_count = config.buffers,
            .descriptor_count = config.descriptors,
            .total_chunks = config.chunks,
        }) catch return null;
        var self = Simulator{ .config = config, .latency = latency, .state = state };
        for (0..config.buffers) |slot| self.buffer_chunks[slot] = @intCast(slot);
        self.updateReadyLowWater();
        return self;
    }

    fn updateReadyLowWater(self: *Simulator) void {
        var ready: u8 = 0;
        for (0..self.config.buffers) |slot_index| {
            if (self.state.slot(@intCast(slot_index)).state == .ready) ready += 1;
        }
        self.minimum_ready_buffers = @min(self.minimum_ready_buffers, ready);
    }

    fn scheduleRefill(self: *Simulator, refill: playback.Refill) ?Failure {
        const pending = &self.pending[refill.slot];
        if (pending.active) return .{ .scheduler = error.InvalidRefill };
        pending.* = .{
            .active = true,
            .refill = refill,
            .complete_tick = self.tick + self.latency.delayFor(refill.chunk),
        };
        return null;
    }

    fn completeRefills(self: *Simulator) ?Failure {
        for (&self.pending) |*pending| {
            if (!pending.active or pending.complete_tick > self.tick) continue;
            self.state.completeRefill(pending.refill) catch |failure| {
                return .{ .scheduler = failure };
            };
            self.buffer_chunks[pending.refill.slot] = pending.refill.chunk;
            pending.active = false;
            self.refills_completed += 1;
        }
        self.updateReadyLowWater();
        return null;
    }

    fn descriptorComplete(self: *Simulator) ?Failure {
        self.dma_chunk += 1;
        const observed: u7 = @intCast(self.dma_chunk % self.config.descriptors);
        if (observed == 0) self.descriptor_wraps += 1;
        self.descriptor_events += 1;
        const should_notify = self.dma_chunk % self.config.notify_every_descriptors == 0 or
            self.dma_chunk == self.config.chunks;
        if (should_notify) {
            const completions = self.state.completionsTo(observed) catch |failure| {
                return .{ .scheduler = failure };
            };
            for (0..completions) |_| {
                const transition = self.state.advance(self.state.nextDescriptor()) catch |failure| {
                    return .{ .scheduler = failure };
                };
                if (transition.refill) |refill| {
                    if (self.scheduleRefill(refill)) |failure| return failure;
                }
            }
        }
        self.source_offset = 0;
        self.restart_ready_tick = self.tick + switch (self.config.handoff) {
            .linked => 0,
            .software_restart => |delay| delay,
        };
        self.updateReadyLowWater();
        return null;
    }

    fn pumpDma(self: *Simulator) ?Failure {
        while (self.fifo.length < self.config.fifo_frames) {
            if (self.dma_chunk >= self.config.chunks) return null;
            if (self.tick < self.restart_ready_tick) return null;
            const slot = self.dma_chunk % self.config.buffers;
            const chunk = self.buffer_chunks[slot];
            const frame = chunk * self.config.frames_per_buffer + self.source_offset;
            self.fifo.push(self.config.fifo_frames, frame);
            self.source_offset += 1;
            if (self.source_offset == self.config.frames_per_buffer) {
                if (self.descriptorComplete()) |failure| return failure;
            }
        }
        return null;
    }

    fn consumeAudio(self: *Simulator) ?Failure {
        const frame = self.fifo.pop() orelse return .{ .underrun = .{
            .tick = self.tick,
            .emitted_frames = self.emitted,
        } };
        if (frame != self.expected_frame) return .{ .sample_order = .{
            .tick = self.tick,
            .expected = self.expected_frame,
            .actual = frame,
        } };
        self.emitted += 1;
        self.expected_frame += 1;
        return null;
    }

    fn run(mut_self: Simulator, tie_order: TieOrder) Result {
        var self = mut_self;
        const total_frames = self.config.chunks * self.config.frames_per_buffer;
        const maximum_ticks = total_frames * 4;
        while (self.emitted < total_frames and self.tick < maximum_ticks) : (self.tick += 1) {
            switch (tie_order) {
                .refill_before_audio => {
                    if (self.completeRefills()) |failure| return .{ .failed = failure };
                    if (self.pumpDma()) |failure| return .{ .failed = failure };
                    if (self.consumeAudio()) |failure| return .{ .failed = failure };
                },
                .audio_before_refill => {
                    if (self.pumpDma()) |failure| return .{ .failed = failure };
                    if (self.consumeAudio()) |failure| return .{ .failed = failure };
                    if (self.completeRefills()) |failure| return .{ .failed = failure };
                },
            }
        }
        if (self.emitted != total_frames) return .{ .failed = .stalled };
        return .{ .passed = .{
            .ticks = self.tick + 1,
            .emitted_frames = self.emitted,
            .descriptor_events = self.descriptor_events,
            .descriptor_wraps = self.descriptor_wraps,
            .refills_completed = self.refills_completed,
            .minimum_ready_buffers = self.minimum_ready_buffers,
        } };
    }
};

fn simulate(config: Config, plan: LatencyPlan, order: TieOrder) Result {
    const simulator = Simulator.init(config, plan) orelse return .{ .failed = .invalid_config };
    return simulator.run(order);
}

fn expectPass(result: Result) !Metrics {
    return switch (result) {
        .passed => |metrics| metrics,
        .failed => |failure| {
            std.debug.print("unexpected simulation failure: {any}\n", .{failure});
            return error.SimulationFailed;
        },
    };
}

test "production scheduler preserves frame order under both tie orders" {
    const config = Config{
        .buffers = 3,
        .descriptors = 12,
        .frames_per_buffer = 64,
        .chunks = 12,
        .fifo_frames = 32,
    };
    for (std.enums.values(TieOrder)) |order| {
        const metrics = try expectPass(simulate(config, LatencyPlan.constant(95), order));
        try std.testing.expectEqual(@as(u32, 768), metrics.emitted_frames);
        try std.testing.expectEqual(@as(u32, 12), metrics.descriptor_events);
        try std.testing.expectEqual(@as(u32, 1), metrics.descriptor_wraps);
    }
}

test "production scheduler preserves order across descriptor page wraps" {
    const config = Config{
        .buffers = 3,
        .descriptors = 120,
        .frames_per_buffer = 64,
        .chunks = 480,
        .fifo_frames = 64,
    };
    for (std.enums.values(TieOrder)) |order| {
        const metrics = try expectPass(simulate(config, LatencyPlan.constant(100), order));
        try std.testing.expectEqual(@as(u32, 480), metrics.descriptor_events);
        try std.testing.expectEqual(@as(u32, 4), metrics.descriptor_wraps);
    }
}

test "software restart exposes the FIFO deadline" {
    const base = Config{
        .buffers = 2,
        .descriptors = 6,
        .frames_per_buffer = 64,
        .chunks = 6,
        .fifo_frames = 32,
        .handoff = .{ .software_restart = 32 },
    };
    _ = try expectPass(simulate(base, LatencyPlan.constant(0), .refill_before_audio));

    var late = base;
    late.handoff = .{ .software_restart = 33 };
    switch (simulate(late, LatencyPlan.constant(0), .refill_before_audio)) {
        .failed => |failure| switch (failure) {
            .underrun => {},
            else => return error.ExpectedUnderrun,
        },
        .passed => return error.ExpectedUnderrun,
    }
}

test "exhaustive bounded refill schedules remain safe" {
    const config = Config{
        .buffers = 3,
        .descriptors = 8,
        .frames_per_buffer = 32,
        .chunks = 8,
        .fifo_frames = 16,
    };

    const choices = [_]u16{ 0, 15, 31, 47 };
    var schedules: u32 = 0;
    for (choices) |a| for (choices) |b| for (choices) |c| for (choices) |d| for (choices) |e| {
        var plan = LatencyPlan{};
        plan.count = 8;
        plan.values[3] = a;
        plan.values[4] = b;
        plan.values[5] = c;
        plan.values[6] = d;
        plan.values[7] = e;
        for (std.enums.values(TieOrder)) |order| {
            _ = try expectPass(simulate(config, plan, order));
            schedules += 1;
        }
    };
    try std.testing.expectEqual(@as(u32, 2_048), schedules);
}

test "refill beyond the ring deadline fails deterministically" {
    const config = Config{
        .buffers = 2,
        .descriptors = 4,
        .frames_per_buffer = 32,
        .chunks = 4,
        .fifo_frames = 8,
    };

    var plan = LatencyPlan.constant(0);
    plan.count = 4;
    plan.values[2] = 64;
    switch (simulate(config, plan, .audio_before_refill)) {
        .failed => |failure| switch (failure) {
            .scheduler, .underrun => {},
            else => return error.ExpectedDeadlineFailure,
        },
        .passed => return error.ExpectedDeadlineFailure,
    }
}

test "measured F20 refill latency has a wide deterministic margin" {
    const config = Config{
        .buffers = 3,
        .descriptors = 120,
        .frames_per_buffer = 2_400,
        .chunks = 480,
        .fifo_frames = 64,
    };

    const measured_worst_case_frames = 193; // 24,014 timer ticks at 48 kHz.
    for (std.enums.values(TieOrder)) |order| {
        const metrics = try expectPass(simulate(
            config,
            LatencyPlan.constant(measured_worst_case_frames),
            order,
        ));
        try std.testing.expectEqual(@as(u32, 480), metrics.descriptor_events);
    }

    _ = try expectPass(simulate(config, LatencyPlan.constant(4_700), .audio_before_refill));
    switch (simulate(config, LatencyPlan.constant(4_900), .audio_before_refill)) {
        .failed => |failure| switch (failure) {
            .scheduler, .underrun => {},
            else => return error.ExpectedDeadlineFailure,
        },
        .passed => return error.ExpectedDeadlineFailure,
    }
}

test "blocking playback display reproduces descriptor overrun" {
    const config = Config{
        .buffers = 3,
        .descriptors = 120,
        .frames_per_buffer = 4_096,
        .chunks = 120,
        .fifo_frames = 64,
        .notify_every_descriptors = 3,
    };
    switch (simulate(config, LatencyPlan.constant(193), .audio_before_refill)) {
        .failed => |failure| switch (failure) {
            .scheduler => |scheduler_failure| try std.testing.expectEqual(
                error.DescriptorOverrun,
                scheduler_failure,
            ),
            else => return error.ExpectedDescriptorOverrun,
        },
        .passed => return error.ExpectedDescriptorOverrun,
    }
}

test "asynchronous display DMA preserves every audio descriptor event" {
    const config = Config{
        .buffers = 3,
        .descriptors = 120,
        .frames_per_buffer = 4_096,
        .chunks = 120,
        .fifo_frames = 64,
        .notify_every_descriptors = 1,
    };
    // LCD DMA progresses independently, so its measured 15.4 ms full-frame
    // duration does not extend the CPU refill latency or hide audio events.
    for (std.enums.values(TieOrder)) |order| {
        const metrics = try expectPass(simulate(config, LatencyPlan.constant(193), order));
        try std.testing.expectEqual(@as(u32, 120), metrics.descriptor_events);
        try std.testing.expectEqual(@as(u32, 120 * 4_096), metrics.emitted_frames);
    }
}

test "asynchronous region DMA preserves 96 kHz playback" {
    const config = Config{
        .buffers = 3,
        .descriptors = 120,
        .frames_per_buffer = 4_096,
        .chunks = 120,
        .fifo_frames = 64,
        .notify_every_descriptors = 1,
    };

    var controller = controls.State.init(64);
    _ = controller.update(0);
    var plan = LatencyPlan.constant(193);
    plan.count = config.chunks;
    var volume_changes: u8 = 0;
    for (0..config.chunks) |chunk| {
        _ = controller.update(0);
        const button = if (chunk & 1 == 0)
            controls.Button.volume_up.mask()
        else
            controls.Button.volume_down.mask();
        switch (controller.update(button)) {
            .set_attenuation => {
                // The measured 18x7 hardware update is 89 us, or fewer than
                // nine 96 kHz frames, while DMA continues independently.
                plan.values[chunk] = 9;
                volume_changes += 1;
            },
            else => return error.ExpectedVolumeChange,
        }
    }
    try std.testing.expectEqual(@as(u8, 120), volume_changes);
    try std.testing.expectEqual(@as(u8, 64), controller.attenuation);

    for (std.enums.values(TieOrder)) |order| {
        const metrics = try expectPass(simulate(config, plan, order));
        try std.testing.expectEqual(@as(u32, 120), metrics.descriptor_events);
        try std.testing.expectEqual(@as(u32, 120 * 4_096), metrics.emitted_frames);
    }
}
