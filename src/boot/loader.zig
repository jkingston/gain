//! RAM-only bootloader spike. No NAND interface and no SD write capability.
const std = @import("std");
const platform = @import("platform");
const storage = platform.storage;
const image = @import("image.zig");
const selection = @import("selection.zig");
comptime {
    for (platform.memory.regions) |region| {
        const code_start = 0x1e00000;
        const code_end = code_start + 0x1a000;
        const stack_start = 0x1e1a000;
        const stack_end = 0x1e1f000;
        if (region.start < code_end and code_start < region.end() or
            region.start < stack_end and stack_start < region.end())
            @compileError("loader RAM overlaps the running Gain firmware");
    }
}
const request_magic = 0x47424f54;
const Request = extern struct { magic: u32, mode: u32, bytes: u32, execute: u32, path: [192]u8 };
const Report = extern struct {
    magic: u32 = request_magic,
    version: u32 = 2,
    complete: u32 = 0,
    failure: u32 = 0,
    stage: u32 = 0,
    relocated_pc: u32 = 0,
    payload_bytes: u32 = 0,
    payload_crc: u32 = 0,
    executed: u32 = 0,
    returned: u32 = 0,
    sd_reads: u32 = 0,
    sd_sectors: u32 = 0,
    ticks: u32 = 0,
    cause: u32 = 0,
    epc: u32 = 0,
    entry: u32 = 0,
    source: u32 = 0,
    fallback: u32 = 0,
};
const report: *volatile Report = @ptrFromInt(0xa0700000);
const host_request: *const Request = @ptrFromInt(0xa06ff000);
const default_request: Request = blk: {
    var config: Request = .{ .magic = request_magic, .mode = 2, .bytes = 0, .execute = 1, .path = @splat(0) };
    const path = "/.gain/firmware.f20";
    @memcpy(config.path[0..path.len], path);
    break :blk config;
};
fn register(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}
fn ticks() u32 {
    return register(0xb2000020).*;
}

// Use the already proven SD controller through a capability with no write
// methods. FAT's unused mutation functions cannot instantiate against it.
const ReadOnlyCard = struct {
    inner: storage.Controller,
    pub fn readBlocks(self: *@This(), lba: u32, bytes: []u8) !void {
        if (ticks() -% began > 30 * 6_000_000) return error.BootDeadline;
        try self.inner.readBlocks(lba, bytes);
        report.sd_reads += 1;
        report.sd_sectors += @intCast(bytes.len / 512);
    }
};
const Volume = storage.filesystem.Volume(ReadOnlyCard);
var began: u32 = 0;

fn loadCard(output: []u8, request: *const Request) !image.Header {
    var card = ReadOnlyCard{ .inner = try storage.Controller.initialize(.{
        .descriptor = @ptrFromInt(platform.memory.sd_control.uncached()),
        .switch_status = @ptrFromInt(platform.memory.sd_control.uncached() + 0x100),
    }) };
    defer {
        // DMA has completed before each read returns; mask MSC0 interrupts and stop DMA
        // before handing control back to the ROM's USB-only driver.
        register(0xb3450024).* = 0xffff_ffff;
        register(0xb3450028).* = 0xffff_ffff;
        register(0xb3450044).* = 0;
    }
    var volume = try Volume.mount(&card, @ptrFromInt(platform.memory.filesystem_sector.uncached()));
    report.stage = 3;
    const path_end = std.mem.indexOfScalar(u8, &request.path, 0) orelse return error.InvalidPath;
    if (path_end == 0) return error.InvalidPath;
    const file = try (try volume.findPath(request.path[0..path_end])).file();
    var inner = try volume.reader(file);
    var reader = try storage.BufferedReader(Volume.Reader).init(&inner, @as([*]u8, @ptrFromInt(platform.memory.storage_burst.uncached()))[0..32768]);
    return image.load(&reader, file.size, output);
}

const Candidates = struct {
    output: []u8,
    pub fn load(self: *@This(), slot: selection.Slot) !image.Header {
        var request = default_request;
        @memset(&request.path, 0);
        const path = if (slot == .current) "/.gain/firmware.f20" else "/.gain/previous.f20";
        @memcpy(request.path[0..path.len], path);
        return loadCard(self.output, &request);
    }
};

const MemoryReader = struct {
    bytes: []const u8,
    position: usize = 0,
    pub fn read(self: *@This(), output: []u8) !usize {
        const count = @min(output.len, self.bytes.len - self.position);
        @memcpy(output[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};

fn run(request: *const Request) !void {
    report.relocated_pc = executing_pc();
    if (report.relocated_pc < 0x81e00000 or report.relocated_pc >= 0x81e1a000) return error.RelocationFailed;
    if (request.magic != request_magic or request.execute > 1) return error.BadRequest;
    report.stage = 2;
    const output = @as([*]u8, @ptrFromInt(0x80004000))[0..image.limit];
    const parsed = switch (request.mode) {
        0 => blk: {
            if (request.bytes > image.limit + image.header_bytes) return error.InvalidSize;
            var reader = MemoryReader{ .bytes = @as([*]const u8, @ptrFromInt(0xa0800000))[0..request.bytes] };
            break :blk try image.load(&reader, request.bytes, output);
        },
        1 => try loadCard(output, request),
        2 => blk: {
            if (request.bytes > 1) return error.BadRequest;
            const back = platform.hardware.buttons[6].pin;
            back.input();
            var candidates = Candidates{ .output = output };
            const chosen = try selection.choose(&candidates, request.bytes == 1 or !back.get());
            report.source = if (chosen.slot == .current) 1 else 2;
            report.fallback = if (chosen.first_failure) |failure| failureCode(failure) else 0;
            break :blk chosen.header;
        },
        else => return error.BadRequest,
    };
    publishPayload(parsed.size);
    report.payload_bytes = parsed.size;
    report.payload_crc = parsed.checksum;
    report.ticks = ticks() -% began;
    report.stage = 4;
    if (request.execute == 1) {
        // Vendor U-Boot treats a retained 0xa1a1 marker as a failed boot.
        // Clear it only after complete firmware validation, preserving all
        // other scratch flags and the explicit stock-recovery request.
        var boot_ack = struct {
            pub fn read(_: *@This()) u32 {
                return register(0xb0000034).*;
            }
            pub fn unlock(_: *@This()) void {
                register(0xb0000038).* = 0x5a5a;
            }
            pub fn lock(_: *@This()) void {
                register(0xb0000038).* = 0xa5a5;
            }
            pub fn settle(_: *@This()) void {
                platform.soc.Timer.delayMicroseconds(100);
            }
            pub fn write(_: *@This(), value: u32) void {
                register(0xb0000034).* = value;
            }
        }{};
        try @import("boot_ack.zig").acknowledge(&boot_ack);
        report.executed = 1;
        payload_enter();
        report.returned = 1;
    }
    report.stage = 5;
}

// SD DMA writes only to its uncached read buffer. The CPU owns the cached
// destination, then publishes it before execution or ROM-side verification.
fn publishPayload(bytes: u32) void {
    const end = (image.address + bytes + 31) & ~@as(usize, 31);
    var line: usize = image.address;
    while (line < end) : (line += 32) {
        asm volatile ("cache 0x15, 0(%[at])"
            :
            : [at] "r" (line),
            : .{ .memory = true });
        asm volatile ("cache 0x10, 0(%[at])"
            :
            : [at] "r" (line),
            : .{ .memory = true });
    }
    platform.soc.memoryBarrier();
}

export fn loader_main(ram_session: u32) callconv(.c) noreturn {
    report.* = .{};
    report.entry = ram_session;
    // Re-establish OST2's 6 MHz timebase; never touch active DRAM training.
    register(0xb0000020).* &= ~@as(u32, 1 << 20);
    register(0xb2000000).* = (register(0xb2000000).* & ~@as(u32, 3 << 2)) | 4;
    // Keep the live counter epoch: resetting it races clock-domain writes
    // on warm entry and can make a relative deadline appear to wrap.
    register(0xb2000034).* = 2;
    began = ticks();
    platform.soc.Interrupts.maskAll();
    platform.soc.Watchdog.stop();
    if (ram_session == 0) {
        platform.soc.Interrupts.maskAll();
        platform.soc.Watchdog.stop();
        while (true) {
            began = ticks();
            report.failure = 0;
            run(&default_request) catch |failure| {
                report.failure = failureCode(failure);
                report.ticks = ticks() -% began;
                report.complete = 1;
                waitForRetry(failure);
                continue;
            };
            report.failure = 13;
            report.ticks = ticks() -% began;
            report.complete = 1;
            waitForRetry(error.FirmwareReturned);
        }
    }
    run(if (ram_session == 2) &default_request else host_request) catch |failure| {
        report.failure = failureCode(failure);
    };
    report.ticks = ticks() -% began;
    report.complete = 1;
    asm volatile ("sync" ::: .{ .memory = true });
    freshRecovery();
}
fn failureCode(failure: anyerror) u32 {
    return switch (failure) {
        error.Truncated, error.UnexpectedEnd => 1,
        error.BadMagic => 2,
        error.HeaderChecksum => 3,
        error.WrongTarget => 4,
        error.InvalidSize => 5,
        error.PayloadChecksum => 6,
        error.NotFound => 7,
        error.CardAbsent => 8,
        error.RelocationFailed => 9,
        error.BadRequest, error.InvalidPath => 10,
        error.BootDeadline => 11,
        else => 12,
    };
}

extern fn executing_pc() callconv(.c) u32;
extern fn payload_enter() callconv(.c) void;
extern fn rom_fresh_enter() callconv(.c) noreturn;
export fn player_check_fault(cause: u32, epc: u32) callconv(.c) noreturn {
    report.magic = request_magic;
    report.version = 2;
    report.failure = 99;
    report.cause = cause;
    report.epc = epc;
    report.complete = 1;
    freshRecovery();
}
export fn gain_x1000_interrupt() callconv(.naked) noreturn {
    asm volatile ("mfc0 $a0, $13\n mfc0 $a1, $14\n li $sp, 0x81e1f000\n la $gp, _gp\n j player_check_fault\n nop");
}
pub fn panic(message: []const u8, trace: ?*@import("std").builtin.StackTrace, address: ?usize) noreturn {
    _ = message;
    _ = trace;
    _ = address;
    player_check_fault(0xffff, 0);
}

/// Cold-boot errors remain visible and retry only after a deliberate button
/// press. Recovery entry itself is the processor's independent MENU/USB path.
fn waitForRetry(failure: anyerror) void {
    const display = platform.display;
    display.initialize() catch {};
    @memset(display.framebuffer, 0xffff);
    const text = @import("boot_text.zig");
    text.write(display.framebuffer, 20, 30, "Gain", 2);
    text.write(display.framebuffer, 20, 85, @errorName(failure), 1);
    text.write(display.framebuffer, 20, 120, "SD: .gain/firmware.f20", 1);
    text.write(display.framebuffer, 20, 155, "PLAY to retry", 1);
    text.write(display.framebuffer, 20, 185, "Reset with MENU held for USB", 1);
    _ = display.resetForDirect();
    _ = display.presentRegionCpu(0, 0, 320, 240);
    const usb = platform.hardware.usb_detect;
    usb.input();
    if (usb.get()) {
        platform.soc.Timer.delayMicroseconds(250_000);
        freshRecovery();
    }
    const button = platform.hardware.buttons[0].pin;
    button.input();
    while (!button.get()) platform.soc.Timer.delayMicroseconds(1000);
    while (button.get()) platform.soc.Timer.delayMicroseconds(1000);
    platform.soc.Timer.delayMicroseconds(50_000);
}

// The loader owns its exit; it never resumes a saved ROM, SPL,
// or U-Boot call frame. The exact ROM was independently archived twice.
fn freshRecovery() noreturn {
    const x = platform.soc;
    asm volatile ("di;ehb");
    x.Watchdog.stop();
    x.Interrupts.maskAll();
    x.write32(0xb2000038, 1);
    x.write32(0xb2000010, 1);
    x.write32(0xb200000c, ~@as(u32, 1));
    const rom: [*]const u8 = @ptrFromInt(0xbfc00000);
    if (std.hash.Crc32.hash(rom[0..16384]) != 0x8924d530) while (true) asm volatile ("nop");
    // Touch DWC2 only while its bus clock is live. ROM establishes its PHY
    // configuration afresh; the loader never enables USB DMA or address mapping.
    if (x.Cpm.clock_gate.read() & x.bit(3) == 0) {
        x.write32(0xb3500804, x.read32(0xb3500804) | 2);
        x.write32(0xb3500008, 0);
        var driver = struct {
            pub fn now(_: *@This()) u32 {
                return ticks();
            }
            pub fn state(_: *@This()) u32 {
                return platform.soc.read32(0xb3500010);
            }
            pub fn requestReset(_: *@This()) void {
                platform.soc.write32(0xb3500010, 1);
            }
            pub fn settle(_: *@This()) void {
                platform.soc.Timer.delayMicroseconds(10);
            }
        }{};
        @import("usb_reset.zig").reset(&driver, x.Timer.milliseconds(100)) catch {};
    }
    rom_fresh_enter();
}
