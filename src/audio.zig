const x1000 = @import("x1000.zig");
const i2c = @import("i2c.zig");
const dac_lock = @import("dac_lock.zig");
const es9018 = @import("es9018k2m.zig");
const frontier = @import("pdma_frontier.zig");
const output_route = @import("output_route.zig");
pub const Output = output_route.Output;
pub const Processing = struct { filter: es9018.Filter = .fast, iir_bypass: bool = false, deemphasis: es9018.Deemphasis = .off };

pub const maximum_descriptors = 128;
pub const maximum_buffers = 4;

pub const SampleFormat = enum {
    /// Two little-endian signed 16-bit channels packed into each DMA word and
    /// serialized in the F20's fixed 32-bit I2S channel slots.
    pcm_s16_packed,
    /// One signed 24-bit channel in the low bits of each 32-bit DMA word and
    /// serialized in a 32-bit I2S channel slot.
    pcm_s24,

    pub fn bytesPerFrame(self: SampleFormat) u8 {
        return switch (self) {
            .pcm_s16_packed => 4,
            .pcm_s24 => 8,
        };
    }

    fn aicControl(self: SampleFormat) u32 {
        return switch (self) {
            .pcm_s16_packed => x1000.Aic.packed_16_bit | x1000.Aic.stereo |
                x1000.Aic.output_16_bit | x1000.Aic.input_16_bit,
            .pcm_s24 => x1000.Aic.stereo |
                x1000.Aic.output_24_bit | x1000.Aic.input_24_bit,
        };
    }
};

pub const Error = error{
    InvalidConfig,
    CachedDmaMemory,
    DescriptorPageAlignment,
    AudioFifoTimeout,
    DacCommunication,
    DacVerification,
    DacLockTimeout,
    AudioBusy,
    InvalidDescriptorOffset,
    DmaObservationTimeout,
};

pub const Buffer = struct {
    address: usize,
};

pub const Config = struct {
    descriptor_count: u8,
    buffer_count: u8,
    chunk_bytes: u24,
    sample_format: SampleFormat = .pcm_s16_packed,

    pub fn valid(self: Config) bool {
        return self.descriptor_count >= self.buffer_count and
            self.descriptor_count <= maximum_descriptors and
            self.buffer_count >= 2 and self.buffer_count <= maximum_buffers and
            self.descriptor_count % self.buffer_count == 0 and
            self.chunk_bytes != 0 and
            self.chunk_bytes % self.sample_format.bytesPerFrame() == 0;
    }
};

pub const Event = struct {
    descriptor: ?u7 = null,
    fifo_level: u7,
    underrun: bool,
    dma_fault: bool,
};

/// Native F20 audio output. Buffer ownership remains in `playback.State`; this
/// type only configures hardware and reports descriptor/fault events.
pub fn Engine(comptime Board: type) type {
    return struct {
        const Self = @This();
        const channel = x1000.Pdma.Channel(0);
        const Dac = es9018.Device(i2c.Bus);

        pub const Resources = struct {
            descriptors: *align(4096) volatile [maximum_descriptors]x1000.Pdma.Descriptor,
            buffers: [maximum_buffers]Buffer,
        };

        resources: Resources,
        config: Config,
        minimum_fifo_level: u7 = 64,
        underrun_count: u32 = 0,
        dac_identity: u8 = 0,
        dac: ?Dac = null,
        rate: ?Board.SampleRate = null,
        route: output_route.State = .{},
        running: bool = false,
        cursor: frontier.Cursor = .{},
        lock: dac_lock.State = .{},

        pub fn init(resources: Resources, config: Config) Error!Self {
            if (!config.valid()) return error.InvalidConfig;
            if (!x1000.isUncachedAddress(@intFromPtr(resources.descriptors))) {
                return error.CachedDmaMemory;
            }
            if (@intFromPtr(resources.descriptors) & 0xfff != 0) {
                return error.DescriptorPageAlignment;
            }
            for (resources.buffers[0..config.buffer_count]) |buffer| {
                if (!x1000.isUncachedAddress(buffer.address) or buffer.address & 3 != 0) {
                    return error.CachedDmaMemory;
                }
            }
            return .{ .resources = resources, .config = config };
        }

        pub fn initialize(self: *Self, rate: Board.SampleRate, attenuation: u8) Error!void {
            self.safePins();
            self.running = false;
            self.route = .{};
            self.rate = rate;
            errdefer self.powerDown();
            x1000.Gpio.selectFunction1(.b, Board.i2s_port_b_function_1);
            x1000.Cpm.ungate(.aic);
            x1000.Aic.configuration.write(x1000.Aic.reset);
            x1000.Aic.i2s_control.write(x1000.Aic.stop_bit_clock);
            x1000.Aic.configuration.write(
                x1000.Aic.receive_threshold_15 | x1000.Aic.transmit_threshold_16 |
                    x1000.Aic.play_last_sample | x1000.Aic.external_codec |
                    x1000.Aic.drive_bit_clock | x1000.Aic.drive_frame_clock,
            );
            x1000.Aic.common_control.write(0);
            x1000.Aic.spdif_enable.write(0);
            self.configureClock(rate);
            x1000.Aic.i2s_control.set(x1000.Aic.master_clock_enable);
            x1000.Aic.configuration.set(x1000.Aic.controller_enable);
            x1000.Timer.delayMicroseconds(10_000);

            Board.dac_analog_power.set(true);
            Board.amplifier_power.set(true);
            x1000.Aic.common_control.set(x1000.Aic.playback_enable);
            for (0..dac_warmup_samples) |_| x1000.Aic.data.write(dac_warmup_word);
            try drainFifo(dac_warmup_timeout_ms);
            x1000.Aic.common_control.clear(x1000.Aic.playback_enable);

            Board.output_select.set(false);
            Board.amplifier_shutdown.set(true);
            x1000.Timer.delayMicroseconds(10_000);
            Board.dac_power.set(true);
            x1000.Timer.delayMicroseconds(10_000);
            try self.configureDac(attenuation);
            // Prime lock with silence before any caller-owned PCM is consumed.
            // Waiting after DMA starts would silently discard the track opening.
            try self.acquireLock();
        }

        pub fn start(self: *Self) Error!void {
            errdefer self.stop();
            self.cursor = .{};
            self.buildDescriptorRing();
            x1000.memoryBarrier();

            x1000.Aic.common_control.write(self.config.sample_format.aicControl());
            x1000.Aic.clearTransmitUnderrun();
            x1000.Cpm.ungate(.pdma);
            x1000.Pdma.control.write(0);
            channel.status.write(0);
            x1000.Pdma.doorbell.write(0);
            x1000.Pdma.acknowledgeDescriptors(x1000.Pdma.channel_0);
            x1000.Pdma.interrupt_pending.write(0);
            x1000.Pdma.control.write(x1000.Pdma.enabled_with_request_forwarding);

            channel.descriptor_address.write(x1000.physicalAddress(@intFromPtr(self.resources.descriptors)));
            channel.status.write(x1000.Pdma.status_descriptor_8_words);
            x1000.Pdma.doorbell.set(x1000.Pdma.channel_0);
            channel.status.set(x1000.Pdma.status_enabled);

            const started = x1000.Timer.now();
            x1000.Aic.common_control.set(x1000.Aic.transmit_dma);
            while (x1000.Aic.transmitLevel() < fifo_prefill_frames) {
                if (x1000.Timer.elapsed(started) > x1000.Timer.milliseconds(fifo_prefill_timeout_ms)) {
                    return error.AudioFifoTimeout;
                }
            }
            self.minimum_fifo_level = x1000.Aic.transmitLevel();
            x1000.Aic.clearTransmitUnderrun();
            x1000.Aic.common_control.set(x1000.Aic.playback_enable);
            x1000.Timer.delayMicroseconds(100);
            x1000.Aic.clearTransmitUnderrun();
            x1000.Aic.common_control.set(x1000.Aic.transmit_underrun_interrupt);
            self.running = true;
            self.dac.?.setMute(false) catch |failure| return dacError(failure);
            Board.output_mute.set(self.route.current == .muted);
        }

        pub fn poll(self: *Self) Error!Event {
            const event = try self.pollDma();
            try self.pollControl();
            return event;
        }
        /// No I2C operations: safe in the highest-priority output task while
        /// the control task owns DAC/routing transactions.
        pub fn pollDma(self: *Self) Error!Event {
            const fifo_level = x1000.Aic.transmitLevel();
            self.minimum_fifo_level = @min(self.minimum_fifo_level, fifo_level);
            const aic_status = x1000.Aic.status.read();
            const underrun = aic_status & x1000.Aic.transmit_underrun != 0;
            if (underrun) {
                self.underrun_count +%= 1;
                x1000.Aic.clearTransmitUnderrun();
            }

            var dma_status = channel.status.read();
            var descriptor: ?u7 = null;
            if (x1000.Pdma.descriptor_pending.read() & x1000.Pdma.channel_0 != 0) {
                var addresses: [maximum_buffers]u32 = undefined;
                for (self.resources.buffers[0..self.config.buffer_count], 0..) |buffer, index| addresses[index] = @intCast(buffer.address);
                var resolved = false;
                // A descriptor fetch can update DSA and CDOA separately. Keep
                // the interrupt pending if four bounded samples are unstable.
                for (0..4) |_| {
                    dma_status = channel.status.read();
                    const source = channel.source.read();
                    const after = channel.status.read();
                    const observed = frontier.observe(.{
                        .link_before = @truncate(dma_status >> 8),
                        .source = source,
                        .link_after = @truncate(after >> 8),
                    }, self.config.descriptor_count, addresses[0..self.config.buffer_count], self.config.chunk_bytes) catch return error.InvalidDescriptorOffset;
                    if (observed) |value| {
                        x1000.Pdma.acknowledgeDescriptors(x1000.Pdma.channel_0);
                        descriptor = self.cursor.update(value);
                        resolved = true;
                        break;
                    }
                }
                if (!resolved) try self.cursor.unresolved(x1000.Timer.now(), x1000.Timer.milliseconds(1));
            }
            return .{
                .descriptor = descriptor,
                .fifo_level = fifo_level,
                .underrun = underrun,
                .dma_fault = dma_status & (x1000.Pdma.status_address_error |
                    x1000.Pdma.status_halted) != 0,
            };
        }

        pub fn pollControl(self: *Self) Error!void {
            var backend = RouteBackend{ .engine = self };
            try self.route.poll(&backend, x1000.Timer.milliseconds(10));
        }
        /// Stop supplying new frames while allowing queued I2S samples to drain.
        pub fn haltDma(_: *Self) void {
            x1000.Cpm.ungate(.pdma);
            channel.status.write(0);
            x1000.Aic.common_control.clear(x1000.Aic.transmit_dma | x1000.Aic.transmit_underrun_interrupt);
        }
        pub fn finish(self: *Self) Error!void {
            self.haltDma();
            defer self.stop();
            try drainFifo(dac_warmup_timeout_ms);
        }

        pub fn stop(self: *Self) void {
            self.running = false;
            Board.output_mute.set(true);
            // `stop` is safe before `start`; a clean boot leaves PDMA gated and
            // touching its registers in that state stalls the X1000 bus.
            x1000.Cpm.ungate(.pdma);
            channel.status.write(0);
            x1000.Pdma.doorbell.write(0);
            x1000.Pdma.acknowledgeDescriptors(x1000.Pdma.channel_0);
            x1000.Pdma.interrupt_pending.write(0);
            drainFifo(dac_warmup_timeout_ms) catch {};
            x1000.Aic.common_control.clear(
                x1000.Aic.transmit_dma | x1000.Aic.transmit_underrun_interrupt |
                    x1000.Aic.playback_enable,
            );
            self.powerDown();
        }

        fn safePins(_: *Self) void {
            Board.amplifier_shutdown.output(false);
            Board.output_mute.output(true);
            Board.dac_power.output(false);
            Board.dac_analog_power.output(false);
            Board.amplifier_power.output(false);
            Board.output_select.output(false);
        }

        fn powerDown(self: *Self) void {
            self.dac = null;
            self.lock = .{};
            Board.output_mute.set(true);
            x1000.Timer.delayMicroseconds(10_000);
            Board.dac_power.set(false);
            Board.amplifier_shutdown.set(false);
            Board.amplifier_power.set(false);
            Board.dac_analog_power.set(false);
            x1000.Aic.i2s_control.set(x1000.Aic.stop_bit_clock);
        }

        fn configureClock(_: *Self, rate: Board.SampleRate) void {
            x1000.Aic.i2s_control.set(x1000.Aic.stop_bit_clock);
            x1000.Cpm.i2s_clock.write(Board.clockWord(rate));
            x1000.Cpm.i2s_clock_latch.write(x1000.Cpm.i2s_clock_latch.read());
            x1000.Aic.bit_clock_divider.write(Board.bitClockDivider(rate));
            x1000.Aic.i2s_control.clear(x1000.Aic.stop_bit_clock);
        }

        fn acquireLock(self: *Self) Error!void {
            self.lock.begin(x1000.Timer.now());
            x1000.Aic.common_control.set(x1000.Aic.playback_enable);
            defer x1000.Aic.common_control.clear(x1000.Aic.playback_enable);
            while (self.lock.pending) {
                // The DAC sees continuous I2S silence. PDMA remains stopped.
                if (x1000.Aic.transmitLevel() < 32) x1000.Aic.data.write(0);
                if (self.lock.due(x1000.Timer.now(), x1000.Timer.milliseconds(5))) {
                    const status = try self.dacStatus();
                    _ = try self.lock.observe(x1000.Timer.now(), status.locked(), x1000.Timer.milliseconds(500));
                }
            }
            try drainFifo(dac_warmup_timeout_ms);
        }

        fn configureDac(self: *Self, attenuation: u8) Error!void {
            self.dac = Dac.init(i2c.Bus.init(Board.dac_i2c.scl, Board.dac_i2c.sda), Board.dac_address);
            const detected = self.dac.?.status() catch |failure| return dacError(failure);
            const identity = self.dac.?.configure(.{
                .left_attenuation = attenuation,
                .right_attenuation = attenuation,
                .dpll_bandwidth = Board.dpll_bandwidth,
                .stop_divider = dac_lock.stopDivider(@backingInt(self.rate.?), detected.revision() == .v),
                .muted = true,
            }) catch |failure| return dacError(failure);
            self.dac_identity = identity.raw;
        }

        /// Hardware attenuation uses the DAC's soft-volume ramp and leaves
        /// source PCM untouched. Failure also asserts the board analogue mute.
        pub fn setHardwareVolume(self: *Self, attenuation: u8) Error!void {
            errdefer Board.output_mute.set(true);
            const dac = if (self.dac) |*value| value else return error.DacCommunication;
            dac.setVolume(attenuation, attenuation) catch |failure| return dacError(failure);
        }
        pub fn dacStatus(self: *Self) Error!es9018.Status {
            const dac = if (self.dac) |*value| value else return error.DacCommunication;
            return dac.status() catch |failure| return dacError(failure);
        }
        /// Configure while idle, after initialize and before start. Filter
        /// settling must never block the real-time playback service loop.
        pub fn setProcessing(self: *Self, processing: Processing) Error!void {
            if (self.running) return error.AudioBusy;
            const dac = if (self.dac) |*value| value else return error.DacCommunication;
            const was_muted = dac.muted;
            Board.output_mute.set(true);
            errdefer Board.output_mute.set(true);
            dac.setMute(true) catch |failure| return dacError(failure);
            dac.setFilter(processing.filter) catch |failure| return dacError(failure);
            dac.setIirBypass(processing.iir_bypass) catch |failure| return dacError(failure);
            dac.setDeemphasis(processing.deemphasis, @backingInt(self.rate.?)) catch |failure| return dacError(failure);
            x1000.Timer.delayMicroseconds(10_000);
            dac.setMute(was_muted) catch |failure| return dacError(failure);
            if (self.running and !self.lock.pending and self.route.current != .muted and !was_muted) Board.output_mute.set(false);
        }
        /// Request routing immediately mutes the analogue path. Hardware
        /// settling is serviced incrementally by poll(), alongside DMA events.
        pub fn setOutput(self: *Self, output: Output) void {
            if (self.route.current != output or self.route.stage != .idle) Board.output_mute.set(true);
            self.route.request(output);
        }
        const RouteBackend = struct {
            engine: *Self,
            pub fn now(_: *@This()) u32 {
                return x1000.Timer.now();
            }
            pub fn hardMute(_: *@This(), value: bool) void {
                Board.output_mute.set(value);
            }
            pub fn softMute(backend: *@This(), value: bool) Error!void {
                const dac = if (backend.engine.dac) |*device| device else return error.DacCommunication;
                dac.setMute(value) catch |failure| return dacError(failure);
            }
            pub fn amplifierShutdown(_: *@This(), value: bool) void {
                Board.amplifier_shutdown.set(value);
            }
            pub fn amplifierPower(_: *@This(), value: bool) void {
                Board.amplifier_power.set(value);
            }
            pub fn selectLine(_: *@This(), value: bool) void {
                Board.output_select.set(value);
            }
            pub fn playing(backend: *@This()) bool {
                return backend.engine.running and !backend.engine.lock.pending;
            }
        };

        fn buildDescriptorRing(self: *Self) void {
            for (0..self.config.descriptor_count) |index| {
                const buffer = self.resources.buffers[index % self.config.buffer_count];
                const next_index: u7 = @intCast((index + 1) % self.config.descriptor_count);
                self.resources.descriptors[index] = cyclicDescriptor(
                    buffer.address,
                    self.config.chunk_bytes,
                    next_index,
                );
            }
        }
    };
}

fn dacError(failure: anyerror) Error {
    return switch (failure) {
        error.VerificationMismatch, error.UnsupportedDevice => error.DacVerification,
        else => error.DacCommunication,
    };
}

pub fn cyclicDescriptor(buffer_address: usize, chunk_bytes: u24, next_index: u7) x1000.Pdma.Descriptor {
    return x1000.Pdma.Descriptor.audioPlayback(
        x1000.physicalAddress(buffer_address),
        chunk_bytes,
    ).linkedTo(next_index);
}

fn drainFifo(timeout_ms: u32) Error!void {
    const started = x1000.Timer.now();
    while (x1000.Aic.transmitLevel() != 0) {
        if (x1000.Timer.elapsed(started) > x1000.Timer.milliseconds(timeout_ms)) {
            return error.AudioFifoTimeout;
        }
    }
}

const dac_warmup_samples = 32;
const dac_warmup_word = 0x00ff_ffff;
const dac_warmup_timeout_ms = 150;
const fifo_prefill_frames = 32;
const fifo_prefill_timeout_ms = 10;

test "cyclic descriptors select a buffer and encode the next descriptor" {
    const testing = @import("std").testing;
    const descriptor = cyclicDescriptor(0xa020_0000, 9_600, 119);
    try testing.expectEqual(@as(u32, 0x0020_0000), descriptor.source);
    try testing.expectEqual(@as(u32, 0x0089_0703), descriptor.command);
    try testing.expectEqual(@as(u32, 0xee00_2580), descriptor.count);
}

test "descriptor status is converted from 16-byte offsets" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(?u7, 119), x1000.Pdma.descriptorIndexFromStatus(238 << 8));
    try testing.expectEqual(@as(?u7, null), x1000.Pdma.descriptorIndexFromStatus(239 << 8));
}

test "sample formats encode the verified stereo DMA layouts" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u8, 4), SampleFormat.pcm_s16_packed.bytesPerFrame());
    try testing.expectEqual(@as(u8, 8), SampleFormat.pcm_s24.bytesPerFrame());
    try testing.expectEqual(
        x1000.Aic.packed_16_bit | x1000.Aic.stereo |
            x1000.Aic.output_16_bit | x1000.Aic.input_16_bit,
        SampleFormat.pcm_s16_packed.aicControl(),
    );
    try testing.expectEqual(
        x1000.Aic.stereo | x1000.Aic.output_24_bit | x1000.Aic.input_24_bit,
        SampleFormat.pcm_s24.aicControl(),
    );
}

test "audio chunks contain complete sample frames" {
    const testing = @import("std").testing;
    const base = Config{ .descriptor_count = 4, .buffer_count = 2, .chunk_bytes = 100 };
    try testing.expect(base.valid());
    try testing.expect(!(Config{
        .descriptor_count = 4,
        .buffer_count = 2,
        .chunk_bytes = 100,
        .sample_format = .pcm_s24,
    }).valid());
    try testing.expect((Config{
        .descriptor_count = 4,
        .buffer_count = 2,
        .chunk_bytes = 104,
        .sample_format = .pcm_s24,
    }).valid());
}

test "cyclic descriptor rings remain aligned with reusable buffers" {
    const testing = @import("std").testing;
    try testing.expect((Config{
        .descriptor_count = 120,
        .buffer_count = 3,
        .chunk_bytes = 9_600,
    }).valid());
    try testing.expect(!(Config{
        .descriptor_count = 128,
        .buffer_count = 3,
        .chunk_bytes = 9_600,
    }).valid());
}

test "invalid zero-buffer configuration is rejected without division" {
    try @import("std").testing.expect(!(Config{ .descriptor_count = 0, .buffer_count = 0, .chunk_bytes = 8 }).valid());
}
