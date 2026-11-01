//! Zig bridge to the pinned upstream USB class. No filesystem or board code.
const c = @import("c_usb");
const storage = @import("usb_storage.zig");
var active: ?*storage.Store = null;
pub fn bind(store: ?*storage.Store) void {
    active = store;
}
pub fn mounted() void {
    if (active) |store| store.session.connectedToHost();
}
pub fn reset() void {
    if (active) |store| store.session.busReset();
}
fn medium(lun: u8) ?*storage.Store {
    return if (lun == 0) active else null;
}
export fn tud_msc_inquiry_cb(_: u8, vendor: [*c]u8, product: [*c]u8, revision: [*c]u8) void {
    @memcpy(vendor[0..8], "GAIN    ");
    @memcpy(product[0..16], "SD CARD         ");
    @memcpy(revision[0..4], "0001");
}
export fn tud_msc_test_unit_ready_cb(lun: u8) bool {
    if (medium(lun)) |store| if (store.ready()) return true;
    _ = c.tud_msc_set_sense(lun, c.SCSI_SENSE_NOT_READY, 0x3a, 0);
    return false;
}
export fn tud_msc_capacity_cb(lun: u8, count: [*c]u32, size: [*c]u16) void {
    count.* = if (medium(lun)) |store| if (store.ready()) store.capacity() else 0 else 0;
    size.* = storage.sector_bytes;
}
export fn tud_msc_is_writable_cb(lun: u8) bool {
    return if (medium(lun)) |store| store.ready() else false;
}
export fn tud_msc_read10_cb(lun: u8, lba: u32, offset: u32, buffer: ?*anyopaque, bytes: u32) i32 {
    const store = medium(lun) orelse return -1;
    const source = buffer orelse return -1;
    store.read(lba, offset, @as([*]u8, @ptrCast(source))[0..bytes]) catch return -1;
    return @intCast(bytes);
}
export fn tud_msc_write10_cb(lun: u8, lba: u32, offset: u32, buffer: [*c]u8, bytes: u32) i32 {
    const store = medium(lun) orelse return -1;
    if (buffer == null) return -1;
    store.write(lba, offset, buffer[0..bytes]) catch return -1;
    return @intCast(bytes);
}
export fn tud_msc_prevent_allow_medium_removal_cb(lun: u8, prevent: u8, _: u8) bool {
    const store = medium(lun) orelse return false;
    store.session.prevent_removal = prevent & 1 != 0;
    return true;
}
export fn tud_msc_start_stop_cb(lun: u8, power: u8, start: bool, eject: bool) bool {
    const store = medium(lun) orelse return false;
    if (power != 0 or !eject) return true;
    if (start) return store.ready();
    store.eject() catch return false;
    return true;
}
export fn tud_msc_scsi_complete_cb(lun: u8, command: [*c]const u8) void {
    if (command[0] == 0x1b) if (medium(lun)) |store| store.session.ejectAcknowledged();
}
export fn tud_msc_scsi_cb(lun: u8, command: [*c]const u8, _: ?*anyopaque, _: u16) i32 {
    if (command[0] == 0x35) {
        const store = medium(lun) orelse return -1;
        store.sync() catch return -1;
        return 0;
    }
    _ = c.tud_msc_set_sense(lun, c.SCSI_SENSE_ILLEGAL_REQUEST, 0x20, 0);
    return -1;
}
