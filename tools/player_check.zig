//! Bounded hardware qualification of the production player and controllers.
//! Input is either a caller-uploaded RAM fixture or a read-only real SD file.
const std = @import("std");
const gain = @import("gain");

const x = gain.soc;
const protocol = @import("player_check_report.zig");

const report: *volatile protocol.Report = @ptrFromInt(protocol.address);
const error_text: [*]u8 = @ptrFromInt(protocol.address + 0x100);
const fixture_address = 0x81800000;
const parameters: *volatile [8]u32 = @ptrFromInt(protocol.address);
const end_seek_mode = 4;

extern fn rom_return() callconv(.c) noreturn;
var deadline: u64 = 0;
var clock: @import("gain").executive.Clock = .{ .previous = 0 };
var inject_read_failure = false;

export fn gain_x1000_dispatch(frame: *gain.runtime.Context, entry: u32, cause: u32) callconv(.c) *gain.runtime.Context {
    if (clock.sample(entry) > deadline) {
        report.elapsed_ticks = @truncate(clock.ticks);
        exception_panic(0xdead, frame.epc, 0);
    }
    return gain.runtime.dispatch(frame, entry, cause);
}

export fn player_check_fault(cause: u32, epc: u32) callconv(.c) noreturn {
    exception_panic(cause, epc, 0);
}

export fn exception_panic(cause: u32, epc: u32, _: u32) callconv(.c) noreturn {
    asm volatile ("di;ehb");
    x.write32(0xb2000038, 1);
    x.write32(0xb2000010, 1);
    x.write32(0xb200000c, ~@as(u32, 1));
    x.Interrupts.maskAll();
    gain.hardware.audio.output_mute.set(true);
    report.cause = cause;
    report.epc = epc;
    report.complete = 1;
    rom_return();
}

fn failed(failure: anyerror) void {
    const name = @errorName(failure);
    @memcpy(error_text[0..name.len], name);
    report.error_length = @intCast(name.len);
    report.error_code = @intFromError(failure);
    report.complete = 1;
}

const RamReader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn seekTo(self: *RamReader, offset: u32) !void {
        if (offset > self.bytes.len) return error.SeekBounds;
        self.position = offset;
    }

    pub fn read(self: *RamReader, output: []u8) !usize {
        const count = @min(output.len, self.bytes.len - self.position);
        @memcpy(output[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};

const Ui = struct {
    screen: gain.player_screen.State = .init(80),
    polls: u32 = 0,
    mode: u32,
    duration: u32,

    fn poll(context: *anyopaque, status: gain.media.PlaybackStatus) gain.media.PlaybackCommand {
        const self: *Ui = @ptrCast(@alignCast(context));
        self.polls += 1;
        var buttons: u8 = 0;
        const Button = gain.playback_controls.Button;
        if (status.phase == .playing) {
            if (self.polls % 6 == 0) {
                buttons = if (self.polls % 24 < 12) Button.volume_up.mask() else Button.volume_down.mask();
                report.volume_changes += 1;
            }
            if (self.mode >= 1 and self.mode <= 3 and status.played_frames >= status.sample_rate / 5) buttons = switch (self.mode) {
                1 => Button.back.mask(),
                2 => Button.next.mask(),
                else => Button.previous.mask(),
            };
            if ((self.mode == 6 or self.mode == 7) and status.played_frames >= @as(u64, status.sample_rate) * self.duration) buttons = Button.back.mask();
            if (self.mode == 7 and status.played_frames >= status.sample_rate / 4) inject_read_failure = true;
        }
        return self.screen.poll(gain.display, buttons, .{ .name = "PLAYER QUALIFICATION" }, 0, gain.ui.dark_theme, status);
    }
};

const Volume = gain.storage.filesystem.Volume(gain.storage.Controller);

const CardReader = struct {
    reader: Volume.Reader,

    pub fn seekTo(self: *CardReader, offset: u32) !void {
        try self.reader.seekTo(offset);
    }

    pub fn read(self: *CardReader, output: []u8) !usize {
        if (inject_read_failure) return error.CardRemoved;
        return self.reader.read(output);
    }
};

fn firstTrack(volume: *Volume, browser: *gain.file_browser.Browser(Volume), depth: usize) anyerror!?gain.storage.fat32.DirectoryEntry {
    if (depth == 7) return null;
    var scene = gain.ui.Ui.init(.{ .pixels = gain.display.framebuffer });
    try browser.draw(volume, &scene, 0, 80, gain.ui.dark_theme);
    scene.finish();
    if (!gain.display.transfer(0, 0, 320, 240)) return error.DisplayFailure;
    const count = browser.counts[browser.depth];
    for (0..count) |_| {
        const entry = (try browser.selectedEntry(volume)) orelse return null;
        if (entry.kind == .file) {
            if (entry.size >= 32 * 1024 * 1024) return entry;
            browser.move(1);
            continue;
        }
        try browser.enter(volume, entry);
        if (try firstTrack(volume, browser, depth + 1)) |found| return found;
        browser.back();
        browser.move(1);
    }
    return null;
}

fn play(reader: anytype, length: u32, card: ?*gain.storage.Controller, mode: u32, duration: u32) !void {
    var ui = Ui{ .mode = mode, .duration = duration };
    defer _ = gain.display.resetForDirect();
    var last_reference: ?gain.pcm_reservoir.StereoFrame = null;
    if (mode == end_seek_mode) {
        // This mode targets headerless/free-format MPEG duration recovery. Its
        // integer decoder is deterministic, so compare the actual final PCM,
        // not only a successful return or a one-frame counter.
        var magic: [3]u8 = undefined;
        try reader.seekTo(0);
        if (try reader.read(&magic) != magic.len or !(std.mem.eql(u8, &magic, "ID3") or (magic[0] == 0xff and magic[1] & 0xe0 == 0xe0))) return error.UnsupportedFixture;
        try reader.seekTo(0);
        const reference = try gain.player.playFile(reader, length, card, .{ .attenuation = 80 }, .{ .context = &ui, .poll = Ui.poll });
        const capture = gain.memory.pcm_reservoir.cachedSlice(gain.pcm_reservoir.StereoFrame);
        if (reference.playback.exit != .completed or reference.playback.frames == 0 or reference.playback.frames > capture.len) return error.CaptureCapacity;
        last_reference = capture[@intCast(reference.playback.frames - 1)];
        _ = gain.display.resetForDirect();
        try reader.seekTo(0);
    }
    const result = try gain.player.playFile(reader, length, card, .{
        .attenuation = 80,
        .start_frame = if (mode == end_seek_mode) std.math.maxInt(u32) else 0,
        .measure_stacks = true,
    }, .{ .context = &ui, .poll = Ui.poll });
    if (ui.screen.failed) return error.DisplayFailure;
    if (mode == end_seek_mode) {
        if (!result.seek_clamped or result.playback.exit != .completed or result.playback.frames != 1) return error.SeekRecovery;
        const last = gain.memory.pcm_reservoir.cachedSlice(gain.pcm_reservoir.StereoFrame)[0];
        if (!std.meta.eql(last_reference.?, last)) return error.SeekSampleMismatch;
        report.pcm_checksum = @import("player_pcm_checksum.zig").update(report.pcm_checksum, &[_]gain.pcm_reservoir.StereoFrame{last});
    }
    if (mode == 0 and result.playback.exit == .completed) {
        const capture = gain.memory.pcm_reservoir.cachedSlice(gain.pcm_reservoir.StereoFrame);
        if (result.playback.frames > capture.len) return error.CaptureCapacity;
        report.pcm_checksum = @import("player_pcm_checksum.zig").update(report.pcm_checksum, capture[0..@intCast(result.playback.frames)]);
    }
    report.sample_rate = result.playback.sample_rate;
    report.frames_low = @truncate(result.playback.frames);
    report.frames_high = @truncate(result.playback.frames >> 32);
    report.periods += result.periods;
    report.underruns += result.playback.underruns;
    report.heap_peak = @max(report.heap_peak, result.heap_peak);
    report.storage_steps += result.storage_steps;
    report.ui_polls += result.ui_polls;
    report.maximum_fill_ticks = @max(report.maximum_fill_ticks, result.worst_fill_ticks);
    report.startup_ticks = @max(report.startup_ticks, result.startup_ticks);
    report.maximum_ui_ticks = @max(report.maximum_ui_ticks, result.maximum_ui_ticks);
    report.maximum_ui_gap_ticks = @max(report.maximum_ui_gap_ticks, result.maximum_ui_gap_ticks);
    report.maximum_irq_ticks = @max(report.maximum_irq_ticks, result.runtime.maximum_handler_ticks);
    for (result.stack_used, 0..) |used, index| report.stack_used[index] = @max(report.stack_used[index], used);
    report.exit = @backingInt(result.playback.exit);
    report.minimum_fifo = if (report.iterations == 0) result.playback.minimum_fifo_level else @min(report.minimum_fifo, result.playback.minimum_fifo_level);
    report.iterations += 1;
}

export fn player_check_main() callconv(.c) void {
    run() catch |failure| failed(failure);
    report.complete = 1;
}

fn run() !void {
    const length = parameters[0];
    const mode = parameters[1];
    const repeats = parameters[2];
    const duration = parameters[3];
    if (length > 7 * 1024 * 1024 or mode > 8 or repeats == 0 or repeats > 1000 or duration > 600 or @as(u64, duration) * repeats > 600) return error.InvalidParameters;
    report.* = .{ .mode = mode };
    x.Timer.initialize();
    deadline = @as(u64, protocol.timer_hz) * (@as(u64, @max(duration, 2)) * repeats + 10);
    try gain.display.initialize();
    defer _ = gain.display.resetForDirect();
    // The OST reset must settle before sampling its new counter baseline.
    const started = x.Timer.now();
    clock = .{ .previous = started };
    if (mode == 8) {
        const bytes = @as([*]const u8, @ptrFromInt(fixture_address))[0..length];
        if (bytes.len < 4) return error.InvalidParameters;
        const count = std.mem.readInt(u32, bytes[0..4], .little);
        if (count == 0 or count > 64 or bytes.len < 4 + count * 16) return error.InvalidParameters;
        for (0..repeats) |_| for (0..count) |index| {
            const record = bytes[4 + index * 16 ..][0..16];
            const offset = std.mem.readInt(u32, record[0..4], .little);
            const size = std.mem.readInt(u32, record[4..8], .little);
            const rate = std.mem.readInt(u32, record[8..12], .little);
            const frames = std.mem.readInt(u32, record[12..16], .little);
            if (offset < 4 + count * 16 or offset > bytes.len or size > bytes.len - offset) return error.InvalidParameters;
            var reader = RamReader{ .bytes = bytes[offset..][0..size] };
            try play(&reader, size, null, 0, 0);
            if (report.sample_rate != rate or report.frames_low != frames or report.frames_high != 0) return error.PresentationLength;
        };
    } else if (mode == 6 or mode == 7) {
        var card = try gain.storage.Controller.initialize(.{
            .descriptor = @ptrFromInt(gain.memory.sd_control.uncached()),
            .switch_status = @ptrFromInt(gain.memory.sd_control.uncached() + 0x100),
        });
        var volume = try Volume.mount(&card, @ptrFromInt(gain.memory.filesystem_sector.uncached()));
        var browser = try gain.file_browser.Browser(Volume).init(&volume);
        const entry = try firstTrack(&volume, &browser, 0) orelse return error.NoAudioFiles;
        for (0..repeats) |_| {
            var reader = CardReader{ .reader = try volume.reader(try entry.file()) };
            try play(&reader, entry.size, &card, mode, duration);
        }
    } else {
        for (0..repeats) |_| {
            var reader = RamReader{ .bytes = @as([*]const u8, @ptrFromInt(fixture_address))[0..if (mode == 5) length / 2 else length] };
            try play(&reader, length, null, mode, duration);
        }
    }
    report.elapsed_ticks = x.Timer.elapsed(started);
}
