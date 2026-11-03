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

pub fn pending() bool {
    return state.ready != null;
}

pub fn peek() ?protocol.Command {
    return state.ready;
}
var ack: u32 = 0x4741494e;

pub fn control(rhport: u8, stage: u8, request: ?*const c.tusb_control_request_t) bool {
    const bytes: *const [8]u8 = @ptrCast(request orelse return false);
    if (stage == c.CONTROL_STAGE_SETUP) {
        const command = state.begin(bytes.*, usb.session().playerAllowed());
        if (bytes[0] != 0xc0 or std.mem.readInt(u16, bytes[4..6], .little) != 0) return false;
        const length = std.mem.readInt(u16, bytes[6..8], .little);
        if (bytes[1] == 0x60 and std.mem.readInt(u16, bytes[2..4], .little) == 0 and length > 0) {
            response = diag.report;
            response.usb_state = @backingInt(usb.session().state);
            return c.tud_control_xfer(rhport, request, &response, @sizeOf(diag.Report));
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
    if (saved_valid) {
        x.write32(base + 0x804, x.read32(base + 0x804) | 2);
        x.write32(base + 8, 0);
        usb.resetForRom() catch {
            // Never release DMA memory while the controller is still active.
            x.Watchdog.start(.external, .by_1024, 1024);
            while (true) asm volatile ("nop");
        };
        saved.restoreQuiesced();
        x.Timer.delayMicroseconds(250_000);
        saved.reconnect();
        x.Interrupts.restore(masks);
    }
    asm volatile ("sync" ::: .{ .memory = true });
    rom_return();
}
