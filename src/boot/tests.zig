const std = @import("std");
const image = @import("image.zig");
const fat = @import("../fat32.zig");
test {
    _ = image;
    _ = @import("selection.zig");
    _ = @import("boot_ack.zig");
    _ = @import("usb_reset.zig");
}

// Compact FAT32 superfloppy with a deliberately fragmented three-cluster file.
// Only a read interface is provided: boot loading cannot mutate the medium.
const Disk = struct {
    bytes: [16 * 512]u8 = @splat(0),
    fail_lba: ?u32 = null,
    reads: u32 = 0,
    pub fn readBlocks(self: *@This(), lba: u32, output: []u8) !void {
        if (self.fail_lba == lba) return error.InjectedReadFailure;
        const mapped = if (lba >= 513) lba - 511 else lba;
        if (mapped >= 16 or output.len > self.bytes.len - mapped * 512) return error.ReadBeyondMedium;
        @memcpy(output, self.bytes[mapped * 512 ..][0..output.len]);
        self.reads += 1;
    }
    fn put16(self: *@This(), at: usize, value: u16) void {
        std.mem.writeInt(u16, self.bytes[at..][0..2], value, .little);
    }
    fn put32(self: *@This(), at: usize, value: u32) void {
        std.mem.writeInt(u32, self.bytes[at..][0..4], value, .little);
    }
    fn prepare(self: *@This(), payload: []const u8) void {
        self.put16(11, 512);
        self.bytes[13] = 1;
        self.put16(14, 1);
        self.bytes[16] = 1;
        self.put32(32, 66040);
        self.put32(36, 512);
        self.put32(44, 2);
        self.put16(510, 0xaa55);
        self.put32(512, 0xffffff8);
        self.put32(516, 0xfffffff);
        self.put32(520, 0xfffffff);
        self.put32(524, 5);
        self.put32(532, 4);
        self.put32(528, 0xfffffff);
        @memcpy(self.bytes[1024..1035], "GAIN    F20");
        self.bytes[1035] = 0x20;
        self.put16(1024 + 26, 3);
        self.put32(1024 + 28, @intCast(payload.len));
        var offset: usize = 0;
        for ([_]usize{ 3, 5, 4 }) |lba| {
            const count = @min(payload.len - offset, 512);
            @memcpy(self.bytes[lba * 512 ..][0..count], payload[offset..][0..count]);
            offset += count;
        }
    }
};
const Volume = fat.Volume(Disk);
test "fragmented SD firmware boots through the production FAT reader" {
    var payload: [1234]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i *% 37);
    var container: [1298]u8 = undefined;
    _ = image.envelope(&payload, &container);
    var disk = Disk{};
    disk.prepare(&container);
    const untouched = disk.bytes;
    var scratch: [512]u8 = undefined;
    var volume = try Volume.mount(&disk, &scratch);
    const file = try (try volume.findPath("gain.f20")).file();
    var reader = try volume.reader(file);
    var output: [1234]u8 = undefined;
    _ = try image.load(&reader, file.size, &output);
    try std.testing.expectEqualSlices(u8, &payload, &output);
    try std.testing.expectEqualSlices(u8, &untouched, &disk.bytes);
    try std.testing.expectError(error.NotFound, volume.findPath("missing.f20"));
}
test "media error during load prevents a valid image result" {
    var payload: [1234]u8 = @splat(0x55);
    var container: [1298]u8 = undefined;
    _ = image.envelope(&payload, &container);
    for ([_]u32{ 514, 516, 515 }) |bad| {
        var disk = Disk{};
        disk.prepare(&container);
        disk.fail_lba = bad;
        var scratch: [512]u8 = undefined;
        var volume = try Volume.mount(&disk, &scratch);
        const file = try (try volume.findPath("GAIN.F20")).file();
        var reader = try volume.reader(file);
        var output: [1234]u8 = undefined;
        try std.testing.expectError(error.InjectedReadFailure, image.load(&reader, file.size, &output));
    }
}

test "short and cyclic FAT chains cannot yield a validated boot image" {
    var payload: [1234]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i *% 37);
    var container: [1298]u8 = undefined;
    _ = image.envelope(&payload, &container);
    for ([_]u32{ 0x0fffffff, 3 }) |next| {
        var disk = Disk{};
        disk.prepare(&container);
        disk.put32(512 + 3 * 4, next);
        var scratch: [512]u8 = undefined;
        var volume = try Volume.mount(&disk, &scratch);
        const file = try (try volume.findPath("GAIN.F20")).file();
        var reader = try volume.reader(file);
        var output: [1234]u8 = undefined;
        if (image.load(&reader, file.size, &output)) |_| return error.AcceptedCorruptChain else |_| {}
    }
}

test "every interrupted current copy falls back to the complete previous payload" {
    const selection = @import("selection.zig");
    const Reader = struct {
        data: []const u8,
        at: usize = 0,
        pub fn read(self: *@This(), output: []u8) !usize {
            const count = @min(output.len, self.data.len - self.at);
            @memcpy(output[0..count], self.data[self.at..][0..count]);
            self.at += count;
            return count;
        }
    };
    const Candidates = struct {
        current: []const u8,
        previous: []const u8,
        output: []u8,
        pub fn load(self: *@This(), slot: selection.Slot) !image.Header {
            const data = if (slot == .current) self.current else self.previous;
            var reader = Reader{ .data = data };
            return image.load(&reader, @intCast(data.len), self.output);
        }
    };
    var current: [320]u8 = undefined;
    var previous: [320]u8 = undefined;
    const current_payload: [256]u8 = @splat(0x19);
    const previous_payload: [256]u8 = @splat(0x73);
    _ = image.envelope(&current_payload, &current);
    _ = image.envelope(&previous_payload, &previous);
    var output: [256]u8 = undefined;
    for (0..current.len) |length| {
        var candidates = Candidates{ .current = current[0..length], .previous = &previous, .output = &output };
        const chosen = try selection.choose(&candidates, false);
        try std.testing.expectEqual(selection.Slot.previous, chosen.slot);
        try std.testing.expectEqualSlices(u8, &previous_payload, &output);
    }
}
