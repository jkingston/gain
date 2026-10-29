pub inline fn bit(comptime index: u5) u32 {
    return @as(u32, 1) << index;
}

pub fn Register32(comptime address: usize) type {
    return struct {
        pub const location = address;

        pub inline fn read() u32 {
            const pointer: *volatile u32 = @ptrFromInt(address);
            return pointer.*;
        }

        pub inline fn write(value: u32) void {
            const pointer: *volatile u32 = @ptrFromInt(address);
            pointer.* = value;
        }

        pub inline fn set(mask: u32) void {
            write(read() | mask);
        }

        pub inline fn clear(mask: u32) void {
            write(read() & ~mask);
        }
    };
}

pub inline fn read32(address: usize) u32 {
    const pointer: *volatile u32 = @ptrFromInt(address);
    return pointer.*;
}

pub inline fn write32(address: usize, value: u32) void {
    const pointer: *volatile u32 = @ptrFromInt(address);
    pointer.* = value;
}

pub const RegisterWrite = struct {
    address: usize,
    value: u32,
};

pub fn writeAll(writes: []const RegisterWrite) void {
    for (writes) |write| write32(write.address, write.value);
}

pub const Cpm = struct {
    pub const main_pll = Register32(0xb0000014);
    pub const clock_gate = Register32(0xb0000020);
    pub const ddr_clock = Register32(0xb000002c);
    pub const lcd_clock = Register32(0xb0000064);
    pub const power_switch_0 = Register32(0xb0000090);
    pub const power_switch_1 = Register32(0xb0000094);
    pub const power_switch_2 = Register32(0xb0000098);
    pub const power_switch_3 = Register32(0xb000009c);
    pub const ddr_reset_clock_gate = Register32(0xb00000d0);
    pub const status = Register32(0xb00000d4);

    pub const Gate = enum(u5) {
        lcd = 23,
        ost = 20,
        ddr = 31,
    };

    pub inline fn ungate(comptime peripheral: Gate) void {
        clock_gate.clear(bit(@backingInt(peripheral)));
    }

    pub const main_pll_on = bit(0);
    pub const main_pll_change_enable = bit(7);
    pub const ddr_clock_busy = bit(28);
    pub const ddr_clock_change_enable = bit(29);
    pub const ddr_clock_stop = bit(26);
    pub const ddr_divider_ready = bit(27);
    pub const lcd_clock_busy = bit(27);
    pub const lcd_clock_change_enable = bit(28);
};

pub const Timer = struct {
    const control = Register32(0xb2000000);
    const clear = Register32(0xb2000008);
    const count_high = Register32(0xb200001c);
    const count_low = Register32(0xb2000020);
    const enable_set = Register32(0xb2000034);

    pub const ticks_per_microsecond: u32 = 6;
    const clock_source_mask: u32 = 3 << 2;
    const external_clock_source: u32 = 1 << 2;
    const channel_2 = bit(1);

    pub inline fn initialize() void {
        Cpm.ungate(.ost);
        control.write((control.read() & ~clock_source_mask) | external_clock_source);
        clear.write(channel_2);
        count_high.write(0);
        count_low.write(0);
        enable_set.write(channel_2);
    }

    pub inline fn now() u32 {
        return count_low.read();
    }

    pub inline fn elapsed(start: u32) u32 {
        return now() -% start;
    }

    pub inline fn microseconds(value: u32) u32 {
        return value * ticks_per_microsecond;
    }

    pub inline fn milliseconds(value: u32) u32 {
        return microseconds(value * 1_000);
    }

    pub fn delayMicroseconds(value: u32) void {
        const start = now();
        const duration = microseconds(value);
        while (elapsed(start) < duration) asm volatile ("nop");
    }
};

pub const Gpio = struct {
    const base = 0xb0010000;
    const stride = 0x100;

    pub const Port = enum(usize) {
        a = 0,
        b = 1,
        c = 2,
        d = 3,
    };

    const Offset = struct {
        const pins = 0x00;
        const interrupt_clear = 0x18;
        const mask_set = 0x24;
        const pattern1_clear = 0x34;
        const pattern1_set = 0x38;
        const output_set = 0x44;
        const output_clear = 0x48;
        const pull_disable_set = 0x74;
        const mask_clear = 0x28;
    };

    pub const Pin = struct {
        port: Port,
        index: u5,

        pub inline fn mask(self: Pin) u32 {
            return @as(u32, 1) << self.index;
        }

        inline fn address(self: Pin, comptime offset: usize) usize {
            return base + @backingInt(self.port) * stride + offset;
        }

        inline fn register(self: Pin, comptime offset: usize) *volatile u32 {
            return @ptrFromInt(self.address(offset));
        }

        pub inline fn output(self: Pin, high: bool) void {
            self.register(Offset.interrupt_clear).* = self.mask();
            self.register(Offset.mask_set).* = self.mask();
            self.register(Offset.pattern1_set).* = self.mask();
            self.set(high);
        }

        pub inline fn input(self: Pin) void {
            self.register(Offset.interrupt_clear).* = self.mask();
            self.register(Offset.mask_set).* = self.mask();
            self.register(Offset.pattern1_clear).* = self.mask();
            self.register(Offset.output_clear).* = self.mask();
            self.register(Offset.pull_disable_set).* = self.mask();
        }

        pub inline fn set(self: Pin, high: bool) void {
            self.register(if (high) Offset.output_set else Offset.output_clear).* = self.mask();
        }

        pub inline fn get(self: Pin) bool {
            return self.register(Offset.pins).* & self.mask() != 0;
        }
    };

    pub inline fn selectFunction1(comptime port: Port, mask: u32) void {
        const port_base = base + @backingInt(port) * stride;
        Register32(port_base + Offset.interrupt_clear).write(mask);
        Register32(port_base + Offset.mask_clear).write(mask);
        Register32(port_base + Offset.pattern1_set).write(mask);
        Register32(port_base + Offset.output_set).write(mask);
    }
};

pub const Watchdog = struct {
    pub const Clock = enum(u3) {
        peripheral = 1,
        rtc = 2,
        external = 4,
    };

    pub const Prescale = enum(u3) {
        by_1 = 0,
        by_4 = 1,
        by_16 = 2,
        by_64 = 3,
        by_256 = 4,
        by_1024 = 5,
    };

    const data = Register32(0xb0002000);
    const enable = Register32(0xb0002004);
    const count = Register32(0xb0002008);
    const control = Register32(0xb000200c);
    const stop_clear = Register32(0xb000203c);
    const stop_bit = bit(16);

    inline fn controlValue(clock: Clock, prescale: Prescale) u32 {
        return @as(u32, @backingInt(prescale)) << 3 | @backingInt(clock);
    }

    pub inline fn start(clock: Clock, prescale: Prescale, timeout_ticks: u16) void {
        stop_clear.write(stop_bit);
        enable.write(0);
        control.write(controlValue(clock, prescale));
        count.write(0);
        data.write(timeout_ticks);
        enable.write(1);
    }

    pub inline fn kick() void {
        count.write(0);
    }
};

pub const Lcd = struct {
    pub const control = Register32(0xb3050030);
    pub const horizontal_area = Register32(0xb3050010);
    pub const vertical_area = Register32(0xb3050014);
    pub const mcu_config = Register32(0xb30500a0);
    pub const mcu_control = Register32(0xb30500a4);
    pub const mcu_state = Register32(0xb30500a8);
    pub const mcu_data = Register32(0xb30500ac);
    pub const write_time = Register32(0xb30500b0);
    pub const task_hold = Register32(0xb30500b4);
    pub const mcu_config_new = Register32(0xb30500b8);
    pub const slow_write_time = Register32(0xb30500bc);

    pub const mcu_busy = bit(0);
    pub const command_flag: u32 = 0x40000000;
    pub const direct_command_mode: u32 = 0x40000000;
};

pub const Ddr = struct {
    pub const phy_base = 0xb3011000;
    pub const controller_base = 0xb34f0000;

    pub const phy = struct {
        pub const initialization = Register32(phy_base + 0x04);
        pub const general_config = Register32(phy_base + 0x08);
        pub const general_status = Register32(phy_base + 0x0c);
        pub const dll_general_control = Register32(phy_base + 0x10);
        pub const ac_dll_control = Register32(phy_base + 0x14);
        pub const pointer_0 = phy_base + 0x18;
        pub const pointer_1 = phy_base + 0x1c;
        pub const pointer_2 = phy_base + 0x20;
        pub const ac_io_control = phy_base + 0x24;
        pub const data_byte_control = phy_base + 0x28;
        pub const system_general_config = Register32(phy_base + 0x2c);
        pub const dram_config = phy_base + 0x30;
        pub const timing_parameter_0 = phy_base + 0x34;
        pub const timing_parameter_1 = phy_base + 0x38;
        pub const timing_parameter_2 = phy_base + 0x3c;
        pub const mode_0 = phy_base + 0x40;
        pub const mode_2 = phy_base + 0x48;
        pub const data_training_address = phy_base + 0x54;
        pub const data_lane_0 = phy_base + 0x1c0;
        pub const data_lane_1 = phy_base + 0x200;
        pub const data_lane_2 = phy_base + 0x240;
        pub const data_lane_3 = phy_base + 0x280;
    };

    pub const controller = struct {
        pub const status = Register32(controller_base + 0x00);
        pub const config = Register32(controller_base + 0x04);
        pub const control = Register32(controller_base + 0x08);
        pub const refresh_count = controller_base + 0x18;
        pub const memory_map_0 = controller_base + 0x24;
        pub const memory_map_1 = controller_base + 0x28;
        pub const timing_1 = controller_base + 0x60;
        pub const timing_2 = controller_base + 0x64;
        pub const timing_3 = controller_base + 0x68;
        pub const timing_4 = controller_base + 0x6c;
        pub const timing_5 = controller_base + 0x70;
        pub const timing_6 = controller_base + 0x74;
        pub const remap_1 = controller_base + 0x9c;
        pub const remap_2 = controller_base + 0xa0;
        pub const remap_3 = controller_base + 0xa4;
        pub const remap_4 = controller_base + 0xa8;
        pub const remap_5 = controller_base + 0xac;
        pub const auto_self_refresh = Register32(controller_base + 0x304);
    };

    pub const apb = struct {
        pub const clock_stop_config = Register32(0xb3012068);
        pub const phy_reset_config = Register32(0xb3012080);
    };

    pub const phy_training_complete: u32 = 0x1f;
    pub const phy_training_error_mask: u32 = 0x60;
};
