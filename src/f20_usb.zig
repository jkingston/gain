//! F20 USB device port. USB is polled by the UI/main owner; it never performs
//! SD I/O until the preemptive player has returned and released its workers.
const c = @import("c_usb");
const x = @import("x1000.zig");
const board = @import("f20_v27.zig");
const storage = @import("f20_storage.zig");
const mass = @import("usb_storage.zig");
const bridge = @import("usb_msc.zig");
const descriptors = @import("usb_descriptors.zig");
const dma = @import("x1000_dma.zig");

const shared_region = board.memory.usb_dma;
var mapping: dma.IdentityWindow = .{};
var core_clock_ready = false;
const usb_base = 0xb3500000;
var disk: mass.Store = undefined;
var enabled = false;
var service_enabled = false;
var was_connected = false;
var initialized = false;
var clock: @import("executive.zig").Clock = .{ .previous = 0 };
pub var failed = false;

pub fn initialize(controller: *storage.Controller) !void {
    board.usb_detect.input();
    x.Interrupts.mask(.usb);
    clock = .{ .previous = x.Timer.now() };
    try mapping.install(shared_region.start);
    errdefer mapping.restore();
    @memset(@as([*]u8, @ptrFromInt(shared_region.start))[0..shared_region.bytes], 0);
    disk = try mass.Store.init(.{
        .context = controller,
        .capacity = capacity,
        .present = present,
        .read = read,
        .write = write,
        .sync = sync,
        .shared = .{ .start = shared_region.start, .bytes = shared_region.bytes },
    }, board.memory.storage_burst.uncachedSlice(u8)[0..c.CFG_TUD_MSC_EP_BUFSIZE]);
    bridge.bind(&disk);
    initialized = true;
}

fn concrete(context: *anyopaque) *storage.Controller {
    return @ptrCast(@alignCast(context));
}

fn capacity(context: *anyopaque) u64 {
    return concrete(context).capacity_sectors;
}

fn present(context: *anyopaque) bool {
    return concrete(context).capacity_sectors != 0 and concrete(context).present();
}

fn read(context: *anyopaque, lba: u32, output: []u8) !void {
    const device = concrete(context);
    const previous = device.keep_alive;
    device.keep_alive = keepAlive;
    defer device.keep_alive = previous;
    const bytes = @as([*]u8, @ptrFromInt(sdAlias(@intFromPtr(output.ptr), output.len)))[0..output.len];
    try device.readBlocks(lba, bytes);
}

fn write(context: *anyopaque, lba: u32, input: []const u8) !void {
    const device = concrete(context);
    const previous = device.keep_alive;
    device.keep_alive = keepAlive;
    defer device.keep_alive = previous;
    const bytes = @as([*]const u8, @ptrFromInt(sdAlias(@intFromPtr(input.ptr), input.len)))[0..input.len];
    try device.writeBlocks(lba, bytes);
}

fn sdAlias(address: usize, length: usize) usize {
    const shared = mass.SharedMemory{ .start = shared_region.start, .bytes = shared_region.bytes };
    return if (shared.contains(address, length)) shared_region.uncached() + (address - shared_region.start) else address;
}

fn sync(context: *anyopaque) !void {
    const device = concrete(context);
    const previous = device.keep_alive;
    device.keep_alive = keepAlive;
    defer device.keep_alive = previous;
    try device.sync();
}

fn keepAlive() void {
    x.Watchdog.kick();
}

pub fn session() *mass.Session {
    return &disk.session;
}

pub fn dmaEnabled() bool {
    return core_clock_ready and x.read32(usb_base + 8) & x.bit(5) != 0; // GAHBCFG.DMAEn
}

pub fn counters() *const mass.Store {
    return &disk;
}

pub fn needsHandoff() bool {
    return initialized and disk.session.state == .quiescing;
}

pub fn needsRemount() bool {
    return initialized and disk.session.state == .remounting;
}

pub fn grantHost() !void {
    try disk.session.grantHost();
    disk.failed = false;
}

pub fn remounted() void {
    disk.session.remounted() catch return;
    disk.failed = false;
}

pub fn reconnect() void {
    disk.session.reconnect() catch return;
    _ = c.tud_disconnect();
    x.Timer.delayMicroseconds(250_000);
    _ = c.tud_connect();
}

pub fn poll() void {
    if (!initialized) return;
    _ = clock.sample(x.Timer.now());
    const connected = board.usb_detect.get();
    if (!connected) {
        if (enabled) {
            _ = c.tud_deinit(0);
            enabled = false;
        }
        if (was_connected) disk.session.unplug();
        was_connected = false;
        failed = false;
        return;
    }
    was_connected = true;
    if (!enabled and !failed) {
        prepareClock() catch {
            failed = true;
            return;
        };
        // Discard the ROM's old USB address before initializing our own core.
        x.write32(usb_base + 0x804, x.read32(usb_base + 0x804) | 2);
        x.Timer.delayMicroseconds(250_000);
        const init: c.tusb_rhport_init_t = .{ .role = c.TUSB_ROLE_DEVICE, .speed = c.TUSB_SPEED_HIGH };
        if (!c.tusb_rhport_init(0, &init)) {
            failed = true;
            return;
        }
        enabled = true;
    }
    if (enabled) {
        if (service_enabled) c.dcd_int_handler(0);
        _ = c.tud_task_ext(0, false);
    }
}

pub fn deinitialize() void {
    if (enabled) {
        _ = c.tud_deinit(0);
        enabled = false;
    }
    bridge.bind(null);
    initialized = false;
    if (!core_clock_ready) mapping.restore();
}

/// DMA mode is latched by the core: restoring the ROM's PIO register values
/// alone cannot switch it off. Stop/reset the core before restoring the TLB.
pub fn resetForRom() !void {
    if (!core_clock_ready) {
        initialized = false;
        bridge.bind(null);
        mapping.restore();
        return;
    }
    x.write32(usb_base + 0x804, x.read32(usb_base + 0x804) | 2);
    x.write32(usb_base + 8, 0);
    var driver = struct {
        pub fn now(_: *@This()) u32 {
            return x.Timer.now();
        }

        pub fn state(_: *@This()) u32 {
            return x.read32(usb_base + 0x10);
        }

        pub fn requestReset(_: *@This()) void {
            x.write32(usb_base + 0x10, 1);
        }

        pub fn settle(_: *@This()) void {
            x.Timer.delayMicroseconds(10);
        }
    }{};
    try @import("usb_core_reset.zig").reset(&driver, x.Timer.milliseconds(100));
    initialized = false;
    enabled = false;
    service_enabled = false;
    bridge.bind(null);
    mapping.restore();
    core_clock_ready = false;
}

const Controller = extern struct { base: usize, irq: u32, endpoints: u8, in_endpoints: u8, fifo_words: u16 };
export const _dwc2_controller: [1]Controller = .{.{ .base = usb_base, .irq = 21, .endpoints = 9, .in_endpoints = 8, .fifo_words = 3576 }};
const UsbClock = x.Register32(0xb0000050);
const UsbReset = x.Register32(0xb00000c4);
const PowerControl = x.Register32(0xb0000024);
const PhyControl = x.Register32(0xb000003c);
const PhyReference = x.Register32(0xb0000048);
const RiseDetect = x.Register32(0xb0000040);
const VbusFilter = x.Register32(0xb0000044);
const phy_suspend_release = x.bit(7);
const phy_clock_gate = x.bit(23);
const phy_power_reset = x.bit(22);

// Prepared before the first DWC2 register access, including when no ROM USB
// session has left the core clock enabled. TinyUSB invokes this hook again.
export fn dwc2_clock_init(_: u8, _: c.tusb_role_t) void {}

fn prepareClock() !void {
    x.Cpm.clock_gate.clear(x.bit(3)); // OTG
    UsbClock.write(x.bit(29)); // 24 MHz external crystal, divide by one
    const began = x.Timer.now();
    while (UsbClock.read() & x.bit(28) != 0) {
        if (x.Timer.elapsed(began) > x.Timer.milliseconds(100)) return error.ClockTimeout;
    }
    UsbClock.clear(x.bit(29));
    UsbReset.set(x.bit(12));
    x.Timer.delayMicroseconds(10);
    UsbReset.clear(x.bit(12));
    PowerControl.clear(phy_clock_gate);
    PowerControl.set(phy_suspend_release);
    x.Timer.delayMicroseconds(45);
    VbusFilter.write(0);
    RiseDetect.write(x.bit(25) | 0x96);
    // Device-only UTMI+, external VBUS valid, documented F20 PHY tuning.
    PhyControl.write(x.bit(25) | x.bit(24) | x.bit(23) | x.bit(20) | (7 << 11) | x.bit(6) | x.bit(4) | 7);
    PhyReference.write(x.bit(31) | (2 << 26) | (1 << 24) | x.bit(19));
    PhyControl.set(phy_power_reset);
    x.Timer.delayMicroseconds(1000);
    PhyControl.clear(phy_power_reset);
    x.Timer.delayMicroseconds(1000);
    core_clock_ready = true;
}

export fn dwc2_int_set(_: u8, _: c.tusb_role_t, value: bool) void {
    // INTC source 21 stays masked: the UI/main task is the sole TinyUSB owner.
    x.Interrupts.mask(.usb);
    service_enabled = value;
}

export fn dwc2_remote_wakeup_delay() void {
    x.Timer.delayMicroseconds(1000);
}

export fn dwc2_phy_init(_: ?*anyopaque, _: u8) void {}

export fn dwc2_phy_update(_: ?*anyopaque, _: u8) void {}

export fn dwc2_phy_deinit(_: ?*anyopaque, _: u8) void {
    PowerControl.clear(phy_suspend_release);
    PhyControl.set(x.bit(20) | x.bit(21));
    PowerControl.set(phy_clock_gate);
    core_clock_ready = false;
}

export fn tusb_time_millis_api() u32 {
    return @truncate(clock.sample(x.Timer.now()) / x.Timer.milliseconds(1));
}

export fn tud_descriptor_device_cb() [*c]const u8 {
    return &descriptors.device;
}

export fn tud_descriptor_configuration_cb(_: u8) [*c]const u8 {
    return if (c.tud_speed_get() == c.TUSB_SPEED_HIGH) &descriptors.high else &descriptors.full;
}

export fn tud_descriptor_other_speed_configuration_cb(_: u8) [*c]const u8 {
    return if (c.tud_speed_get() == c.TUSB_SPEED_HIGH) &descriptors.other_full else &descriptors.other_high;
}

export fn tud_descriptor_device_qualifier_cb() [*c]const u8 {
    return &descriptors.qualifier;
}
var string_buffer: [64]u16 = @splat(0);

export fn tud_descriptor_string_cb(index: u8, _: u16) [*c]const u16 {
    if (index == 0) {
        string_buffer[0] = 0x0304;
        string_buffer[1] = 0x0409;
        return &string_buffer;
    }
    const text = switch (index) {
        1 => "Gain",
        2 => "Gain SD card",
        3 => "GAIN-F20-V27",
        else => return null,
    };
    string_buffer[0] = 0x0300 + @as(u16, @intCast(2 + text.len * 2));
    for (text, 0..) |byte, i| string_buffer[i + 1] = byte;
    return &string_buffer;
}

export fn tud_mount_cb() void {
    bridge.mounted();
}

export fn tud_umount_cb() void {
    bridge.reset();
}
