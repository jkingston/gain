const x1000 = @import("x1000.zig");

pub const Error = error{
    ClockHeldLow,
    NoAcknowledge,
};

/// Open-drain software I2C for board devices used during early bring-up.
pub const Bus = struct {
    scl: x1000.Gpio.Pin,
    sda: x1000.Gpio.Pin,

    pub fn init(scl: x1000.Gpio.Pin, sda: x1000.Gpio.Pin) Bus {
        return .{ .scl = scl, .sda = sda };
    }

    pub fn readRegister(self: Bus, device: u7, index: u8) Error!u8 {
        try self.start();
        errdefer self.stop() catch {};
        try self.writeByte(@as(u8, device) << 1);
        try self.writeByte(index);
        try self.start();
        try self.writeByte((@as(u8, device) << 1) | 1);
        const value = try self.readByte();
        try self.stop();
        return value;
    }

    pub fn writeRegister(self: Bus, device: u7, index: u8, value: u8) Error!void {
        try self.start();
        errdefer self.stop() catch {};
        try self.writeByte(@as(u8, device) << 1);
        try self.writeByte(index);
        try self.writeByte(value);
        try self.stop();
    }

    fn driveLow(_: Bus, pin: x1000.Gpio.Pin) void {
        pin.output(false);
    }

    fn release(_: Bus, pin: x1000.Gpio.Pin) void {
        pin.input();
    }

    fn clock(self: Bus, high: bool) Error!void {
        if (!high) {
            self.driveLow(self.scl);
        } else {
            self.release(self.scl);
            const started = x1000.Timer.now();
            while (!self.scl.get()) {
                if (x1000.Timer.elapsed(started) >= x1000.Timer.microseconds(clock_stretch_timeout_us)) {
                    return error.ClockHeldLow;
                }
            }
        }
        x1000.Timer.delayMicroseconds(half_period_us);
    }

    fn dataLine(self: Bus, high: bool) void {
        if (high) self.release(self.sda) else self.driveLow(self.sda);
        x1000.Timer.delayMicroseconds(half_period_us);
    }

    fn start(self: Bus) Error!void {
        self.dataLine(true);
        try self.clock(true);
        self.dataLine(false);
        try self.clock(false);
    }

    fn stop(self: Bus) Error!void {
        self.dataLine(false);
        try self.clock(true);
        self.dataLine(true);
    }

    fn writeByte(self: Bus, value: u8) Error!void {
        var mask: u8 = 0x80;
        while (mask != 0) : (mask >>= 1) {
            self.dataLine(value & mask != 0);
            try self.clock(true);
            try self.clock(false);
        }
        self.dataLine(true);
        try self.clock(true);
        const acknowledged = !self.sda.get();
        try self.clock(false);
        if (!acknowledged) return error.NoAcknowledge;
    }

    fn readByte(self: Bus) Error!u8 {
        var value: u8 = 0;
        self.dataLine(true);
        var bit_index: u4 = 0;
        while (bit_index < 8) : (bit_index += 1) {
            try self.clock(true);
            value = value << 1 | @intFromBool(self.sda.get());
            try self.clock(false);
        }
        self.dataLine(true);
        try self.clock(true);
        try self.clock(false); // NACK: this API reads one byte.
        return value;
    }
};

const half_period_us = 4;
const clock_stretch_timeout_us = 100;
