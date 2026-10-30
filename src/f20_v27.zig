const x1000 = @import("x1000.zig");

pub const clock = struct {
    // Verified clock words from the F20 V2.7 boot path.
    pub const main_pll: u32 = (1 << 31) | (24 << 24) | x1000.Cpm.main_pll_change_enable;
    pub const ddr: u32 = (2 << 30) | x1000.Cpm.ddr_clock_change_enable | 2;
    pub const ddr_field_mask: u32 = 0xc000000f;
};

pub const power_switches = [_]u32{ 0x00, 0x10, 0x18, 0x08 };

pub const display = struct {
    pub const width = 320;
    pub const height = 240;
    pub const framebuffer_address = 0xa0040000;
    // Fixed uncached workspace below the SD DMA descriptor and above the
    // read-ahead buffers. Full frames transfer directly from the framebuffer;
    // only packed dirty regions use the staging area.
    pub const dma_descriptor_address = 0xa007e000;
    pub const dma_command_address = 0xa007e100;
    pub const dma_staging_address = 0xa00c0000;
    pub const dma_staging_pixel_capacity = width * 42;
    pub const clock_divider = 29;
    pub const clock_configuration: u32 = 0x90000000 | clock_divider;
    pub const mcu_configuration: u32 = 0x00000100;
    pub const mcu_control: u32 = 0x00000114;

    pub const backlight = x1000.Gpio.Pin{ .port = .c, .index = 25 };
    pub const reset = x1000.Gpio.Pin{ .port = .b, .index = 13 };
    pub const power = x1000.Gpio.Pin{ .port = .b, .index = 14 };
    pub const read_strobe = x1000.Gpio.Pin{ .port = .b, .index = 16 };
    pub const chip_enable = x1000.Gpio.Pin{ .port = .b, .index = 18 };
    pub const port_a_function_1: u32 = 0x0000ffff;
    pub const port_b_function_1: u32 = 0x001a0000;

    pub const Command = enum(u8) {
        vendor_config = 0xc8,
        memory_access = 0x36,
        pixel_format = 0x3a,
        power_control_1 = 0xc0,
        power_control_2 = 0xc1,
        vcom_control = 0xc5,
        frame_rate = 0xb1,
        inversion_control = 0xb4,
        positive_gamma = 0xe0,
        negative_gamma = 0xe1,
        sleep_out = 0x11,
        display_on = 0x29,
        column_address = 0x2a,
        page_address = 0x2b,
        memory_write = 0x2c,
    };

    const command_marker: u16 = 0x100;

    fn command(value: Command) u16 {
        return command_marker | @backingInt(value);
    }

    fn data(value: u8) u16 {
        return value;
    }

    pub fn isCommand(value: u16) bool {
        return value & command_marker != 0;
    }

    // Verified F20 V2.7 panel sequence. Gamma data are controller-specific curves.
    pub const initialization = [_]u16{
        command(.vendor_config),   data(0xff),             data(0x93),                  data(0x42),
        command(.memory_access),   data(0xd8),             command(.pixel_format),      data(0x05),
        command(.power_control_1), data(0x15),             data(0x15),                  command(.power_control_2),
        data(0x01),                command(.vcom_control), data(0xda),                  command(.frame_rate),
        data(0x00),                data(0x1b),             command(.inversion_control), data(0x02),
        command(.positive_gamma),  data(0x0f),             data(0x13),                  data(0x17),
        data(0x04),                data(0x13),             data(0x07),                  data(0x40),
        data(0x39),                data(0x4f),             data(0x06),                  data(0x0d),
        data(0x0a),                data(0x1f),             data(0x22),                  data(0x00),
        command(.negative_gamma),  data(0x00),             data(0x21),                  data(0x24),
        data(0x03),                data(0x0f),             data(0x05),                  data(0x38),
        data(0x32),                data(0x49),             data(0x00),                  data(0x09),
        data(0x08),                data(0x32),             data(0x35),                  data(0x0f),
    };
};

pub const audio = struct {
    pub const SampleRate = enum(u32) {
        hz_44_100 = 44_100,
        hz_48_000 = 48_000,
        hz_88_200 = 88_200,
        hz_96_000 = 96_000,
        hz_176_400 = 176_400,
        hz_192_000 = 192_000,
    };

    pub const i2s_port_b_function_1: u32 = 0x1f;
    pub const dac_i2c = I2cPins{
        .scl = .{ .port = .c, .index = 26 },
        .sda = .{ .port = .c, .index = 27 },
    };

    pub const dac_power = x1000.Gpio.Pin{ .port = .b, .index = 12 };
    pub const dac_analog_power = x1000.Gpio.Pin{ .port = .b, .index = 9 };
    pub const amplifier_power = x1000.Gpio.Pin{ .port = .b, .index = 6 };
    pub const amplifier_shutdown = x1000.Gpio.Pin{ .port = .b, .index = 8 };
    pub const output_mute = x1000.Gpio.Pin{ .port = .b, .index = 15 };
    pub const output_select = x1000.Gpio.Pin{ .port = .b, .index = 5 };

    pub const dac_address: u7 = 0x48;
    pub const DacRegister = enum(u8) {
        input_configuration = 1,
        master_mode_control = 10,
        dpll_settings = 12,
        left_volume = 15,
        right_volume = 16,
    };
    // The X1000 keeps BCLK at 64fs, so both 16- and 24-bit samples occupy
    // 32-bit I2S channel slots at the ES9018K2M input.
    pub const dac_input_32_bit_i2s: u8 = 0x80;
    pub const master_mode_stop_divider_fast_lock: u8 = 0x0f;
    pub const dpll_bandwidth: u8 = 0xda;

    pub const source_clock_hz: u32 = 600_000_000;
    pub const master_clock_multiplier: u32 = 256;
    pub const bit_clock_divider: u32 = 3;
    pub const dma_fifo_prime_frames: u8 = 24;

    const ClockRatio = struct { numerator: u32, denominator: u32 };

    pub fn clockRatio(rate: SampleRate) ClockRatio {
        return switch (rate) {
            .hz_44_100 => .{ .numerator = 41, .denominator = 2_179 },
            .hz_48_000 => .{ .numerator = 64, .denominator = 3_125 },
            .hz_88_200 => .{ .numerator = 82, .denominator = 2_179 },
            .hz_96_000 => .{ .numerator = 128, .denominator = 3_125 },
            .hz_176_400 => .{ .numerator = 164, .denominator = 2_179 },
            .hz_192_000 => .{ .numerator = 256, .denominator = 3_125 },
        };
    }

    pub fn clockWord(rate: SampleRate) u32 {
        const ratio = clockRatio(rate);
        return x1000.bit(31) | x1000.bit(30) | x1000.bit(29) |
            ratio.numerator << 13 | ratio.denominator;
    }

    pub fn clockErrorPpb(rate: SampleRate) u32 {
        const ratio = clockRatio(rate);
        const expected = @as(u64, @backingInt(rate)) * master_clock_multiplier * ratio.denominator;
        const generated = @as(u64, source_clock_hz) * ratio.numerator;
        const difference = if (generated > expected) generated - expected else expected - generated;
        return @intCast(difference * 1_000_000_000 / expected);
    }

    pub fn clockErrorPpm(rate: SampleRate) u32 {
        return clockErrorPpb(rate) / 1_000;
    }
};

pub const storage = struct {
    pub const card_power = x1000.Gpio.Pin{ .port = .b, .index = 10 };
    pub const card_detect = x1000.Gpio.Pin{ .port = .b, .index = 11 };
    pub const port_a_function_1: u32 = @as(u32, 0x3f) << 20;

    pub const controller_clock_configuration = x1000.bit(31) |
        x1000.Cpm.msc_clock_change_enable | 5;
    pub const identification_clock_divider: u32 = 7;
    pub const default_clock_divider: u32 = 1;
    pub const high_speed_clock_divider: u32 = 0;
    pub const default_bus_hz: u32 = 25_000_000;
    pub const high_speed_bus_hz: u32 = 50_000_000;
};

pub const ButtonId = enum(u3) {
    play,
    volume_up,
    volume_down,
    menu,
    previous,
    next,
    back,
    power,

    pub fn mask(self: ButtonId) u8 {
        return @as(u8, 1) << @backingInt(self);
    }
};

pub const Button = struct {
    id: ButtonId,
    pin: x1000.Gpio.Pin,
    label: []const u8,
};

pub const buttons = [_]Button{
    .{ .id = .play, .pin = .{ .port = .a, .index = 16 }, .label = "PLAY" },
    .{ .id = .volume_up, .pin = .{ .port = .a, .index = 17 }, .label = "VOL+" },
    .{ .id = .volume_down, .pin = .{ .port = .a, .index = 19 }, .label = "VOL-" },
    .{ .id = .menu, .pin = .{ .port = .b, .index = 28 }, .label = "MENU" },
    .{ .id = .previous, .pin = .{ .port = .d, .index = 4 }, .label = "PREV" },
    .{ .id = .next, .pin = .{ .port = .c, .index = 24 }, .label = "NEXT" },
    .{ .id = .back, .pin = .{ .port = .d, .index = 5 }, .label = "BACK" },
    .{ .id = .power, .pin = .{ .port = .b, .index = 7 }, .label = "POWER" },
};

pub const wheel = struct {
    pub const phase_a = x1000.Gpio.Pin{ .port = .b, .index = 23 };
    pub const phase_b = x1000.Gpio.Pin{ .port = .b, .index = 24 };
};

pub const pmic = struct {
    pub const address: u7 = 0x34;
    pub const primary = I2cPins{
        .scl = .{ .port = .d, .index = 0 },
        .sda = .{ .port = .d, .index = 1 },
    };
    pub const alternate = I2cPins{
        .scl = .{ .port = .d, .index = 1 },
        .sda = .{ .port = .d, .index = 0 },
    };

    pub const Register = enum(u8) {
        status = 0x00,
        power_control = 0x32,
        battery_high = 0x78,
        battery_low = 0x79,
    };

    pub const shutdown: u8 = 1 << 7;
};

pub const I2cPins = struct {
    scl: x1000.Gpio.Pin,
    sda: x1000.Gpio.Pin,
};

pub const watchdog_timeout_ticks: u16 = 65_000;

pub const ddr = struct {
    pub const reset_clock_gate_asserted: u32 = 0x73;
    pub const reset_clock_gate_released: u32 = 0x71;
    pub const phy_reset_asserted: u32 = 0x01a00001;
    pub const phy_training_reset: u32 = 0x00400000;
    pub const controller_config_initial: u32 = 0x0a46896c;
    pub const controller_config_training: u32 = 0x0a4689ec;
    pub const controller_reset_asserted: u32 = 0xf00000;
    pub const command_configure: u32 = 2;
    pub const command_precharge_all: u32 = 10;
    pub const final_control: u32 = 0xc91e;
    pub const refresh_count: u32 = 0x2f0003;
    pub const clock_stop_configuration: u32 = 0x9000000f;
    pub const auto_self_refresh_enabled: u32 = 1;
    pub const memory_test_address = 0xa0010000;
    pub const memory_test_pattern_1: u32 = 0x55aa33cc;
    pub const memory_test_pattern_2: u32 = 0xaa55cc33;

    // Verified F20 V2.7 32 MiB LPDDR profile. Composite values encode DRAM timings.
    pub const phy_profile = [_]x1000.RegisterWrite{
        .{ .address = x1000.Ddr.phy.data_training_address, .value = 0x150000 },
        .{ .address = x1000.Ddr.phy.dram_config, .value = 0 },
        .{ .address = x1000.Ddr.phy.mode_0, .value = 0x42 },
        .{ .address = x1000.Ddr.phy.mode_2, .value = 0x98 },
        .{ .address = x1000.Ddr.phy.pointer_0, .value = 0x21000a },
        .{ .address = x1000.Ddr.phy.pointer_1, .value = 0xa09c40 },
        .{ .address = x1000.Ddr.phy.pointer_2, .value = 0x280014 },
        .{ .address = x1000.Ddr.phy.timing_parameter_0, .value = 0x1a69444a },
        .{ .address = x1000.Ddr.phy.timing_parameter_1, .value = 0x180090 },
        .{ .address = x1000.Ddr.phy.timing_parameter_2, .value = 0x1ff99428 },
        .{ .address = x1000.Ddr.phy.data_lane_0, .value = 0x90881 },
        .{ .address = x1000.Ddr.phy.data_lane_1, .value = 0x90881 },
        .{ .address = x1000.Ddr.phy.data_lane_2, .value = 0x90e80 },
        .{ .address = x1000.Ddr.phy.data_lane_3, .value = 0x90e80 },
        .{ .address = x1000.Ddr.phy.general_config.location, .value = 0x1042e03 },
        .{ .address = x1000.Ddr.phy.ac_io_control, .value = 0x30c00813 },
        .{ .address = x1000.Ddr.phy.data_byte_control, .value = 0x4912 },
    };

    pub const controller_profile = [_]x1000.RegisterWrite{
        .{ .address = x1000.Ddr.controller.timing_1, .value = 0x02050501 },
        .{ .address = x1000.Ddr.controller.timing_2, .value = 0x04090404 },
        .{ .address = x1000.Ddr.controller.timing_3, .value = 0x2704030d },
        .{ .address = x1000.Ddr.controller.timing_4, .value = 0x0b7a0251 },
        .{ .address = x1000.Ddr.controller.timing_5, .value = 0xff090200 },
        .{ .address = x1000.Ddr.controller.timing_6, .value = 0x0a0a0202 },
        .{ .address = x1000.Ddr.controller.memory_map_0, .value = 0x20fe },
        .{ .address = x1000.Ddr.controller.memory_map_1, .value = 0x2200 },
    };

    pub const remap_profile = [_]x1000.RegisterWrite{
        .{ .address = x1000.Ddr.controller.remap_1, .value = 0x03020b0a },
        .{ .address = x1000.Ddr.controller.remap_2, .value = 0x07060504 },
        .{ .address = x1000.Ddr.controller.remap_3, .value = 0x01000908 },
        .{ .address = x1000.Ddr.controller.remap_4, .value = 0x0f0e0d0c },
        .{ .address = x1000.Ddr.controller.remap_5, .value = 0x13121110 },
    };
};

test "audio clock profiles stay within two ppm" {
    const testing = @import("std").testing;
    const expected = [_]struct { rate: audio.SampleRate, word: u32, error_ppb: u32 }{
        .{ .rate = .hz_44_100, .word = 0xe0052883, .error_ppb = 1_560 },
        .{ .rate = .hz_48_000, .word = 0xe0080c35, .error_ppb = 0 },
        .{ .rate = .hz_88_200, .word = 0xe00a4883, .error_ppb = 1_560 },
        .{ .rate = .hz_96_000, .word = 0xe0100c35, .error_ppb = 0 },
        .{ .rate = .hz_176_400, .word = 0xe0148883, .error_ppb = 1_560 },
        .{ .rate = .hz_192_000, .word = 0xe0200c35, .error_ppb = 0 },
    };
    for (expected) |profile| {
        try testing.expectEqual(profile.word, audio.clockWord(profile.rate));
        try testing.expectEqual(profile.error_ppb, audio.clockErrorPpb(profile.rate));
        try testing.expect(audio.clockErrorPpb(profile.rate) <= 2_000);
    }
}

test "audio DMA descriptor matches the X1000 playback contract" {
    const testing = @import("std").testing;
    const descriptor = x1000.Pdma.Descriptor.audioPlayback(0x00080000, 960_000);
    try testing.expectEqual(@as(usize, 32), @sizeOf(x1000.Pdma.Descriptor));
    try testing.expectEqual(@as(u32, 0x00890702), descriptor.command);
    try testing.expectEqual(@as(u32, 0x10020034), descriptor.target);
    try testing.expectEqual(@as(u32, 6), descriptor.request);
    try testing.expectEqual(@as(u32, 960_000), descriptor.count);
}

test "audio DMA descriptor links within its four KiB page" {
    const testing = @import("std").testing;
    const descriptor = x1000.Pdma.Descriptor.audioPlayback(0x00080000, 9_600).linkedTo(119);
    try testing.expectEqual(@as(u32, 0x00890703), descriptor.command);
    try testing.expectEqual(@as(u32, 0xee002580), descriptor.count);
}

test "AIC transmit FIFO level preserves the full state" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u7, 0), x1000.Aic.transmitLevelFromStatus(0x0000));
    try testing.expectEqual(@as(u7, 63), x1000.Aic.transmitLevelFromStatus(0x3f00));
    try testing.expectEqual(@as(u7, 64), x1000.Aic.transmitLevelFromStatus(0x4000));
    try testing.expectEqual(@as(u7, 64), x1000.Aic.transmitLevelFromStatus(0x7f00));
}
