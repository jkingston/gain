//! DWC2 state required to resume the X1000 ROM's PIO USB driver.
//! The caller must stop/reset the native DMA core before restoring registers.
const std = @import("std");
const x = @import("x1000.zig");

const base: usize = 0xb3500000;
const soft_disconnect: u32 = 1 << 1;

// FIFO allocation is not reset to the ROM layout by a DWC2 core reset. The
// ROM also expects both EP0 and bulk EP1 to retain their type, MPS and FIFO.
const configuration = [_]u16{ 0, 0x0c, 0x18, 0x24, 0x28, 0x5c, 0x104, 0x108, 0x800, 0x810, 0x814, 0x81c, 0x834 };
const endpoints = [_]u16{ 0x900, 0x920, 0xb00, 0xb20 };

const Endpoint = struct { control: u32, size: u32, dma: u32 };

const Hardware = struct {
    fn read(_: *@This(), offset: u16) u32 {
        return x.read32(base + offset);
    }

    fn write(_: *@This(), offset: u16, value: u32) void {
        x.write32(base + offset, value);
    }
};

pub const Snapshot = struct {
    ahb: u32,
    device_control: u32,
    config: [configuration.len]u32,
    endpoint: [endpoints.len]Endpoint,

    pub fn capture() Snapshot {
        var hardware: Hardware = .{};
        return captureWith(&hardware);
    }

    pub fn captureWith(driver: anytype) Snapshot {
        var result: Snapshot = undefined;
        result.ahb = driver.read(8);
        result.device_control = driver.read(0x804);
        for (configuration, &result.config) |offset, *value| value.* = driver.read(offset);
        for (endpoints, &result.endpoint) |offset, *endpoint| endpoint.* = .{
            .control = driver.read(offset),
            .size = driver.read(offset + 0x10),
            .dma = driver.read(offset + 0x14),
        };
        return result;
    }

    pub fn restoreQuiesced(self: Snapshot) void {
        var hardware: Hardware = .{};
        self.restoreWith(&hardware);
    }

    /// Transfer size and DMA address must precede endpoint enable. Never
    /// restore a captured W1C interrupt value: clear stale completions instead.
    pub fn restoreWith(self: Snapshot, driver: anytype) void {
        // Core reset clears SDIS. Hold the pull-up disconnected while FIFO,
        // address and endpoint state are rebuilt, then reconnect explicitly.
        driver.write(0x804, self.device_control | soft_disconnect);
        for (configuration, self.config) |offset, value| driver.write(offset, value);
        for (endpoints, self.endpoint) |offset, endpoint| {
            driver.write(offset + 0x10, endpoint.size);
            driver.write(offset + 0x14, endpoint.dma);
            driver.write(offset + 8, 0xffff_ffff);
        }
        for (endpoints, self.endpoint) |offset, endpoint| driver.write(offset, endpoint.control);
        driver.write(0x14, 0xffff_ffff);
    }

    pub fn reconnect(self: Snapshot) void {
        var hardware: Hardware = .{};
        self.reconnectWith(&hardware);
    }

    /// Call after the disconnect settling interval and register restoration.
    pub fn reconnectWith(self: Snapshot, driver: anytype) void {
        driver.write(8, self.ahb);
        driver.write(0x804, self.device_control & ~soft_disconnect);
    }
};

const Fake = struct {
    registers: [0x1000 / 4]u32 = @splat(0),
    writes: [64]u16 = undefined,
    count: usize = 0,

    fn read(self: *@This(), offset: u16) u32 {
        return self.registers[offset / 4];
    }

    fn write(self: *@This(), offset: u16, value: u32) void {
        self.writes[self.count] = offset;
        self.count += 1;
        self.registers[offset / 4] = value;
    }

    fn position(self: @This(), offset: u16) usize {
        return std.mem.indexOfScalar(u16, self.writes[0..self.count], offset) orelse unreachable;
    }
};

test "ROM bulk endpoint and FIFO configuration survive native USB reset" {
    var driver: Fake = .{};
    for (&driver.registers, 0..) |*value, index| value.* = @intCast(index * 37);
    driver.registers[8 / 4] = 1; // ROM PIO, interrupts enabled.
    driver.registers[0x804 / 4] = 0x10002;
    driver.registers[0x104 / 4] = 0x04000497;
    driver.registers[0x108 / 4] = 0x00800897;
    driver.registers[0x920 / 4] = 0x10488200;
    driver.registers[0xb20 / 4] = 0x94088200;
    const snapshot = Snapshot.captureWith(&driver);
    const original = driver.registers;
    @memset(&driver.registers, 0); // Model the native core reset.
    // Observed FIFO defaults after reset differ from the ROM's allocation.
    driver.registers[0x104 / 4] = 0x0e401c80;
    snapshot.restoreWith(&driver);
    for (configuration) |offset| try std.testing.expectEqual(original[offset / 4], driver.read(offset));
    for (endpoints) |offset| {
        for ([_]u16{ 0, 0x10, 0x14 }) |field| try std.testing.expectEqual(original[(offset + field) / 4], driver.read(offset + field));
        try std.testing.expect(driver.position(offset + 0x10) < driver.position(offset));
        try std.testing.expect(driver.position(offset + 0x14) < driver.position(offset));
        try std.testing.expect(driver.position(0x104) < driver.position(offset));
        try std.testing.expect(driver.position(offset + 8) < driver.position(offset));
    }
    try std.testing.expectEqual(@as(u32, 0), driver.read(8));
    try std.testing.expectEqual(@as(u32, 0x10002), driver.read(0x804));
    try std.testing.expectEqual(@as(u16, 0x804), driver.writes[0]);
    snapshot.reconnectWith(&driver);
    try std.testing.expectEqual(@as(u32, 1), driver.read(8));
    try std.testing.expectEqual(@as(u32, 0x10000), driver.read(0x804));
    try std.testing.expectEqual(@as(u16, 0x804), driver.writes[driver.count - 1]);
}
