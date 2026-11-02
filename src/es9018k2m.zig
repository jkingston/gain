//! ES9018K2M register protocol, independent of the I2C controller and board.
//! ESS datasheet v3.7 (2021-04-22), registers 1, 6, 7, 10-16, 21 and 64-69.
const std = @import("std");

pub const Register = enum(u8) {
    input = 1,
    volume_control = 6,
    general = 7,
    master = 10,
    dpll = 12,
    left_volume = 15,
    right_volume = 16,
    filter_bypass = 21,
    status = 64,
    ratio_low = 66,
};

pub const Filter = enum(u2) { fast, slow, minimum_phase };

pub const Deemphasis = enum { off, hz_32_000, hz_44_100, hz_48_000 };

pub const Status = struct {
    raw: u8,

    pub fn supported(self: Status) bool {
        return self.raw & 0x1c == 0x10;
    }

    pub fn locked(self: Status) bool {
        return self.raw & 1 != 0;
    }

    pub fn automuted(self: Status) bool {
        return self.raw & 2 != 0;
    }

    pub fn revision(self: Status) enum { v, w } {
        return if (self.raw & 0x20 != 0) .v else .w;
    }
};

pub const Config = struct {
    left_attenuation: u8 = 16,
    right_attenuation: u8 = 16,
    filter: Filter = .fast,
    ramp_rate: u3 = 2,
    dpll_bandwidth: u8 = 0xda,
    stop_divider: u4 = 15,
    muted: bool = false,
};

pub const Error = error{ UnsupportedDevice, VerificationMismatch, NotConfigured, MustBeMuted, UnsupportedDeemphasisRate };

/// Bus implements readRegister(address, register) and writeRegister(...).
/// A failed configuration/control transaction invalidates configuration and
/// attempts a soft mute after the device has been identified;
/// the board adapter must also assert its independent analogue mute on error.
pub fn Device(comptime Bus: type) type {
    return struct {
        const Self = @This();
        bus: Bus,
        address: u7,
        configured: bool = false,
        general: u8 = 0x83,
        bypass: u8 = 0,
        volume_control: u8 = 0x4a,
        muted: bool = true,

        pub fn init(bus: Bus, address: u7) Self {
            return .{ .bus = bus, .address = address };
        }

        pub fn status(self: *Self) !Status {
            return .{ .raw = try self.read(.status) };
        }

        pub fn configure(self: *Self, config: Config) !Status {
            const previously_configured = self.configured;
            self.configured = false;
            const identity = self.status() catch |failure| {
                if (previously_configured) self.fault();
                return failure;
            };
            if (!identity.supported()) {
                self.muted = true;
                return error.UnsupportedDevice;
            }
            errdefer self.fault();
            self.general = (try self.read(.general) & 0x0c) | 0x83;
            try self.write(.general, self.general);
            self.muted = true;
            try self.write(.input, 0x80); // Fixed 32-bit I2S slots, no input auto-detect.
            try self.write(.master, config.stop_divider); // X1000 supplies BCLK/LRCK.
            try self.write(.dpll, config.dpll_bandwidth);
            self.volume_control = 0x48 | @as(u8, config.ramp_rate);
            try self.write(.volume_control, self.volume_control);
            // Keep external GPIO selectors; always retain the interpolating FIR.
            self.bypass = try self.read(.filter_bypass) & ~@as(u8, 5);
            try self.write(.filter_bypass, self.bypass);
            self.general = (self.general & ~@as(u8, 0x60)) | (@as(u8, @backingInt(config.filter)) << 5);
            try self.write(.general, self.general);
            try self.write(.left_volume, config.left_attenuation);
            try self.write(.right_volume, config.right_attenuation);
            self.configured = true;
            if (!config.muted) try self.setMute(false);
            return identity;
        }

        pub fn setMute(self: *Self, muted: bool) !void {
            try self.ready();
            errdefer self.fault();
            const next = (self.general & ~@as(u8, 3)) | @as(u8, if (muted) 3 else 0);
            try self.write(.general, next);
            self.general = next;
            self.muted = muted;
        }

        /// Half-decibel attenuation, 0..127.5 dB; no PCM samples are changed.
        pub fn setVolume(self: *Self, left: u8, right: u8) !void {
            try self.ready();
            errdefer self.fault();
            try self.write(.left_volume, left);
            try self.write(.right_volume, right);
        }

        pub fn setFilter(self: *Self, filter: Filter) !void {
            try self.readyMuted();
            errdefer self.fault();
            const next = (self.general & ~@as(u8, 0x60)) | (@as(u8, @backingInt(filter)) << 5);
            try self.write(.general, next);
            self.general = next;
        }

        /// IIR bypass is distinct from FIR/NOS bypass. External 8x oversampling
        /// is not supplied by this firmware, so register 21 bit 0 stays clear.
        pub fn setIirBypass(self: *Self, bypass: bool) !void {
            try self.readyMuted();
            errdefer self.fault();
            const next = (self.bypass & ~@as(u8, 5)) | (@as(u8, @intFromBool(bypass)) << 2);
            try self.write(.filter_bypass, next);
            self.bypass = next;
        }

        pub fn setDeemphasis(self: *Self, mode: Deemphasis, sample_rate: u32) !void {
            try self.readyMuted();
            const selector: u8 = switch (mode) {
                .off => 0x40,
                .hz_32_000 => if (sample_rate == 32_000) 0 else return error.UnsupportedDeemphasisRate,
                .hz_44_100 => if (sample_rate == 44_100) 0x10 else return error.UnsupportedDeemphasisRate,
                .hz_48_000 => if (sample_rate == 48_000) 0x20 else return error.UnsupportedDeemphasisRate,
            };
            errdefer self.fault();
            const next = (self.volume_control & 7) | 8 | selector;
            try self.write(.volume_control, next);
            self.volume_control = next;
        }

        /// Reading 66 first latches all four ratio bytes until 69 is read.
        pub fn measuredSampleRate(self: *Self, master_clock_hz: u32) !u32 {
            try self.ready();
            var ratio: u32 = 0;
            for (0..4) |index| {
                const value = try self.bus.readRegister(self.address, @as(u8, @backingInt(Register.ratio_low)) + @as(u8, @intCast(index)));
                ratio |= @as(u32, value) << @as(u5, @intCast(index * 8));
            }
            return @intCast((@as(u64, ratio) * master_clock_hz + (1 << 31)) >> 32);
        }

        fn ready(self: *Self) Error!void {
            if (!self.configured) return error.NotConfigured;
        }

        fn readyMuted(self: *Self) Error!void {
            try self.ready();
            if (!self.muted) return error.MustBeMuted;
        }

        fn read(self: *Self, register: Register) !u8 {
            return self.bus.readRegister(self.address, @backingInt(register));
        }

        fn write(self: *Self, register: Register, value: u8) !void {
            try self.bus.writeRegister(self.address, @backingInt(register), value);
            if (try self.read(register) != value) return error.VerificationMismatch;
        }

        fn fault(self: *Self) void {
            self.configured = false;
            self.muted = true;
            self.general |= 3;
            self.bus.writeRegister(self.address, @backingInt(Register.general), self.general) catch {};
        }
    };
}

const Fake = struct {
    registers: [128]u8 = @splat(0),
    calls: usize = 0,
    writes: usize = 0,
    fail_at: ?usize = null,
    corrupt_read: ?u8 = null,
    read_order: [128]u8 = undefined,
    read_count: usize = 0,

    pub fn readRegister(self: *Fake, address: u7, register: u8) !u8 {
        std.debug.assert(address == 0x48);
        self.calls += 1;
        if (self.fail_at == self.calls) return error.NoAcknowledge;
        if (self.read_count < self.read_order.len) {
            self.read_order[self.read_count] = register;
            self.read_count += 1;
        }
        return self.registers[register] ^ @as(u8, if (self.corrupt_read == register) 1 else 0);
    }

    pub fn writeRegister(self: *Fake, address: u7, register: u8, value: u8) !void {
        std.debug.assert(address == 0x48);
        self.calls += 1;
        if (self.fail_at == self.calls) return error.NoAcknowledge;
        self.registers[register] = value;
        self.writes += 1;
    }

    fn init() Fake {
        var result = Fake{};
        result.registers[64] = 0x31;
        result.registers[7] = 0x8c;
        result.registers[21] = 0xa5;
        return result;
    }
};

test "actual identity, reserved bits, filter selection and FIR safety" {
    var bus = Fake.init();
    var device = Device(*Fake).init(&bus, 0x48);
    const identity = try device.configure(.{});
    try std.testing.expect(identity.supported() and identity.locked() and identity.revision() == .v);
    try std.testing.expectEqual(@as(u8, 0x8c), bus.registers[7]);
    try std.testing.expectEqual(@as(u8, 0xa0), bus.registers[21]);
    try std.testing.expectError(error.MustBeMuted, device.setFilter(.slow));
    try device.setMute(true);
    for ([_]Filter{ .fast, .slow, .minimum_phase }) |filter| {
        try device.setFilter(filter);
        try std.testing.expectEqual(@as(u8, 0x8f) | (@as(u8, @backingInt(filter)) << 5), bus.registers[7]);
    }
    try device.setIirBypass(true);
    try std.testing.expectEqual(@as(u8, 0xa4), bus.registers[21]);
    try device.setDeemphasis(.hz_44_100, 44100);
    try std.testing.expectEqual(@as(u8, 0x1a), bus.registers[6]);
    try std.testing.expectError(error.UnsupportedDeemphasisRate, device.setDeemphasis(.hz_44_100, 48000));
    try device.setDeemphasis(.off, 192000);
    try std.testing.expectEqual(@as(u8, 0x4a), bus.registers[6]);
    try device.setVolume(64, 68);
    try std.testing.expect(bus.registers[15] == 64 and bus.registers[16] == 68);
}

test "wrong identity never causes a configuration write" {
    var bus = Fake.init();
    bus.registers[64] = 0xff;
    var device = Device(*Fake).init(&bus, 0x48);
    try std.testing.expectError(error.UnsupportedDevice, device.configure(.{}));
    try std.testing.expectEqual(@as(usize, 0), bus.writes);
}

test "every configuration communication failure prevents use and attempts mute" {
    var baseline = Fake.init();
    var good = Device(*Fake).init(&baseline, 0x48);
    _ = try good.configure(.{});
    for (1..baseline.calls + 1) |at| {
        var bus = Fake.init();
        bus.fail_at = at;
        var device = Device(*Fake).init(&bus, 0x48);
        if (device.configure(.{})) |_| return error.ExpectedFailure else |_| {}
        try std.testing.expect(!device.configured);
        if (at > 1) try std.testing.expect(bus.registers[7] & 3 == 3);
    }
}

test "partial stereo write and verification failure fail closed" {
    var bus = Fake.init();
    var device = Device(*Fake).init(&bus, 0x48);
    _ = try device.configure(.{});
    bus.fail_at = bus.calls + 3;
    try std.testing.expectError(error.NoAcknowledge, device.setVolume(64, 64));
    try std.testing.expect(!device.configured and device.muted and bus.registers[7] & 3 == 3);
    bus = Fake.init();
    device = Device(*Fake).init(&bus, 0x48);
    _ = try device.configure(.{});
    bus.corrupt_read = 15;
    try std.testing.expectError(error.VerificationMismatch, device.setVolume(64, 64));
    try std.testing.expect(!device.configured and device.muted);
}

test "sample ratio is read in latched order" {
    var bus = Fake.init();
    var device = Device(*Fake).init(&bus, 0x48);
    _ = try device.configure(.{});
    const ratio: u32 = 1 << 24;
    for (0..4) |index| bus.registers[66 + index] = @truncate(ratio >> @as(u5, @intCast(index * 8)));
    bus.read_count = 0;
    try std.testing.expectEqual(@as(u32, 48000), try device.measuredSampleRate(12288000));
    try std.testing.expectEqualSlices(u8, &.{ 66, 67, 68, 69 }, bus.read_order[0..4]);
}

test "reconfiguration cannot retain a stale ready state after identity-read failure" {
    var bus = Fake{};
    bus.registers[64] = 0x31;
    var device = Device(*Fake).init(&bus, 0x48);
    _ = try device.configure(.{});
    try std.testing.expect(device.configured and !device.muted);
    bus.fail_at = bus.calls + 1;
    try std.testing.expectError(error.NoAcknowledge, device.configure(.{}));
    try std.testing.expect(!device.configured and device.muted);
    try std.testing.expect(bus.registers[7] & 3 == 3);
}
