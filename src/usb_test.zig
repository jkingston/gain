//! Production MSC wire protocol with deterministic endpoints and block I/O.
const std = @import("std");
const c = @import("c_usb");
const Endpoint = struct {
    buffer: [*c]u8 = null,
    length: u16 = 0,
    busy: bool = false,
    stalled: bool = false,
    snapshot: [4096]u8 = @splat(0),
};
var endpoints: [256]Endpoint = @splat(.{});
const bridge = @import("usb_msc.zig");
const storage = @import("usb_storage.zig");
const descriptors = @import("usb_descriptors.zig");

export fn tud_speed_get() c.tusb_speed_t {
    return c.TUSB_SPEED_HIGH;
}
export fn tud_control_status(_: u8, _: ?*const c.tusb_control_request_t) bool {
    return true;
}
export fn tud_control_xfer(_: u8, _: ?*const c.tusb_control_request_t, _: ?*anyopaque, _: u16) bool {
    return true;
}
export fn usbd_edpt_open(_: u8, _: ?*const c.tusb_desc_endpoint_t) bool {
    return true;
}
export fn usbd_open_edpt_pair(_: u8, descriptor: [*c]const u8, _: u8, _: u8, out: [*c]u8, in: [*c]u8) bool {
    for ([_]u8{ descriptor[2], descriptor[9] }) |ep| {
        if (ep & 0x80 == 0) out.* = ep else in.* = ep;
    }
    return true;
}
export fn usbd_edpt_claim(_: u8, ep: u8) bool {
    return !endpoints[ep].busy;
}
export fn usbd_edpt_busy(_: u8, ep: u8) bool {
    return endpoints[ep].busy;
}
export fn usbd_edpt_stalled(_: u8, ep: u8) bool {
    return endpoints[ep].stalled;
}
export fn usbd_edpt_rx_consume(_: u8, _: u8) void {}
export fn usbd_edpt_stall(_: u8, ep: u8) void {
    endpoints[ep].stalled = true;
    endpoints[ep].busy = false;
}
export fn usbd_edpt_abort(_: u8, ep: u8) void {
    endpoints[ep].busy = false;
}
export fn dcd_event_handler(_: ?*const c.dcd_event_t, _: bool) void {
    @panic("unexpected async completion in synchronous block-device test");
}
export fn usbd_defer_func_after_queue(func: c.osal_task_func_t, param: ?*anyopaque) bool {
    func.?(param);
    return true;
}
export fn usbd_defer_func(func: c.osal_task_func_t, param: ?*anyopaque, _: bool) void {
    func.?(param);
}
export fn usbd_edpt_xfer(_: u8, ep: u8, buffer: [*c]u8, length: u16, _: bool) bool {
    const endpoint = &endpoints[ep];
    std.debug.assert(!endpoint.busy and length <= endpoint.snapshot.len);
    endpoint.buffer = buffer;
    endpoint.length = length;
    endpoint.busy = true;
    if (ep & 0x80 != 0 and length != 0) @memcpy(endpoint.snapshot[0..length], buffer[0..length]);
    return true;
}

fn hostOut(eps: anytype, bytes: []const u8) !void {
    const ep = &eps[1];
    try std.testing.expect(ep.busy and bytes.len <= ep.length);
    @memcpy(ep.buffer[0..bytes.len], bytes);
    ep.busy = false;
    try std.testing.expect(c.mscd_xfer_cb(0, 1, c.XFER_RESULT_SUCCESS, @intCast(bytes.len)));
}
fn finish(eps: anytype) !void {
    const ep = &eps[0x81];
    try std.testing.expect(ep.busy);
    const bytes = ep.length;
    ep.busy = false;
    try std.testing.expect(c.mscd_xfer_cb(0, 0x81, c.XFER_RESULT_SUCCESS, bytes));
}
fn command(eps: anytype, opcode: u8, data_bytes: u32, in: bool, byte4: u8, lba: u32, blocks: u16) !void {
    var cbw: [31]u8 = @splat(0);
    std.mem.writeInt(u32, cbw[0..4], 0x43425355, .little);
    std.mem.writeInt(u32, cbw[4..8], 123, .little);
    std.mem.writeInt(u32, cbw[8..12], data_bytes, .little);
    cbw[12] = if (in) 0x80 else 0;
    cbw[14] = if (opcode == 0x28 or opcode == 0x2a) 10 else 6;
    cbw[15] = opcode;
    cbw[19] = byte4;
    if (opcode == 0x28 or opcode == 0x2a) {
        std.mem.writeInt(u32, cbw[17..21], lba, .big);
        std.mem.writeInt(u16, cbw[22..24], blocks, .big);
    }
    try hostOut(eps, &cbw);
}

fn setup(store: *storage.Store) !void {
    bridge.bind(store);
    bridge.mounted();
    try store.session.grantHost();
    endpoints = @splat(.{});
    c.mscd_init();
    c.mscd_reset(0);
    try std.testing.expectEqual(23, c.mscd_open(0, @ptrCast(&descriptors.high[9]), 23));
}
test "production MSC write read sync eject and reset obey wire status ordering" {
    var device: storage.TestDevice = .{};
    var bounce: [4096]u8 align(4) = undefined;
    var store = try storage.Store.init(device.device(), &bounce);
    try setup(&store);
    defer bridge.bind(null);
    var expected: [4096]u8 = undefined;
    for (&expected, 0..) |*byte, i| byte.* = @truncate(i *% 71);
    try command(&endpoints, 0x2a, 4096, false, 0, 2, 8);
    try hostOut(&endpoints, &expected);
    try std.testing.expectEqualSlices(u8, &expected, device.bytes[1024..5120]);
    try std.testing.expectEqual(13, endpoints[0x81].length);
    try std.testing.expectEqual(0, endpoints[0x81].snapshot[12]);
    try finish(&endpoints);
    try command(&endpoints, 0x28, 4096, true, 0, 2, 8);
    try std.testing.expectEqualSlices(u8, &expected, &endpoints[0x81].snapshot);
    try finish(&endpoints);
    try finish(&endpoints);
    try command(&endpoints, 0x35, 0, false, 0, 0, 0);
    try finish(&endpoints);
    try std.testing.expectEqual(1, device.syncs);
    // Ordinary STOP is not an ownership transfer.
    try command(&endpoints, 0x1b, 0, false, 0, 0, 0);
    try finish(&endpoints);
    try std.testing.expect(store.ready());
    try command(&endpoints, 0x1b, 0, false, 2, 0, 0);
    try std.testing.expectEqual(storage.State.ejecting, store.session.state);
    try std.testing.expect(!store.ready() and !store.session.playerAllowed());
    try finish(&endpoints);
    try std.testing.expectEqual(storage.State.remounting, store.session.state);
    try store.session.remounted();
    try command(&endpoints, 0, 0, true, 0, 0, 0);
    try std.testing.expectEqual(1, endpoints[0x81].snapshot[12]);
    try finish(&endpoints);
    for (0..32) |_| {
        bridge.reset();
        bridge.mounted();
    }
    try std.testing.expectEqual(storage.State.ejected, store.session.state);
    try std.testing.expectEqual(-1, c.tud_msc_write10_cb(0, 0, 0, &expected, 4096));
    try std.testing.expectEqual(-1, c.tud_msc_read10_cb(1, 0, 0, &expected, 512));
    try std.testing.expectEqualSlices(u8, &expected, device.bytes[1024..5120]);
}
test "failed flush returns failed CSW and never grants player access" {
    var device: storage.TestDevice = .{};
    var bounce: [4096]u8 align(4) = undefined;
    var store = try storage.Store.init(device.device(), &bounce);
    try setup(&store);
    defer bridge.bind(null);
    device.fail_sync = true;
    try command(&endpoints, 0x1b, 0, false, 2, 0, 0);
    try std.testing.expectEqual(1, endpoints[0x81].snapshot[12]);
    try finish(&endpoints);
    try std.testing.expectEqual(storage.State.host, store.session.state);
    try std.testing.expect(!store.session.playerAllowed());
}
test "malformed CBW stalls bulk endpoints and class reset recovers" {
    var device: storage.TestDevice = .{};
    var bounce: [4096]u8 align(4) = undefined;
    var store = try storage.Store.init(device.device(), &bounce);
    try setup(&store);
    defer bridge.bind(null);
    var invalid: [31]u8 = @splat(0);
    const ep = &endpoints[1];
    @memcpy(ep.buffer[0..31], &invalid);
    ep.busy = false;
    _ = c.mscd_xfer_cb(0, 1, c.XFER_RESULT_SUCCESS, 31);
    try std.testing.expect(endpoints[1].stalled and endpoints[0x81].stalled);
    try std.testing.expectEqual(0, device.operations);
    endpoints = @splat(.{});
    c.mscd_reset(0);
    try std.testing.expectEqual(23, c.mscd_open(0, @ptrCast(&descriptors.high[9]), 23));
    try command(&endpoints, 0, 0, true, 0, 0, 0);
    try finish(&endpoints);
}
