const x1000 = @import("x1000.zig");
const i2c = @import("i2c.zig");

pub const maximum_descriptors = 128;
pub const maximum_buffers = 4;

pub const Error = error{
    InvalidConfig,
    CachedDmaMemory,
    DescriptorPageAlignment,
    AudioFifoTimeout,
    DacCommunication,
    DacVerification,
    InvalidDescriptorOffset,
};

pub const Buffer = struct {
    address: usize,
};

pub const Config = struct {
    descriptor_count: u8,
    buffer_count: u8,
    chunk_bytes: u24,

    pub fn valid(self: Config) bool {
        return self.descriptor_count >= self.buffer_count and
            self.descriptor_count <= maximum_descriptors and
            self.buffer_count >= 2 and self.buffer_count <= maximum_buffers and
            self.chunk_bytes != 0 and self.chunk_bytes & 3 == 0;
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

        pub const Resources = struct {
            descriptors: *align(4096) volatile [maximum_descriptors]x1000.Pdma.Descriptor,
            buffers: [maximum_buffers]Buffer,
        };

        resources: Resources,
        config: Config,
        minimum_fifo_level: u7 = 64,
        underrun_count: u32 = 0,
        dac_identity: u8 = 0,

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
            x1000.Timer.initialize();
            self.safePins();
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
        }

        pub fn start(self: *Self) Error!void {
            errdefer self.stop();
            self.buildDescriptorRing();
            x1000.memoryBarrier();

            x1000.Aic.common_control.write(
                x1000.Aic.packed_16_bit | x1000.Aic.stereo |
                    x1000.Aic.output_16_bit | x1000.Aic.input_16_bit,
            );
            x1000.Aic.clearTransmitUnderrun();
            Board.output_mute.set(false);
            x1000.Cpm.ungate(.pdma);
            x1000.Pdma.control.write(0);
            channel.status.write(0);
            x1000.Pdma.doorbell.write(0);
            x1000.Pdma.descriptor_interrupt_clear.write(x1000.Pdma.clear_all_but_channel_0);
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
        }

        pub fn poll(self: *Self) Error!Event {
            const fifo_level = x1000.Aic.transmitLevel();
            self.minimum_fifo_level = @min(self.minimum_fifo_level, fifo_level);
            const aic_status = x1000.Aic.status.read();
            const underrun = aic_status & x1000.Aic.transmit_underrun != 0;
            if (underrun) {
                self.underrun_count +%= 1;
                x1000.Aic.clearTransmitUnderrun();
            }

            const dma_status = channel.status.read();
            var descriptor: ?u7 = null;
            if (x1000.Pdma.descriptor_pending.read() & x1000.Pdma.channel_0 != 0) {
                descriptor = x1000.Pdma.descriptorIndexFromStatus(dma_status) orelse
                    return error.InvalidDescriptorOffset;
                if (descriptor.? >= self.config.descriptor_count) return error.InvalidDescriptorOffset;
                x1000.Pdma.descriptor_interrupt_clear.write(x1000.Pdma.clear_all_but_channel_0);
            }
            return .{
                .descriptor = descriptor,
                .fifo_level = fifo_level,
                .underrun = underrun,
                .dma_fault = dma_status & (x1000.Pdma.status_address_error |
                    x1000.Pdma.status_halted) != 0,
            };
        }

        pub fn stop(self: *Self) void {
            channel.status.write(0);
            x1000.Pdma.doorbell.write(0);
            x1000.Pdma.descriptor_interrupt_clear.write(x1000.Pdma.clear_all_but_channel_0);
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

        fn powerDown(_: *Self) void {
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
            x1000.Aic.bit_clock_divider.write(Board.bit_clock_divider);
            x1000.Aic.i2s_control.clear(x1000.Aic.stop_bit_clock);
        }

        fn configureDac(self: *Self, attenuation: u8) Error!void {
            const bus = i2c.Bus.init(Board.dac_i2c.scl, Board.dac_i2c.sda);
            self.dac_identity = bus.readRegister(Board.dac_address, 0) catch
                return error.DacCommunication;
            bus.writeRegister(
                Board.dac_address,
                @backingInt(Board.DacRegister.master_mode_control),
                Board.master_mode_stop_div_16_384_edges,
            ) catch return error.DacCommunication;
            bus.writeRegister(
                Board.dac_address,
                @backingInt(Board.DacRegister.dpll_settings),
                Board.dpll_bandwidth,
            ) catch return error.DacCommunication;
            bus.writeRegister(Board.dac_address, @backingInt(Board.DacRegister.left_volume), attenuation) catch
                return error.DacCommunication;
            bus.writeRegister(Board.dac_address, @backingInt(Board.DacRegister.right_volume), attenuation) catch
                return error.DacCommunication;
            const left = bus.readRegister(Board.dac_address, @backingInt(Board.DacRegister.left_volume)) catch
                return error.DacCommunication;
            const right = bus.readRegister(Board.dac_address, @backingInt(Board.DacRegister.right_volume)) catch
                return error.DacCommunication;
            if (left != attenuation or right != attenuation) return error.DacVerification;
        }

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
