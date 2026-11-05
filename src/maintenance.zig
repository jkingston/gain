//! Optional RAM-development controls: bounded semantic commands and read-only
//! status. Commands commit after USB ACK and execute in the application owner.
const std = @import("std");
const x = @import("x1000.zig");
const c = @import("c_usb");
const usb = @import("f20_usb.zig");
const diag = @import("f20_diagnostics.zig");
const protocol = @import("maintenance_protocol.zig");

var state: protocol.State = .{};
var response: diag.Report = .{};
var health: @import("health.zig").Snapshot = .{};

pub fn pending() bool {
    return state.ready != null;
}

pub fn peek() ?protocol.Command {
    return state.ready;
}
var pixels: [1024]u8 = undefined;
var failure_text: [64]u8 = @splat(0);
var ack: u32 = 0x4741494e;

pub fn control(rhport: u8, stage: u8, request: ?*const c.tusb_control_request_t) bool {
    const bytes: *const [8]u8 = @ptrCast(request orelse return false);
    if (stage == c.CONTROL_STAGE_SETUP) {
        const command = state.begin(bytes.*, usb.session().playerAllowed());
        if (bytes[0] != 0xc0 or std.mem.readInt(u16, bytes[4..6], .little) != 0) return false;
        const length = std.mem.readInt(u16, bytes[6..8], .little);
        if (bytes[1] == 0x60 and std.mem.readInt(u16, bytes[2..4], .little) == 0 and length > 0) {
            response = diag.report;
            response.raw_timer = x.Timer.now();
            response.ui_trace_next = @import("display_trace.zig").ring.next;
            response.usb_state = @backingInt(usb.session().state);
            return c.tud_control_xfer(rhport, request, &response, @sizeOf(diag.Report));
        }
        if (bytes[1] == 0x73 and length == @sizeOf(@import("health.zig").Snapshot) and std.mem.readInt(u16, bytes[2..4], .little) == 0) {
            health = @import("health.zig").snapshot;
            return c.tud_control_xfer(rhport, request, &health, @sizeOf(@import("health.zig").Snapshot));
        }
        if (bytes[1] == 0x70 and length > 0) {
            const offset = @as(usize, std.mem.readInt(u16, bytes[2..4], .little)) * pixels.len;
            const framebuffer = std.mem.sliceAsBytes(@import("f20_display.zig").framebuffer);
            if (offset >= framebuffer.len) return false;
            const n = @min(@min(length, pixels.len), framebuffer.len - offset);
            @memcpy(pixels[0..n], framebuffer[offset..][0..n]);
            return c.tud_control_xfer(rhport, request, &pixels, @intCast(n));
        }
        if (bytes[1] == 0x72 and length > 0) {
            const offset = @as(usize, std.mem.readInt(u16, bytes[2..4], .little)) * pixels.len;
            const data = std.mem.sliceAsBytes(&@import("display_trace.zig").ring.entries);
            if (offset >= data.len) return false;
            const n = @min(@min(length, pixels.len), data.len - offset);
            @memcpy(pixels[0..n], data[offset..][0..n]);
            return c.tud_control_xfer(rhport, request, &pixels, @intCast(n));
        }
        if (bytes[1] == 0x71 and length > 0) {
            @memset(&failure_text, 0);
            const code = if (diag.report.scan_failure != 0) diag.report.scan_failure else diag.report.failure;
            if (code > 0 and code < 65536) {
                const text = @errorName(@errorFromInt(@as(u16, @intCast(code))));
                @memcpy(failure_text[0..@min(text.len, failure_text.len)], text[0..@min(text.len, failure_text.len)]);
            }
            return c.tud_control_xfer(rhport, request, &failure_text, failure_text.len);
        }
        if (command == null) return false;
        return c.tud_control_xfer(rhport, request, &ack, 4);
    }
    if (stage == c.CONTROL_STAGE_ACK) state.ack(bytes.*);
    return true;
}

pub fn take() ?protocol.Command {
    return state.take();
}
const base: usize = 0xb3500000;
var saved: @import("usb_rom.zig").Snapshot = undefined;
var masks: [2]u32 = undefined;
var saved_valid = false;

pub fn saveRom() void {
    saved = @import("usb_rom.zig").Snapshot.capture();
    masks = x.Interrupts.masks();
    saved_valid = true;
}

extern fn rom_return() callconv(.c) noreturn;

pub fn returnRom() noreturn {
    asm volatile ("di;ehb");
    x.Watchdog.stop();
    x.Interrupts.maskAll();
    x.write32(0xb2000038, 1);
    x.write32(0xb2000010, 1);
    x.write32(0xb200000c, ~@as(u32, 1));
    const rom: [*]const u8 = @ptrFromInt(0xbfc00000);
    if (std.hash.Crc32.hash(rom[0..16384]) != 0x8924d530) {
        diag.failed(8, error.UnsupportedBootRom);
        while (true) asm volatile ("nop");
    }
    usb.resetForRom() catch {
        x.Watchdog.start(.external, .by_1024, 1024);
        while (true) asm volatile ("nop");
    };
    // A new ROM session has its own stack/configuration; no old USB state or
    // application/loader return frame is resumed.
    rom_fresh_enter();
}

extern fn rom_fresh_enter() callconv(.c) noreturn;
