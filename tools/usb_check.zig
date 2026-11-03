//! Bounded RAM-only qualification of the production USB/SD driver. The host
//! writes disposable files; this tool never formats or writes sectors itself.
const std = @import("std");
const gain = @import("gain");
const c = @import("c_usb");

const x = gain.soc;
const usb = gain.usb;
const report: *volatile Report = @ptrFromInt(0xa0700000);

const Report = extern struct {
    magic: u32 = 0x55534447,
    version: u32 = 4,
    stage: u32 = 0,
    failure: u32 = 0,
    epc: u32 = 0,
    state: u32 = 0,
    sectors: u32 = 0,
    read_bytes: u32 = 0,
    written_bytes: u32 = 0,
    remounts: u32 = 0,
    remount_error: u32 = 0,
    loops: u32 = 0,
    charge_control: u32 = 0,
    usb_power: u32 = 0,
    last_command: u32 = 0,
    last_flags: u32 = 0,
    file_bytes: u32 = 0,
    file_checksum: u32 = 0,
    file_error: u32 = 0,
    playback_polls: u32 = 0,
    played_frames: u32 = 0,
    playback_stopped: u32 = 0,
    bytes_before_grant: u32 = 0,
    dma_enabled: u32 = 0,
    direct_read_bytes: u32 = 0,
    direct_written_bytes: u32 = 0,
};

var response: Report = .{};
const usb_base: usize = 0xb3500000;
var saved: gain.usb_rom.Snapshot = undefined;
var saved_valid = false;
var pending: u8 = 0;
var ready: u8 = 0;
var in_player = false;
var player_started: u32 = 0;
var acknowledgement: u32 = 0x4741494e;

extern fn rom_return() callconv(.c) noreturn;

fn watchdog(seconds: u32) void {
    watchdogStop();
    const base = 0xb2000000;
    x.write32(base, (x.read32(base) & ~@as(u32, 3)) | 1);
    x.write32(base + 0x0c, ~@as(u32, 1));
    x.write32(base + 0x14, seconds * 6_000_000);
    x.write32(base + 8, 1);
    x.write32(base + 0x34, 1);
    x.write32(base + 0x10, ~@as(u32, 1));
    asm volatile ("mfc0 $8, $13; li $9, 0xff7fffff; and $8, $8, $9; mtc0 $8, $13; li $8, 0x20000801; mtc0 $8, $12; ehb" ::: .{
            .r8 = true,
            .r9 = true,
            .memory = true,
        });
}

fn watchdogStop() void {
    asm volatile ("di; ehb");
    x.write32(0xb2000038, 1);
    x.write32(0xb2000010, 1);
    x.write32(0xb200000c, ~@as(u32, 1));
}

fn returnRom() noreturn {
    watchdogStop();
    if (saved_valid) {
        x.write32(usb_base + 0x804, x.read32(usb_base + 0x804) | 2);
        x.write32(usb_base + 8, 0);
        usb.resetForRom() catch {
            // Never release DMA memory while the controller is still active.
            x.Watchdog.start(.external, .by_1024, 1024);
            while (true) asm volatile ("nop");
        };
        saved.restoreQuiesced();
        x.Timer.delayMicroseconds(250_000);
        saved.reconnect();
        asm volatile ("sync" ::: .{ .memory = true });
    }
    rom_return();
}

export fn gain_x1000_dispatch(frame: *gain.runtime.Context, entry: u32, cause: u32) callconv(.c) *gain.runtime.Context {
    if (in_player) {
        if (x.Timer.elapsed(player_started) > x.Timer.milliseconds(20_000)) exception_panic(0xdead, frame.epc, 0);
        return gain.runtime.dispatch(frame, entry, cause);
    }
    exception_panic(cause, frame.epc, 0);
}

export fn player_check_fault(cause: u32, epc: u32) callconv(.c) noreturn {
    exception_panic(cause, epc, 0);
}

export fn exception_panic(cause: u32, epc: u32, _: u32) callconv(.c) noreturn {
    report.failure = cause;
    report.epc = epc;
    report.stage = 0xff;
    returnRom();
}
pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(_: []const u8, address: ?usize) noreturn {
    exception_panic(0x50414e49, @truncate(address orelse 0), 0);
}

/// These read-only diagnostics exist only in this qualification executable.
/// Commands commit after ACK, and ROM return is refused while the host owns SD.
export fn tud_vendor_control_xfer_cb(rhport: u8, stage: u8, request: ?*const c.tusb_control_request_t) bool {
    const bytes: *const [8]u8 = @ptrCast(request.?);
    if (stage == c.CONTROL_STAGE_SETUP) {
        pending = 0;
        if (bytes[0] != 0xc0 or std.mem.readInt(u16, bytes[2..4], .little) != 0 or std.mem.readInt(u16, bytes[4..6], .little) != 0) return false;
        const length = std.mem.readInt(u16, bytes[6..8], .little);
        if (bytes[1] == 0x5a and length > 0) {
            response = report.*;
            return c.tud_control_xfer(rhport, request, &response, @sizeOf(Report));
        }
        if (length != 4 or (bytes[1] != 0x5b and bytes[1] != 0x5f) or !usb.session().playerAllowed()) return false;
        pending = bytes[1];
        return c.tud_control_xfer(rhport, request, &acknowledgement, 4);
    }
    if (stage == c.CONTROL_STAGE_ACK and pending == bytes[1]) {
        ready = pending;
        pending = 0;
    }
    return true;
}

export fn player_check_main() callconv(.c) void {
    report.* = .{};
    x.Timer.initialize();
    saved = gain.usb_rom.Snapshot.capture();
    saved_valid = true;
    watchdog(20);
    report.stage = 1;
    var card = gain.storage.Controller.initialize(.{
        .descriptor = @ptrFromInt(gain.memory.sd_control.uncached()),
        .switch_status = @ptrFromInt(gain.memory.sd_control.uncached() + 0x100),
    }) catch |err| {
        report.failure = @intFromError(err);
        returnRom();
    };
    report.sectors = @intCast(card.capacity_sectors);
    usb.initialize(&card) catch |err| {
        report.failure = @intFromError(err);
        returnRom();
    };

    var pmic = gain.power.initialize() catch |err| {
        report.failure = @intFromError(err);
        returnRom();
    };
    report.stage = 2;
    checkPlaybackHandoff(&card) catch |err| {
        report.failure = @intFromError(err);
        returnRom();
    };
    watchdog(20);
    var heartbeat = x.Timer.now();
    while (true) {
        usb.poll();
        report.stage = 3;
        report.loops +%= 1;
        if (usb.needsHandoff()) usb.grantHost() catch {};
        if (usb.needsRemount()) {
            const scratch: *[512]u8 = @ptrFromInt(gain.memory.filesystem_sector.uncached());
            card = gain.storage.Controller.initialize(card.resources) catch |err| {
                report.remount_error = @intFromError(err);
                returnRom();
            };

            var volume = Volume.mount(&card, scratch) catch |err| {
                report.remount_error = @intFromError(err);
                returnRom();
            };
            report.file_bytes = 0;
            report.file_checksum = 0;
            report.file_error = 0;
            verifyFile(&volume) catch |err| {
                report.file_error = @intFromError(err);
            };
            report.remounts += 1;
            usb.remounted();
        }
        report.state = @backingInt(usb.session().state);
        report.read_bytes = @truncate(usb.counters().reads);
        report.written_bytes = @truncate(usb.counters().writes);
        report.dma_enabled = @intFromBool(usb.dmaEnabled());
        report.direct_read_bytes = @truncate(usb.counters().direct_reads);
        report.direct_written_bytes = @truncate(usb.counters().direct_writes);
        report.last_command = card.last_command;
        report.last_flags = card.last_flags;
        const action = ready;
        ready = 0;
        if (action != 0) {
            x.Timer.delayMicroseconds(10_000);
            if (action == 0x5f) returnRom();
            usb.reconnect();
        }
        if (x.Timer.elapsed(heartbeat) > x.Timer.milliseconds(1000)) {
            heartbeat = x.Timer.now();
            watchdog(20);
            report.charge_control = pmic.read(.charge_control) catch 0xffffffff;
            report.usb_power = if (pmic.telemetry()) |value| @intFromBool(value.status.usb_present) else |_| 0;
        }
    }
}

fn verifyFile(volume: *gain.storage.fat32.Volume(gain.storage.Controller)) !void {
    var root = try volume.iterate(volume.rootDirectory());
    while (try root.next()) |folder| {
        if (!std.mem.eql(u8, folder.name(), ".gain-usb-check")) continue;
        var directory = try volume.iterate(try folder.directory());
        while (try directory.next()) |file| {
            if (!std.mem.eql(u8, file.name(), "TRANSFER.BIN")) continue;
            if (file.size > 64 * 1024 * 1024) return error.UnexpectedFileSize;
            var reader = try volume.reader(try file.file());
            const bytes = gain.memory.storage_burst.uncachedSlice(u8)[0..32768];
            const cached = gain.memory.decoder_cache.cachedSlice(u8)[0..bytes.len];
            var observer = struct {
                began: u32,
                heartbeat: u32,

                pub fn poll(self: *@This(), progress: u32) !void {
                    if (x.Timer.elapsed(self.began) > x.Timer.milliseconds(120_000)) return error.VerifyTimeout;
                    if (x.Timer.elapsed(self.heartbeat) >= x.Timer.milliseconds(1000)) {
                        watchdog(20);
                        self.heartbeat = x.Timer.now();
                    }
                    report.stage = 4;
                    report.state = @backingInt(usb.session().state);
                    report.file_bytes = progress;
                    // Host access remains refused while the native mount owns SD.
                    usb.poll();
                }
            }{ .began = x.Timer.now(), .heartbeat = x.Timer.now() };
            const result = try @import("usb_verify.zig").verify(&reader, bytes, cached, file.size, &observer);
            report.file_bytes = result.bytes;
            report.file_checksum = result.checksum;
            return;
        }
    }
}

const Volume = gain.storage.fat32.Volume(gain.storage.Controller);

fn firstTrack(volume: *Volume, directory: gain.storage.fat32.Directory, depth: usize) anyerror!?gain.storage.fat32.DirectoryEntry {
    if (depth == 7) return null;
    var iterator = try volume.iterate(directory);
    while (try iterator.next()) |entry| {
        if (!gain.file_browser.isVisibleEntry(&entry)) continue;
        if (entry.kind == .file) {
            if (entry.size >= 2 * 1024 * 1024) return entry;
        } else if (try firstTrack(volume, try entry.directory(), depth + 1)) |found| return found;
    }
    return null;
}

fn playbackPoll(_: *anyopaque, status: gain.media.PlaybackStatus) gain.media.PlaybackCommand {
    report.playback_polls += 1;
    report.played_frames = @truncate(status.played_frames);
    // First establish real SD-fed playback, then enumerate a USB host while
    // storage/codec/output tasks are live. No host I/O is granted in this task.
    if (status.phase == .playing and status.played_frames >= status.sample_rate / 4) usb.poll();
    return if (usb.needsHandoff()) .stop else .none;
}

fn checkPlaybackHandoff(card: *gain.storage.Controller) !void {
    watchdogStop();
    var volume = try Volume.mount(card, @ptrFromInt(gain.memory.filesystem_sector.uncached()));
    const entry = try firstTrack(&volume, volume.rootDirectory(), 0) orelse return error.NoQualificationTrack;
    var reader = try volume.reader(try entry.file());
    var context: u32 = 0;
    player_started = x.Timer.now();
    in_player = true;
    const result = gain.player.playFile(&reader, entry.size, card, .{
        .attenuation = 128,
        .measure_stacks = true,
    }, .{ .context = &context, .poll = playbackPoll }) catch |err| {
        in_player = false;
        return err;
    };
    in_player = false;
    if (!usb.needsHandoff() or result.playback.exit != .stopped) return error.HandoffDidNotStopPlayback;
    if (card.waiter != null) return error.StorageWorkerStillAttached;
    report.bytes_before_grant = @intCast(usb.counters().reads + usb.counters().writes);
    if (report.bytes_before_grant != 0) return error.HostAccessBeforePlayerJoined;
    report.playback_stopped = 1;
}
