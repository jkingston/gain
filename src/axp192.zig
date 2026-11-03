//! AXP192 protocol and telemetry. No board rail voltages are changed here.
const std = @import("std");

pub const Register = enum(u8) {
    power_status = 0,
    charge_status = 1,
    identity = 3,
    usb_path = 0x30,
    shutdown = 0x32,
    charge_control = 0x33,
    usb_voltage_high = 0x5a,
    usb_current_high = 0x5c,
    die_temperature_high = 0x5e,
    battery_voltage_high = 0x78,
    charge_current_high = 0x7a,
    discharge_current_high = 0x7c,
    adc_enable = 0x82,
    adc_enable_second = 0x83,
    adc_rate = 0x84,
    coulomb_charge = 0xb0,
    coulomb_discharge = 0xb4,
    coulomb_control = 0xb8,
    gpio0_function = 0x90,
    gpio1_function = 0x92,
    gpio_state = 0x94,
};

pub const Jacks = struct {
    headphone: bool,
    line: bool,

    pub fn fromRegister(value: u8) Jacks {
        return .{ .headphone = value & 0x10 == 0, .line = value & 0x20 == 0 };
    }
};

pub const PowerStatus = struct {
    ac_present: bool,
    usb_present: bool,
    usb_usable: bool,
    battery_present: bool,
    charging: bool,
    over_temperature: bool,

    pub fn decode(power: u8, charge: u8) PowerStatus {
        return .{
            .ac_present = power & 0x80 != 0,
            .usb_present = power & 0x20 != 0,
            .usb_usable = power & 0x10 != 0,
            .battery_present = charge & 0x20 != 0,
            .charging = charge & 0x40 != 0,
            .over_temperature = charge & 0x80 != 0,
        };
    }
};

pub const Telemetry = struct {
    status: PowerStatus,
    battery_mv: ?u16 = null,
    usb_mv: ?u16 = null,
    usb_microamps: ?u32 = null,
    die_millicelsius: ?i32 = null,
    charge_microamps: ?u32 = null,
    discharge_microamps: ?u32 = null,
    jacks: Jacks,
};

pub const Error = error{ UnsupportedDevice, UnstableAdc, VerificationMismatch, JackInputsNotConfigured };

pub const Coulomb = struct {
    charge: u32,
    discharge: u32,
    rate_hz: u16,
    running: bool,

    pub fn deltaMicroampHours(self: Coulomb, previous: Coulomb) ?struct { charge: u64, discharge: u64 } {
        if (!self.running or !previous.running or self.rate_hz != previous.rate_hz or self.rate_hz == 0) return null;
        const denominator = @as(u64, 3600) * self.rate_hz;
        return .{
            .charge = @as(u64, self.charge -% previous.charge) * 65536 * 500 / denominator,
            .discharge = @as(u64, self.discharge -% previous.discharge) * 65536 * 500 / denominator,
        };
    }
};

const charge_currents_ma = [_]u16{ 100, 190, 280, 360, 450, 550, 630, 700, 780, 880, 960, 1000, 1080, 1160, 1240, 1320 };

pub fn Device(comptime Bus: type) type {
    return struct {
        const Self = @This();
        bus: Bus,
        address: u7,
        jack_inputs_configured: bool = false,

        pub fn init(bus: Bus, address: u7) Self {
            return .{ .bus = bus, .address = address };
        }

        pub fn identify(self: *Self) !void {
            if (try self.read(.identity) != 3) return error.UnsupportedDevice;
        }

        pub fn configureJackInputs(self: *Self) !void {
            self.jack_inputs_configured = false;
            // Only GPIO0/1 function bits; never touch GPIO2 or rail controls.
            try self.modify(.gpio0_function, 7, 1);
            try self.modify(.gpio1_function, 7, 1);
            self.jack_inputs_configured = true;
        }

        pub fn jacks(self: *Self) !Jacks {
            if (!self.jack_inputs_configured) return error.JackInputsNotConfigured;
            return Jacks.fromRegister(try self.read(.gpio_state));
        }

        pub fn powerStatus(self: *Self) !PowerStatus {
            return PowerStatus.decode(try self.read(.power_status), try self.read(.charge_status));
        }

        pub fn telemetry(self: *Self) !Telemetry {
            const enabled = try self.read(.adc_enable);
            var result = Telemetry{ .status = try self.powerStatus(), .jacks = try self.jacks() };
            if (enabled & 0x80 != 0) result.battery_mv = @intCast((@as(u32, try self.adc(.battery_voltage_high, 4)) * 11 + 5) / 10);
            if (enabled & 0x08 != 0) result.usb_mv = @intCast((@as(u32, try self.adc(.usb_voltage_high, 4)) * 17 + 5) / 10);
            if (enabled & 0x04 != 0) result.usb_microamps = @as(u32, try self.adc(.usb_current_high, 4)) * 375;
            if (try self.read(.adc_enable_second) & 0x80 != 0) result.die_millicelsius = @as(i32, try self.adc(.die_temperature_high, 4)) * 100 - 144700;
            if (enabled & 0x40 != 0) {
                result.charge_microamps = @as(u32, try self.adc(.charge_current_high, 5)) * 500;
                result.discharge_microamps = @as(u32, try self.adc(.discharge_current_high, 5)) * 500;
            }
            return result;
        }

        pub fn enableTelemetry(self: *Self) !void {
            // Battery voltage/current and VBUS voltage/current ADC channels.
            // Preserve ADC rate, other channels, rails and charging controls.
            try self.modify(.adc_enable, 0xcc, 0xcc);
        }

        pub fn enableCoulombCounting(self: *Self) !void {
            // Enable accumulation, clear pause, never assert the clear pulse.
            // Charging current, voltage and rail controls are untouched.
            const old = try self.read(.coulomb_control);
            try self.write(.coulomb_control, (old & 0x1f) | 0x80);
        }

        pub fn coulomb(self: *Self) !Coulomb {
            const control = try self.read(.coulomb_control);
            return .{
                .charge = try self.counter(.coulomb_charge),
                .discharge = try self.counter(.coulomb_discharge),
                .rate_hz = @as(u16, 25) << @as(u2, @truncate((try self.read(.adc_rate)) >> 6)),
                .running = control & 0xc0 == 0x80 and try self.read(.adc_enable) & 0x40 != 0,
            };
        }

        fn counter(self: *Self, register: Register) !u32 {
            const base = @backingInt(register);
            for (0..4) |_| {
                var high: u32 = 0;
                for (0..3) |i| high = (high << 8) | try self.bus.readRegister(self.address, base + @as(u8, @intCast(i)));
                const low = try self.bus.readRegister(self.address, base + 3);
                var check: u32 = 0;
                for (0..3) |i| check = (check << 8) | try self.bus.readRegister(self.address, base + @as(u8, @intCast(i)));
                if (high == check) return (high << 8) | low;
            }
            return error.UnstableAdc;
        }

        /// Can only lower the existing current setting. Charging enable,
        /// target voltage and termination controls are preserved exactly.
        /// USB input negotiation and total system current are separate policies.
        pub fn limitChargeCurrent(self: *Self, maximum_ma: u16) !void {
            const old = try self.read(.charge_control);
            var next = old;
            if (maximum_ma < charge_currents_ma[0]) next &= ~@as(u8, 0x80) else {
                var index: usize = 0;
                while (index + 1 < charge_currents_ma.len and charge_currents_ma[index + 1] <= maximum_ma) index += 1;
                const current: usize = old & 15;
                next = (old & 0xf0) | @as(u8, @intCast(@min(index, current)));
            }
            if (next != old) try self.write(.charge_control, next);
        }

        pub fn shutdown(self: *Self) !void {
            // Read-modify-write preserves battery detection and LED policy.
            const old = try self.read(.shutdown);
            try self.bus.writeRegister(self.address, @backingInt(Register.shutdown), old | 0x80);
        }

        pub fn read(self: *Self, register: Register) !u8 {
            return self.bus.readRegister(self.address, @backingInt(register));
        }

        fn adc(self: *Self, high_register: Register, low_bits: u3) !u16 {
            const high_index = @backingInt(high_register);
            for (0..3) |_| {
                const high = try self.bus.readRegister(self.address, high_index);
                const low = try self.bus.readRegister(self.address, high_index + 1);
                const check = try self.bus.readRegister(self.address, high_index);
                if (high == check) return (@as(u16, high) << low_bits) | (low & (@as(u8, 1) << low_bits) - 1);
            }
            return error.UnstableAdc;
        }

        fn modify(self: *Self, register: Register, mask: u8, value: u8) !void {
            try self.write(register, ((try self.read(register)) & ~mask) | (value & mask));
        }

        fn write(self: *Self, register: Register, value: u8) !void {
            try self.bus.writeRegister(self.address, @backingInt(register), value);
            if (try self.read(register) != value) return error.VerificationMismatch;
        }
    };
}

/// Stable time is measured in caller-supplied ticks, including counter wrap.
/// Missing samples revoke confidence rather than fabricating unplugged jacks.
pub const JackDebounce = struct {
    candidate: ?Jacks = null,
    stable: ?Jacks = null,
    since: u32 = 0,

    pub fn update(self: *JackDebounce, now: u32, sample: ?Jacks, settle: u32) ?Jacks {
        const value = sample orelse {
            self.candidate = null;
            self.stable = null;
            return null;
        };
        if (self.candidate == null or !std.meta.eql(self.candidate.?, value)) {
            self.candidate = value;
            self.since = now;
        }
        if (now -% self.since >= settle) self.stable = value;
        return self.stable;
    }
};

const Fake = struct {
    registers: [256]u8 = @splat(0),
    writes: usize = 0,
    fail_register: ?u8 = null,
    rollover: bool = false,
    high_reads: u8 = 0,

    pub fn readRegister(self: *Fake, address: u7, reg: u8) !u8 {
        std.debug.assert(address == 0x34);
        if (self.fail_register == reg) return error.NoAcknowledge;
        if (self.rollover and reg == 0x78) {
            self.high_reads +%= 1;
            return self.high_reads;
        }
        return self.registers[reg];
    }

    pub fn writeRegister(self: *Fake, address: u7, reg: u8, value: u8) !void {
        std.debug.assert(address == 0x34);
        if (self.fail_register == reg) return error.NoAcknowledge;
        self.registers[reg] = value;
        self.writes += 1;
    }
};

test "telemetry uses correct ADC widths, units, enables and jack input modes" {
    var bus = Fake{};
    bus.registers[3] = 3;
    bus.registers[0] = 0x30;
    bus.registers[1] = 0x60;
    bus.registers[0x82] = 0xc8;
    bus.registers[0x78] = 0xe9;
    bus.registers[0x79] = 0xfb;
    bus.registers[0x7a] = 3;
    bus.registers[0x7b] = 0xff;
    bus.registers[0x5a] = 0xb8;
    bus.registers[0x5b] = 0xf;
    bus.registers[0x90] = 0xa7;
    bus.registers[0x92] = 0xb7;
    bus.registers[0x94] = 0x20;
    var device = Device(*Fake).init(&bus, 0x34);
    try device.identify();
    try std.testing.expectError(error.JackInputsNotConfigured, device.jacks());
    try device.configureJackInputs();
    try std.testing.expect(bus.registers[0x90] == 0xa1 and bus.registers[0x92] == 0xb1);
    const telemetry = try device.telemetry();
    try std.testing.expectEqual(@as(?u16, 4113), telemetry.battery_mv);
    try std.testing.expectEqual(@as(?u32, 63500), telemetry.charge_microamps);
    try std.testing.expect(telemetry.status.usb_present and telemetry.status.charging and telemetry.status.battery_present);
    try std.testing.expect(telemetry.jacks.headphone and !telemetry.jacks.line);
    bus.registers[0x82] = 0;
    const disabled = try device.telemetry();
    try std.testing.expect(disabled.battery_mv == null and disabled.charge_microamps == null);
}

test "all jack combinations and debounce wrap bounce and I2C failure" {
    for (0..4) |bits| {
        const state = Jacks.fromRegister(@as(u8, @intCast(bits)) << 4);
        try std.testing.expectEqual(bits & 1 == 0, state.headphone);
        try std.testing.expectEqual(bits & 2 == 0, state.line);
    }
    var debounce = JackDebounce{};
    const hp = Jacks{ .headphone = true, .line = false };
    try std.testing.expect(debounce.update(0xfffffff0, hp, 32) == null);
    try std.testing.expect(debounce.update(0x0f, hp, 32) == null);
    try std.testing.expectEqual(hp, debounce.update(0x10, hp, 32).?);
    try std.testing.expectEqual(hp, debounce.update(0x11, .{ .headphone = false, .line = false }, 32).?);
    try std.testing.expect(debounce.update(0x12, null, 32) == null);
}

test "unstable ADC and communication failures never become plausible zero readings" {
    var bus = Fake{};
    var device = Device(*Fake).init(&bus, 0x34);
    try device.configureJackInputs();
    bus.registers[0x82] = 0x80;
    bus.rollover = true;
    try std.testing.expectError(error.UnstableAdc, device.telemetry());
    bus.rollover = false;
    bus.fail_register = 0x79;
    try std.testing.expectError(error.NoAcknowledge, device.telemetry());
}

test "charge limiter preserves voltage, termination and enable and never raises current" {
    for (0..256) |value| for ([_]u16{ 0, 99, 100, 189, 500, 780, 1320, 65535 }) |limit| {
        var bus = Fake{};
        bus.registers[0x33] = @intCast(value);
        var device = Device(*Fake).init(&bus, 0x34);
        try device.limitChargeCurrent(limit);
        const next = bus.registers[0x33];
        try std.testing.expectEqual(@as(u8, @intCast(value)) & 0x70, next & 0x70);
        try std.testing.expect(charge_currents_ma[next & 15] <= charge_currents_ma[value & 15]);
        if (limit < 100) try std.testing.expect(next & 0x80 == 0) else try std.testing.expectEqual(@as(u8, @intCast(value)) & 0x80, next & 0x80);
        try std.testing.expectEqual(@as(usize, if (next == value) 0 else 1), bus.writes);
    };
}

test "coulomb deltas handle wrap and reject changed ADC configuration" {
    const before = Coulomb{ .charge = 0xfffffffe, .discharge = 10, .rate_hz = 25, .running = true };
    var after = before;
    after.charge = 1;
    after.discharge = 12;
    const delta = after.deltaMicroampHours(before).?;
    try std.testing.expectEqual(@as(u64, 3) * 65536 * 500 / (3600 * 25), delta.charge);
    after.rate_hz = 50;
    try std.testing.expect(after.deltaMicroampHours(before) == null);
    after = before;
    after.running = false;
    try std.testing.expect(after.deltaMicroampHours(before) == null);
}

test "coulomb enable preserves reserved bits without clearing counters or changing rails" {
    for (0..256) |old| {
        var bus = Fake{};
        bus.registers[0xb8] = @intCast(old);
        bus.registers[0x33] = 0xc4;
        var device = Device(*Fake).init(&bus, 0x34);
        try device.enableCoulombCounting();
        try std.testing.expectEqual(@as(u8, @intCast(old)) & 31 | 128, bus.registers[0xb8]);
        try std.testing.expectEqual(0xc4, bus.registers[0x33]);
    }
    var bus = Fake{};
    bus.registers[0x82] = 0x44;
    bus.registers[0x83] = 0x80;
    bus.registers[0x84] = 0x80;
    bus.registers[0xb8] = 0x80;
    bus.registers[0xb0] = 0x12;
    bus.registers[0xb3] = 0x34;
    bus.registers[0x5c] = 2;
    bus.registers[0x5d] = 0x1f;
    bus.registers[0x5e] = 100;
    var device = Device(*Fake).init(&bus, 0x34);
    try device.configureJackInputs();
    const count = try device.coulomb();
    try std.testing.expectEqual(100, count.rate_hz);
    try std.testing.expect(count.running);
    try std.testing.expectEqual(0x12000034, count.charge);
    const telemetry = try device.telemetry();
    try std.testing.expectEqual(@as(?u32, 47 * 375), telemetry.usb_microamps);
    try std.testing.expectEqual(@as(?i32, 15300), telemetry.die_millicelsius);
}

test "telemetry enables only the requested ADC channels" {
    for (0..256) |old| {
        var bus = Fake{};
        bus.registers[0x82] = @intCast(old);
        bus.registers[0x84] = 0xa5;
        bus.registers[0x33] = 0xc4;
        var device = Device(*Fake).init(&bus, 0x34);
        try device.enableTelemetry();
        try std.testing.expectEqual(@as(u8, @intCast(old)) | 0xcc, bus.registers[0x82]);
        try std.testing.expectEqual(0xa5, bus.registers[0x84]);
        try std.testing.expectEqual(0xc4, bus.registers[0x33]);
    }
}
