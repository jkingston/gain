const std = @import("std");
const options = @import("firmware_options");
pub const gain_options = .{ .display_trace = options.maintenance };
const diag = @import("f20_diagnostics.zig");
const maintenance = @import("maintenance.zig");
const x1000 = @import("x1000.zig");
const board = @import("f20_v27.zig");
const storage = @import("f20_storage.zig");
const usb = @import("f20_usb.zig");
const media = @import("f20_media.zig");
const player = @import("f20_player.zig");
const fat32 = @import("filesystem.zig");
const ui = @import("ui.zig");
const LcdDma = @import("f20_display.zig");

const memory = board.memory;
const Timer = x1000.Timer;
const Watchdog = x1000.Watchdog;
var retained_themes: @import("runtime_theme.zig").Store = .{};
var usb_palette: @import("music_chrome.zig").Palette = @import("music_chrome.zig").light;
var appearance: @import("music_chrome.zig").Appearance = .light;
var text_loader: ?*@import("f20_text.zig").Loader = null;

const Display = struct {
    const width = board.display.width;
    const height = board.display.height;
    const surface = ui.Surface{ .pixels = LcdDma.framebuffer };
    const black: u16 = 0x0000;
    const white: u16 = 0xffff;
    const red: u16 = 0xf800;
    const cyan: u16 = 0x07ff;
    const yellow: u16 = 0xffe0;

    fn init() bool {
        LcdDma.initialize() catch return false;
        return true;
    }

    fn clear(color: u16) void {
        surface.clear(color);
    }

    fn rectangle(x: usize, y: usize, w: usize, h: usize, color: u16) void {
        surface.fill(.{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(w), .height = @intCast(h) }, color);
    }

    fn text(x: usize, y: usize, value: []const u8, color: u16, scale: usize) void {
        surface.text(.{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = @intCast(width -| x),
            .height = @intCast(height -| y),
        }, value, .{ .color = color, .scale = @intCast(scale) });
    }

    fn present() bool {
        return LcdDma.transfer(0, 0, width, height);
    }
    const presentRegionCpu = LcdDma.presentRegionCpu;
};

var display_ready = false;

fn panicCode(comptime value: *const [4]u8) u32 {
    return @as(u32, value[0]) << 24 |
        @as(u32, value[1]) << 16 |
        @as(u32, value[2]) << 8 |
        value[3];
}

fn wheelState() u2 {
    return @truncate((@as(u2, @intFromBool(board.wheel.phase_b.get())) << 1) |
        @intFromBool(board.wheel.phase_a.get()));
}

fn hexDigit(value: u4) u8 {
    return if (value < 10) '0' + @as(u8, value) else 'A' + @as(u8, value) - 10;
}

fn hex32(value: u32, output: *[8]u8) void {
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        const shift: u5 = @intCast((7 - index) * 4);
        output[index] = hexDigit(@truncate(value >> shift));
    }
}

fn decimal4(value_initial: u32, output: *[4]u8) void {
    var value = value_initial;
    var index: usize = 4;
    while (index != 0) {
        index -= 1;
        output[index] = '0' + @as(u8, @truncate(value % 10));
        value /= 10;
    }
}

fn rawPanicBlink() noreturn {
    board.display.backlight.output(false);
    while (true) {
        board.display.backlight.set(true);
        Timer.delayMicroseconds(150_000);
        board.display.backlight.set(false);
        Timer.delayMicroseconds(150_000);
    }
}

fn showPanic(cause: u32, epc: u32, status: u32) noreturn {
    const capsule: *volatile [4]u32 = @ptrFromInt(memory.fault_capsule.uncached());
    capsule.* = .{ 0x47464155, cause, epc, status };
    if (options.maintenance) maintenance.returnRom();
    if (!display_ready) rawPanicBlink();
    var cause_text: [8]u8 = undefined;
    var epc_text: [8]u8 = undefined;
    var status_text: [8]u8 = undefined;
    hex32(cause, &cause_text);
    hex32(epc, &epc_text);
    hex32(status, &status_text);

    Display.clear(Display.black);
    Display.rectangle(0, 0, Display.width, 34, Display.red);
    Display.text(12, 8, "GAIN PANIC", Display.white, 2);
    Display.text(16, 58, "CAUSE", Display.white, 2);
    Display.text(130, 58, &cause_text, Display.yellow, 2);
    Display.text(16, 94, "EPC", Display.white, 2);
    Display.text(130, 94, &epc_text, Display.yellow, 2);
    Display.text(16, 130, "STATUS", Display.white, 2);
    Display.text(130, 130, &status_text, Display.yellow, 2);
    Display.text(16, 188, "WATCHDOG RESET", Display.cyan, 1);
    if (!LcdDma.resetForDirect()) rawPanicBlink();
    if (!Display.presentRegionCpu(0, 0, Display.width, Display.height)) rawPanicBlink();
    while (true) asm volatile ("nop");
}

export fn gain_x1000_dispatch(frame: *@import("task_context.zig").Context, entry: u32, cause: u32) callconv(.c) *@import("task_context.zig").Context {
    return @import("x1000_runtime.zig").dispatch(frame, entry, cause);
}

export fn exception_panic(cause: u32, epc: u32, status: u32) callconv(.c) noreturn {
    showPanic(cause, epc, status);
}

const Volume = fat32.Volume(storage.Controller);
const sd_descriptor: *volatile storage.DmaDescriptor = @ptrFromInt(memory.sd_control.uncached());
const sd_switch_status: *align(4) [64]u8 = @ptrFromInt(memory.sd_control.uncached() + 0x100);
const sd_scratch: *[fat32.sector_bytes]u8 = @ptrFromInt(memory.filesystem_sector.uncached());

const UiEvent = @import("music_ui.zig").Input;

const Input = struct {
    music: @import("music_input.zig").Stream,
    generation: u32 = 1,
    injected: ?u16 = null,
    raw_buttons: u8 = 0,
    stable_buttons: u8 = 0,
    stable_samples: u3 = 0,
    old_wheel: u2,
    wheel_accumulator: i8 = 0,

    fn init() Input {
        for (board.buttons) |button| button.pin.input();
        board.wheel.phase_a.input();
        board.wheel.phase_b.input();
        const wheel = wheelState();
        return .{ .old_wheel = wheel, .music = .init(.{ .at = Timer.now(), .buttons = buttonState(), .wheel = wheel }, Timer.milliseconds(6)) };
    }

    fn poll(self: *Input) ?UiEvent {
        const sample = buttonState();
        var pressed: u8 = 0;
        if (sample == self.raw_buttons) {
            if (self.stable_samples < 7) self.stable_samples += 1;
        } else {
            self.raw_buttons = sample;
            self.stable_samples = 0;
        }
        if (self.stable_samples == 3 and self.stable_buttons != self.raw_buttons) {
            pressed = self.raw_buttons & ~self.stable_buttons;
            self.stable_buttons = self.raw_buttons;
        }

        if (pressed != 0) {
            if (pressed & board.ButtonId.play.mask() != 0) return .select;
            if (pressed & board.ButtonId.back.mask() != 0) return .back;
            if (pressed & board.ButtonId.menu.mask() != 0) return .home;
            if (pressed & board.ButtonId.previous.mask() != 0) return .up;
            if (pressed & board.ButtonId.next.mask() != 0) return .down;
            if (pressed & board.ButtonId.volume_up.mask() != 0) return .volume_up;
            if (pressed & board.ButtonId.volume_down.mask() != 0) return .volume_down;
        }

        const current_wheel = wheelState();
        if (current_wheel != self.old_wheel) {
            const transitions = [_]i8{ 0, -1, 1, 0, 1, 0, 0, -1, -1, 0, 0, 1, 0, 1, -1, 0 };
            self.wheel_accumulator += transitions[(@as(usize, self.old_wheel) << 2) | current_wheel];
            self.old_wheel = current_wheel;
            if (self.wheel_accumulator >= 4) {
                self.wheel_accumulator = 0;
                return .down;
            }
            if (self.wheel_accumulator <= -4) {
                self.wheel_accumulator = 0;
                return .up;
            }
        }
        return null;
    }

    fn resync(self: *Input) void {
        const buttons = buttonState();
        self.raw_buttons = buttons;
        self.stable_buttons = buttons;
        self.stable_samples = 0;
        self.old_wheel = wheelState();
        self.wheel_accumulator = 0;
        self.music.reset(.{ .at = Timer.now(), .buttons = buttons, .wheel = self.old_wheel });
        self.generation +%= 1;
    }
};

fn buttonState() u8 {
    var sample: u8 = 0;
    for (board.buttons) |button| {
        if (!button.pin.get()) sample |= button.id.mask();
    }
    return sample;
}

fn clippedName(name: []const u8, maximum: usize) []const u8 {
    return name[0..@min(name.len, maximum)];
}

fn showError(title: []const u8, failure: anyerror) bool {
    var code: [8]u8 = undefined;
    hex32(@intFromError(failure), &code);
    Display.clear(Display.black);
    Display.rectangle(0, 0, Display.width, 32, Display.red);
    Display.text(10, 8, "GAIN", Display.white, 2);
    Display.text(10, 68, clippedName(title, 24), Display.white, 2);
    Display.text(10, 112, "ERROR", Display.red, 2);
    Display.text(92, 112, &code, Display.yellow, 2);
    Display.text(10, 148, clippedName(@errorName(failure), 48), Display.cyan, 1);
    Display.text(10, 212, "BACK TO RETURN", 0x8410, 1);
    return Display.present();
}

fn showShutdown() bool {
    Display.clear(Display.black);
    Display.text(38, 92, "POWERING OFF", Display.white, 3);
    return Display.present();
}

fn powerOff(pmic: *@import("f20_power.zig").Controller) noreturn {
    Watchdog.kick();
    _ = showShutdown();
    pmic.shutdown() catch showPanic(panicCode("PMIC"), 0, 0);
    while (true) Watchdog.kick();
}

fn fatalError(title: []const u8, failure: anyerror) noreturn {
    _ = showError(title, failure);
    while (true) Watchdog.kick();
}

fn waitForErrorDismiss(input: *Input) void {
    while (true) {
        Watchdog.kick();
        usb.poll();
        if (usb.needsHandoff()) return;
        if (options.maintenance and maintenance.pending()) return;
        if (input.poll()) |event| {
            if (event == .back or event == .select or event == .home) return;
        }
        Timer.delayMicroseconds(1_000);
    }
}

export fn gain_main() callconv(.c) noreturn {
    if (options.maintenance) maintenance.saveRom();
    // SPL (or the warm RAM monitor) already runs OST2. Resetting it here
    // races the first measurement against the hardware counter clear.
    diag.initialize(options.build_id, options.maintenance);
    if (!Display.init()) rawPanicBlink();
    display_ready = true;
    Watchdog.start(.external, .by_1024, board.watchdog_timeout_ticks);
    Watchdog.kick();

    var input = Input.init();
    var pmic = @import("f20_power.zig").initialize() catch |failure| fatalError("POWER", failure);
    // A failed/disabled ADC is unknown, never a fabricated empty battery.
    pmic.enableTelemetry() catch |failure| diag.failed(4, failure);
    pmic.enableCoulombCounting() catch |failure| diag.failed(4, failure);
    diag.samplePower(&pmic);
    const battery_mv = diag.report.battery_mv;

    Display.clear(Display.black);
    Display.text(102, 92, "GAIN", Display.white, 3);
    Display.text(112, 132, "LOADING", Display.cyan, 1);
    if (!Display.present()) rawPanicBlink();

    const resources = storage.Controller.Resources{
        .descriptor = sd_descriptor,
        .switch_status = sd_switch_status,
    };

    var card = storage.Controller{ .resources = resources };
    usb.initialize(&card) catch |failure| fatalError("USB", failure);
    var attenuation: u8 = 64;
    while (true) {
        if (options.maintenance) if (maintenance.peek()) |command| {
            if (command.action == .rom) maintenance.returnRom();
        };
        // Recreate the controller, FAT cache and browser after every ownership
        // change. Host edits may have replaced directories and cluster chains.
        card = storage.Controller.initialize(resources) catch |failure| {
            card.capacity_sectors = 0;
            if (usb.needsRemount()) usb.remounted();
            _ = showError("SD CARD", failure);
            waitForErrorDismiss(&input);
            if (usb.needsHandoff()) runUsbMode(&pmic);
            continue;
        };
        card.keep_alive = keepAlive;
        if (usb.needsRemount()) usb.remounted();
        var volume = Volume.mount(&card, sd_scratch) catch |failure| {
            _ = showError("FILESYSTEM", failure);
            waitForErrorDismiss(&input);
            if (usb.needsHandoff()) runUsbMode(&pmic);
            continue;
        };
        diag.attach(&volume);
        _ = diag.load(&volume) catch |failure| failed_load: {
            diag.failed(2, failure);
            break :failed_load false;
        };

        browseMusic(&volume, battery_mv, &attenuation, &input, &pmic) catch |failure| {
            _ = showError("DIRECTORY", failure);
            waitForErrorDismiss(&input);
        };
        // Playback has joined every task before the UI session returns. No decoder,
        // SD prefetch, FAT reader or audio callback can now touch the card.
        diag.flush();
        diag.detached();
        if (usb.needsHandoff()) runUsbMode(&pmic);
        input.resync();
    }
}

fn runUsbMode(pmic: *@import("f20_power.zig").Controller) void {
    LcdDma.setAwake(true);
    diag.flush();
    diag.event(.usb, .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    const view = @import("usb_view.zig");
    var previous_phase: ?view.Phase = null;
    var previous_power: @import("battery.zig").Status = .{};
    var last_health = Timer.now();
    while (true) {
        Watchdog.kick();
        // Service completions continuously while the host owns SD.
        usb.poll();
        if (Timer.elapsed(last_health) >= Timer.milliseconds(1000)) {
            last_health = Timer.now();
            diag.samplePower(pmic);
        }
        switch (usb.session().state) {
            .remounting, .player, .ejected => return,
            else => {},
        }
        const phase: view.Phase = switch (usb.session().state) {
            .quiescing => .connecting,
            .ejecting => .ejecting,
            else => .connected,
        };
        const power = @import("battery.zig").Status.fromPower(if (diag.report.power_valid & 1 != 0) diag.report.battery_mv else 0, diag.report.power_valid & (1 << 5) != 0, diag.report.power_valid & (1 << 3) != 0);
        if (previous_phase == null or previous_phase.? != phase or !std.meta.eql(previous_power, power)) {
            view.renderPalette(@import("canvas.zig").Canvas.init(LcdDma.framebuffer), phase, power, usb_palette);
            _ = Display.present();
            previous_phase = phase;
            previous_power = power;
        }
        switch (usb.session().state) {
            .quiescing => usb.grantHost() catch {},
            .host, .ejecting => {},
            .remounting, .player, .ejected => return,
        }
    }
}

fn keepAlive() void {
    Watchdog.kick();
}

export fn tud_vendor_control_xfer_cb(port: u8, stage: u8, request: ?*const @import("c_usb").tusb_control_request_t) bool {
    return if (options.maintenance) maintenance.control(port, stage, request) else false;
}

var idle_music_session: ?*MusicSession = null;

const MusicSession = struct {
    const SavedCompletion = struct { slot: u3, success: bool, count: u16 };
    const LibraryCompletion = struct {
        summary: [8]@import("saved_playlists.zig").Summary,
        activity_available: bool,
        saved_available: bool,
        save: ?SavedCompletion = null,
        notice: ?[]const u8 = null,
    };

    state: *@import("f20_music_ui.zig").State,
    input: *Input,
    pmic: *@import("f20_power.zig").Controller,
    preferences_store: *@import("f20_preferences.zig").Store,
    preferences_seen: @import("preferences.zig").Options,
    preferences_due: ?u64 = null,
    listening_store: *@import("f20_session.zig").Store,
    activity_store: *@import("f20_activity.zig").Store,
    activity_state: *@import("listening_activity.zig").State,
    playlist_store: *@import("f20_playlists.zig").Store,
    library_loaded: bool = false,
    activity_view_revision: u32 = 0,
    library_completion: ?LibraryCompletion = null,
    resume_pending: ?@import("listening_session.zig").Record = null,
    resume_revision: ?u32 = null,
    listening_ready: bool = false,
    checkpoint: @import("listening_session.zig").Checkpoint = .{},
    power_policy: @import("listening_power.zig").Policy = .{},
    power_poll_at: u64 = 0,
    jack_poll_at: u32 = 0,
    sleep_seen: u32 = 0,
    output_policy: @import("listening_power.zig").OutputPolicy = .{ .settle_ticks = Timer.milliseconds(40) },
    jack_pause_event: std.atomic.Value(bool) = .init(false),
    desired_output: std.atomic.Value(u32) = .init(@backingInt(@import("f20_audio.zig").Output.headphones)),
    active_output: std.atomic.Value(u32) = .init(@backingInt(@import("f20_audio.zig").Output.headphones)),
    activity_seen: ?u64 = null,
    unplug_pause: @import("listening_power.zig").PauseRequest = .{},
    fat_seeks: *@import("file_seek_index.zig").Cache,
    theme_pending: bool = true,
    return_rom: bool = false,
    playing: bool = false,
    flush_pending: bool = false,
    last_log_flush: u64 = 0,
    reconnect_pending: bool = false,
    power_started: ?u64 = null,
    power_off: bool = false,
    input_generation: u32 = 0,
    clock: @import("executive.zig").Clock = .{ .previous = 0 },

    fn now(self: *@This()) u64 {
        // UI and storage share this wrapping hardware clock. Sample and extend
        // it as one tiny operation so preemption cannot invent an epoch.
        const masks = x1000.Interrupts.disableCpu();
        defer x1000.Interrupts.restoreCpu(masks);
        const counter = Timer.now();
        if (counter < self.clock.previous) diag.report.ui_clock_wraps += 1;
        return self.clock.sample(counter) / Timer.milliseconds(1);
    }

    fn sourceIdentity(track: *const @import("library.zig").Track) u64 {
        var bytes: [40]u8 = undefined;
        std.mem.writeInt(u64, bytes[0..8], track.id, .little);
        std.mem.writeInt(u64, bytes[8..16], track.stamp.size, .little);
        std.mem.writeInt(i64, bytes[16..24], track.stamp.modified, .little);
        std.mem.writeInt(u64, bytes[24..32], track.stamp.device, .little);
        std.mem.writeInt(u64, bytes[32..40], track.stamp.inode, .little);
        return std.hash.Wyhash.hash(0x47534f55, &bytes) | 1;
    }

    fn storageCancelled(context: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        Watchdog.kick();
        return self.return_rom or self.power_off or self.reconnect_pending or self.state.requested_track != null or usb.needsHandoff();
    }

    fn prepareReader(self: *@This(), reader: *Volume.Reader, identity: u64) void {
        reader.enableAudioSeeks(self.fat_seeks.forSource(identity), identity);
        reader.seek_control = .{ .context = self, .cancelled = storageCancelled };
    }

    fn openNext(context: *anyopaque, storage_reader: *anyopaque, previous: player.SequenceTrack) anyerror!?player.SequenceTrack {
        const self: *@This() = @ptrCast(@alignCast(context));
        const order = &self.state.track_store.order;
        if (storageCancelled(self) or order.membership_revision != previous.revision or order.repeat == .one) return null;
        const previous_position = order.positionOf(previous.occurrence) orelse return null;
        var cursor = order.*;
        cursor.cursor = previous_position;
        const Resolver = struct {
            view: *const @import("progressive_view.zig").Snapshot,
            pub fn contains(resolver: @This(), id: u64) bool {
                return resolver.view.trackById(id) != null;
            }
        };
        const id = cursor.adjacent(1, Resolver{ .view = self.state.snapshot() }) orelse return null;
        // Repeat wrapping is a controlled main-loop boundary in this first
        // release; no occurrence is decoded twice inside the admission window.
        if (cursor.cursor <= previous_position) return null;
        const occurrence = cursor.occurrenceAt(cursor.cursor).?;
        const track = self.state.snapshot().trackById(id) orelse return null;
        const identity = sourceIdentity(track);
        const gain = self.state.replay_gain.gain(track.meta.gain);
        const entry = try self.state.index.volume.findPath(track.path);
        var reader = try self.state.index.volume.reader(try entry.file());
        if (storageCancelled(self) or order.membership_revision != previous.revision) return null;
        const admission = order.prepareCommit(occurrence) catch return null;
        self.prepareReader(&reader, identity);
        const target: *Volume.Reader = @ptrCast(@alignCast(storage_reader));
        // No I/O or unbounded searches inside the commit. UI sees either no
        // admission or a complete queue fence and matching storage reader.
        const masks = x1000.Interrupts.disableCpu();
        defer x1000.Interrupts.restoreCpu(masks);
        if (storageCancelled(self) or order.membership_revision != previous.revision) return null;
        order.commitPrepared(admission) catch return null;
        target.* = reader;
        return .{ .occurrence = occurrence, .revision = previous.revision, .length = entry.size, .gain_q24 = gain, .source_identity = identity };
    }

    fn audible(context: *anyopaque, track: player.SequenceTrack) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.state.requested_track != null or track.occurrence == self.state.playing_occurrence) return;
        const order = &self.state.track_store.order;
        const position = order.positionOf(track.occurrence) orelse return;
        const id = order.at(position).?;
        const fallback = @import("library.zig").Track{ .id = id, .path = "", .stamp = .{}, .meta = .{ .title = "Unavailable track" } };
        const metadata = self.state.snapshot().trackById(id) orelse &fallback;
        _ = self.state.track_store.queue(metadata) catch self.state.track_store.queue(&fallback) catch |failure| {
            diag.failed(9, failure);
            self.state.failure = true;
            return;
        };
        if (!order.advanceCommitted(track.occurrence)) {
            self.state.track_store.pending = false;
            return;
        }
        self.state.playing_track = self.state.track_store.begin();
        self.state.playing_occurrence = track.occurrence;
        self.state.pending_frame.ready = false;
        self.state.major = true;
        self.state.dirty = true;
    }

    /// This callback is the sole I2C owner while audio runs. The UI consumes a
    /// compact observation, never starting a bus transaction during painting.
    fn background(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        diag.samplePower(self.pmic);
        const ticks = Timer.now();
        if (ticks -% self.jack_poll_at < Timer.milliseconds(100)) return;
        self.jack_poll_at = ticks;
        const jacks = self.pmic.jacks() catch {
            _ = self.output_policy.observe(ticks, null, self.outputRoute(), self.playing and self.state.status.phase != .paused);
            @import("health.zig").snapshot.jack_flags = 0;
            return;
        };
        if (self.output_policy.observe(ticks, jacks, self.outputRoute(), self.playing and self.state.status.phase != .paused)) |decision| {
            if (decision.pause) self.jack_pause_event.store(true, .release);
            self.desired_output.store(@backingInt(if (decision.route == .headphone) @import("f20_audio.zig").Output.headphones else .line_out), .release);
        }
        @import("health.zig").snapshot.jack_flags = 1 | (@as(u32, @intFromBool(jacks.headphone)) << 1) | (@as(u32, @intFromBool(jacks.line)) << 2);
    }

    fn outputRoute(self: *@This()) @import("listening_power.zig").Route {
        return switch (@as(@import("f20_audio.zig").Output, @fromBackingInt(@as(u2, @intCast(self.active_output.load(.acquire)))))) {
            .headphones => .headphone,
            .line_out => .line,
            .muted => .none,
        };
    }

    fn route(context: *anyopaque, actual: @import("f20_audio.zig").Output) ?@import("f20_audio.zig").Output {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.active_output.store(@backingInt(actual), .release);
        @import("health.zig").snapshot.output_route = @backingInt(actual);
        return @fromBackingInt(@as(u2, @intCast(self.desired_output.load(.acquire))));
    }

    fn restoreListening(self: *@This()) void {
        const record = self.resume_pending orelse {
            self.listening_ready = true;
            return;
        };
        // An explicit song choice always wins over automatic paused restore.
        if (self.state.requested_track != null) {
            self.resume_pending = null;
            self.listening_ready = true;
            return;
        }
        const view = self.state.snapshot();
        if (!self.state.index.complete or !view.complete or self.resume_revision == view.revision) return;
        self.resume_revision = view.revision;
        self.state.restoreListening(record) catch return;
        self.resume_pending = null;
        self.listening_ready = true;
    }

    fn saveListening(self: *@This(), force: bool) void {
        if (!self.listening_ready or self.listening_store.disabled or self.listening_store.file == null) return;
        const masks = x1000.Interrupts.disableCpu();
        const due = self.checkpoint.due(self.now(), force);
        const serial = self.checkpoint.serial;
        const revision = self.state.track_store.order.revision;
        const position = self.state.listeningPosition();
        const location = self.state.listeningNavigation();
        x1000.Interrupts.restoreCpu(masks);
        if (!due) return;
        self.listening_store.save(self.state.index.volume, &self.state.track_store.order, revision, self.state.snapshot().source, position, location);
        if (self.listening_store.cancelled) return;
        const completed = x1000.Interrupts.disableCpu();
        self.checkpoint.saved(self.now(), serial);
        x1000.Interrupts.restoreCpu(completed);
    }

    fn publishLibrary(self: *@This(), save: ?SavedCompletion, notice: ?[]const u8) void {
        const masks = x1000.Interrupts.disableCpu();
        defer x1000.Interrupts.restoreCpu(masks);
        var completion = self.library_completion orelse LibraryCompletion{
            .summary = self.playlist_store.value.summary,
            .activity_available = self.activity_store.file != null,
            .saved_available = self.playlist_store.file != null,
        };
        completion.summary = self.playlist_store.value.summary;
        completion.activity_available = self.activity_store.file != null;
        completion.saved_available = self.playlist_store.file != null;
        if (save) |value| completion.save = value;
        if (notice) |value| completion.notice = value;
        self.library_completion = completion;
    }

    fn consumeLibrary(self: *@This()) void {
        const masks = x1000.Interrupts.disableCpu();
        const completion = self.library_completion;
        self.library_completion = null;
        x1000.Interrupts.restoreCpu(masks);
        if (completion) |value| {
            self.state.activity_available = value.activity_available;
            self.state.saved_available = value.saved_available;
            self.state.saved_summary = value.summary;
            if (value.save) |saved| self.state.savedPlaylistResult(saved.slot, saved.success, saved.count);
            if (value.notice) |notice| self.state.libraryNotice(notice);
        }
    }

    fn libraryNeedsWork(self: *@This()) bool {
        return self.listening_ready and (!self.library_loaded or self.state.favourite_request != null or self.state.saved_request != null or self.activity_view_revision != self.state.snapshot().revision or self.activity_state.revision != self.state.snapshot().activity_revision or (self.activity_store.file != null and !self.activity_store.disabled and self.activity_store.saved_revision != self.activity_state.revision));
    }

    fn serviceLibrary(self: *@This(), service: player.StorageService) void {
        if (!self.listening_ready or !self.state.index.complete) return;
        const observer = struct {
            service: player.StorageService,
            pub fn cancelled(value: @This()) bool {
                return value.service.poll(value.service.context);
            }
        }{ .service = service };
        if (!self.library_loaded) {
            self.activity_store.load(self.state.index.volume, self.activity_state);
            if (self.activity_store.cancelled or observer.cancelled()) return;
            self.playlist_store.open(self.state.index.volume, self.state.snapshot().source);
            if (self.playlist_store.cancelled) return;
            self.publishLibrary(null, null);
            self.state.index.projection.activity = self.activity_state;
            self.library_loaded = true;
        }
        if (observer.cancelled()) return;
        var changed = self.activity_view_revision != self.state.snapshot().revision or self.activity_state.revision != self.state.snapshot().activity_revision;
        if (changed and self.state.snapshot().complete) self.activity_state.reconcile(self.state.snapshot(), memory.session_scratch.cachedSlice(u8), observer) catch return;
        const claim = x1000.Interrupts.disableCpu();
        const favourite = self.state.favourite_request;
        self.state.favourite_request = null;
        x1000.Interrupts.restoreCpu(claim);
        if (favourite) |request| {
            const resolved = @import("listening_activity.zig").resolveFavouriteId(self.state.snapshot(), request.kind, request.id, request.anchor);
            const before = self.activity_state.revision;
            self.activity_state.applyFavourite(request.kind, resolved, request.anchor, request.enabled) catch |failure| {
                self.publishLibrary(null, if (failure == error.ActivityCapacity) "Favourites full" else "Cannot update favourites");
                return;
            };
            changed = changed or before != self.activity_state.revision;
        }
        if (changed) {
            const revision = self.state.index.projection.prepareActivity(observer) catch return;
            self.state.index.projection.commit(revision);
            self.activity_view_revision = revision;
        }
        if (observer.cancelled()) return;
        self.activity_store.save(self.state.index.volume, self.activity_state);
        if (observer.cancelled()) return;
        const saved_claim = x1000.Interrupts.disableCpu();
        const saved = self.state.saved_request;
        if (saved == null or saved.?.action != .load or !self.playing) self.state.saved_request = null;
        const expected_revision = self.state.track_store.order.revision;
        x1000.Interrupts.restoreCpu(saved_claim);
        if (saved) |request| {
            if (request.action == .load and self.playing) return;
            if (request.action == .save) {
                if (request.membership_revision != self.state.track_store.order.membershipRevision()) {
                    self.publishLibrary(null, "Queue changed");
                    return;
                }
                const success = self.playlist_store.save(self.state.index.volume, request.slot, &self.state.track_store.order, expected_revision, self.state.snapshot().source);
                if (!self.playlist_store.cancelled) self.publishLibrary(.{ .slot = request.slot, .success = success, .count = self.playlist_store.value.summary[request.slot].count }, null);
            } else {
                // Audio workers have joined. This idle owner may restore the
                // queue synchronously; restoration performs no I/O or yields.
                if (self.playlist_store.load(self.state.index.volume, request.slot, self.state.snapshot().source)) |data| {
                    self.state.loadedSavedPlaylist(data) catch |failure| {
                        if (failure != error.PlaylistSuperseded) self.publishLibrary(null, "Playlist unavailable");
                    };
                } else if (!self.playlist_store.cancelled) self.publishLibrary(null, "Playlist unavailable");
            }
            if (self.playlist_store.cancelled) {
                const retry = x1000.Interrupts.disableCpu();
                if (self.state.saved_request == null) self.state.saved_request = request;
                x1000.Interrupts.restoreCpu(retry);
            } else self.publishLibrary(null, null);
        }
    }

    fn flushLibrary(self: *@This()) void {
        if (!self.library_loaded) return;
        if (self.state.favourite_request) |request| {
            self.state.favourite_request = null;
            const resolved = @import("listening_activity.zig").resolveFavouriteId(self.state.snapshot(), request.kind, request.id, request.anchor);
            self.activity_state.applyFavourite(request.kind, resolved, request.anchor, request.enabled) catch {};
        }
        self.activity_store.save(self.state.index.volume, self.activity_state);
        if (self.state.saved_request) |request| {
            if (request.action == .save and request.membership_revision == self.state.track_store.order.membershipRevision()) _ = self.playlist_store.save(self.state.index.volume, request.slot, &self.state.track_store.order, self.state.track_store.order.revision, self.state.snapshot().source);
            self.state.saved_request = null;
        }
    }

    fn control(context: *anyopaque, status: media.PlaybackStatus) media.PlaybackCommand {
        const self: *@This() = @ptrCast(@alignCast(context));
        Watchdog.kick();
        usb.poll();
        if (usb.needsHandoff() or self.power_off or self.return_rom or self.reconnect_pending) return .stop;
        var remote: ?UiEvent = null;
        if (options.maintenance) if (maintenance.take()) |command| switch (command.action) {
            .quick => self.state.index.request(false),
            .verify, .rebuild => self.state.index.request(true),
            .stop => return .stop,
            .rom => {
                self.return_rom = true;
                return .stop;
            },
            .play => if (diag.catalog) |*catalogue| {
                if (command.value < catalogue.value.tracks.len) {
                    self.state.track_store.order.clear();
                    self.state.track_store.order.append(catalogue.value.tracks[command.value].id) catch unreachable;
                    self.state.queue(&catalogue.value.tracks[command.value]);
                    self.state.navigate(.player);
                    if (self.playing) return .stop;
                }
            },
            .toggle_lock => self.state.toggleLock(),
            .input => remote = @fromBackingInt(@intCast(command.value)),
            .input_sample => self.input.injected = if (command.value == 0xffff) null else command.value,
            .reconnect => {
                self.reconnect_pending = true;
                return .stop;
            },
            .flush => self.flush_pending = true,
        };
        self.consumeLibrary();
        self.state.setPlaybackStatus(status);
        @import("health.zig").snapshot.playback_phase = @backingInt(status.phase);
        @import("health.zig").snapshot.queue_count = @intCast(self.state.track_store.order.count);
        @import("health.zig").snapshot.queue_cursor = @intCast(self.state.track_store.order.cursor);
        const now_ms = self.now();
        if (self.sleep_seen != self.state.sleep_revision) {
            self.sleep_seen = self.state.sleep_revision;
            self.power_policy.setSleep(now_ms, self.state.sleep_timer);
        }
        if (self.activity_seen != self.state.last_activity) {
            self.activity_seen = self.state.last_activity;
            self.power_policy.activity(now_ms);
        }
        self.unplug_pause.observe(self.playing, status.phase, self.state.requested_track != null);
        if (self.jack_pause_event.swap(false, .acq_rel) and self.playing and status.phase != .paused) self.unplug_pause.request();
        if (now_ms >= self.power_poll_at) {
            self.power_poll_at = now_ms +| 100;
            if (!self.playing) background(self);
            // Physical jack edges are captured by the control owner before
            // changing its output route. This UI policy owns timer decisions.
            const policy_action = self.power_policy.tick(now_ms, self.state.paused_idle, .{ .playing = self.playing and status.phase != .paused, .host_owned = false, .route = self.outputRoute(), .jacks = null });
            if (policy_action == .shutdown) {
                self.power_off = true;
                return .stop;
            }
            if (policy_action == .pause) self.unplug_pause.request();
        }
        const at = Timer.now();
        const sample = self.input.injected;
        self.input.music.observe(.{ .at = at, .buttons = if (sample) |value| @truncate(value) else buttonState(), .wheel = if (sample) |value| @truncate(value >> 8) else wheelState() });
        if (self.input_generation != self.input.generation) {
            self.input_generation = self.input.generation;
            self.state.cancelInput(0);
        }
        var result: media.PlaybackCommand = if (remote) |event| self.state.handle(event, now_ms, self.playing) else .none;
        if (std.meta.activeTag(result) == .none) result = self.input.music.dispatch(self.state, at, now_ms, Timer.milliseconds(1), self.playing);
        self.input.stable_buttons = self.input.music.decoder.stable;
        const power_down = self.input.stable_buttons & board.ButtonId.power.mask() != 0;
        if (power_down) {
            if (self.power_started == null) self.power_started = now_ms;
            if (now_ms - self.power_started.? >= 1500) {
                self.power_off = true;
                return .stop;
            }
        } else self.power_started = null;
        self.state.refreshBattery(if (diag.report.power_valid & 1 != 0) diag.report.battery_mv else 0, diag.report.power_valid & (1 << 5) != 0, diag.report.power_valid & (1 << 3) != 0, now_ms);
        self.state.frame(self.now());
        const preferences = self.state.preferences();
        if (!std.meta.eql(preferences, self.preferences_seen)) {
            self.preferences_seen = preferences;
            self.preferences_due = now_ms +| 1000;
        }
        const health = &@import("health.zig").snapshot;
        health.ui_locked = @intFromBool(self.state.locked);
        health.ui_appearance = @backingInt(self.state.appearance);
        health.ui_attenuation = self.state.attenuation;
        health.ui_backlight_active = @intFromBool(board.display.backlight.get());
        if (self.listening_ready) self.checkpoint.observe(now_ms, self.state.track_store.order.revision, self.state.track_store.order.cursor, self.playing and status.phase != .paused);
        if (self.state.failure) return .stop;
        return self.unplug_pause.command(status.phase, result);
    }

    fn savePreferences(self: *@This(), force: bool) void {
        const due = self.preferences_due orelse return;
        if (!force and self.now() < due) return;
        const value = self.state.preferences();
        self.preferences_store.save(self.state.index.volume, value);
        // A cooperative card operation may have serviced a newer user choice.
        const masks = x1000.Interrupts.disableCpu();
        if (std.meta.eql(value, self.state.preferences())) self.preferences_due = null;
        x1000.Interrupts.restoreCpu(masks);
    }

    fn storageWork(context: *anyopaque, service: player.StorageService) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (service.poll(service.context)) return;
        if (self.theme_pending and !self.playing) {
            self.theme_pending = false;
            @import("f20_themes.zig").load(self.state.index.volume, self.state);
        }
        self.listening_store.service = service;
        self.activity_store.service = service;
        self.playlist_store.service = service;
        defer {
            self.listening_store.service = null;
            self.activity_store.service = null;
            self.playlist_store.service = null;
        }
        self.savePreferences(false);
        self.saveListening(false);
        if (service.poll(service.context)) return;
        self.serviceLibrary(service);
        if (service.poll(service.context)) return;
        @import("f20_index.zig").State.run(self.state.index, service);
        if (service.poll(service.context)) return;
        const claim = x1000.Interrupts.disableCpu();
        const forced = self.flush_pending;
        self.flush_pending = false;
        x1000.Interrupts.restoreCpu(claim);
        if (forced or self.now() -| self.last_log_flush >= 60_000) {
            const pages: usize = if (forced) 8 else 1;
            for (0..pages) |_| {
                if (service.poll(service.context)) break;
                diag.flushStorage(service);
            }
            self.last_log_flush = self.now();
        }
    }

    fn idlePoll(context: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = control(self, self.state.status);
        @import("f20_display.zig").idleLaunch();
        if (!self.state.isAnimating(self.now())) diag.samplePower(self.pmic);
        return usb.needsHandoff() or self.return_rom or self.power_off or self.reconnect_pending or
            self.state.requested_track != null;
    }

    fn retireCatalogue(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.state.catalogueRetired();
    }

    fn serviceCovers(context: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.state.index.covers) |loader| loader.service(self.state.index.volume);
    }

    fn keepIdleResponsive() void {
        if (idle_music_session) |session| {
            _ = control(session, session.state.status);
            @import("f20_display.zig").idleLaunch();
        }
    }
};

fn browseMusic(volume: *Volume, battery_mv: u32, attenuation: *u8, input: *Input, pmic: *@import("f20_power.zig").Controller) !void {
    const seek_cache: *@import("audio_seek.zig").Cache = @ptrFromInt(memory.audio_seek.cached());
    const fat_seeks: *@import("file_seek_index.zig").Cache = @ptrFromInt(std.mem.alignForward(usize, memory.audio_seek.cached() + @sizeOf(@import("audio_seek.zig").Cache), @alignOf(@import("file_seek_index.zig").Cache)));
    comptime {
        if (@sizeOf(@import("audio_seek.zig").Cache) + @sizeOf(@import("file_seek_index.zig").Cache) + 16 > memory.audio_seek.bytes) @compileError("audio seek workspace exceeds reservation");
    }
    seek_cache.reset();
    fat_seeks.reset();
    var activity_state = try @import("listening_activity.zig").State.init(memory.activity_records.cachedSlice(u8), volume.serial);
    var activity_store = @import("f20_activity.zig").Store{};
    var playlist_store = @import("f20_playlists.zig").Store{};
    var listening_store = @import("f20_session.zig").Store{};
    const resume_record = listening_store.load(volume, volume.serial);
    var preference_store = @import("f20_preferences.zig").Store{};
    var preferences = preference_store.load(volume);
    if (preference_store.journal.saved == null) {
        preferences.appearance = appearance;
        preferences.attenuation = attenuation.*;
    }
    var index = try @import("f20_index.zig").State.init(volume);
    const covers = @import("f20_covers.zig").Loader.init();
    index.covers = covers;
    const text = @import("f20_text.zig").Loader.init(volume);
    index.text = text;
    text_loader = text;
    LcdDma.text_cache = &text.cache;
    defer {
        LcdDma.text_cache = null;
        text_loader = null;
        text.deinit();
    }
    index.request(false);
    var state = @import("f20_music_ui.zig").State{ .index = &index, .covers = &covers.cache, .text_cache = &text.cache, .attenuation = attenuation.*, .battery_mv = battery_mv, .appearance = appearance, .track_store = @import("track_selection.zig").Store.init(memory.scan_artwork.cachedSlice(u8)) };
    state.theme_store = retained_themes;
    state.applyPreferences(preferences);
    var session = MusicSession{ .state = &state, .input = input, .pmic = pmic, .preferences_store = &preference_store, .preferences_seen = preferences, .listening_store = &listening_store, .activity_state = &activity_state, .activity_store = &activity_store, .playlist_store = &playlist_store, .resume_pending = resume_record, .listening_ready = resume_record == null, .fat_seeks = fat_seeks };
    index.retirement = .{ .context = &session, .withdraw = MusicSession.retireCatalogue };
    // Font source polls occur between card transactions, so a long font read
    // can give urgent artwork a turn without adding a second storage owner.
    text.storage_work.hook = .{ .context = &session, .run = MusicSession.serviceCovers };
    defer text.storage_work.hook = null;
    const old_keep_alive = volume.device.keep_alive;
    idle_music_session = &session;
    volume.device.keep_alive = MusicSession.keepIdleResponsive;
    covers.idle_yield = .{ .context = &session, .poll = MusicSession.idlePoll };
    defer {
        volume.device.keep_alive = old_keep_alive;
        idle_music_session = null;
        covers.idle_yield = null;
    }
    defer attenuation.* = state.attenuation;
    defer appearance = state.appearance;
    defer usb_palette = state.palette();
    defer retained_themes = state.theme_store;
    var last_flush = Timer.now();
    diag.booted();
    while (true) {
        _ = MusicSession.control(&session, state.status);
        session.restoreListening();
        session.savePreferences(false);
        session.saveListening(false);
        if (session.power_off) {
            index.finish();
            session.savePreferences(true);
            session.saveListening(true);
            session.flushLibrary();
            diag.flush();
            powerOff(pmic);
        }
        if (session.flush_pending) {
            session.flush_pending = false;
            diag.flush();
        }
        if (session.reconnect_pending) {
            index.finish();
            session.savePreferences(true);
            session.saveListening(true);
            session.flushLibrary();
            diag.flush();
            usb.reconnect();
            return;
        }
        if (options.maintenance and session.return_rom) {
            index.finish();
            session.savePreferences(true);
            session.saveListening(true);
            session.flushLibrary();
            diag.flush();
            maintenance.returnRom();
        }
        if (usb.needsHandoff()) {
            session.power_policy.setSleep(session.now(), .off);
            state.sleep_timer = .off;
            index.finish();
            session.savePreferences(true);
            session.saveListening(true);
            session.flushLibrary();
            return;
        }
        if (state.requested_track) |track| {
            var path_buffer: [4096]u8 = undefined;
            if (track.path.len > path_buffer.len) return error.PathTooLong;
            @memcpy(path_buffer[0..track.path.len], track.path);
            const path = path_buffer[0..track.path.len];
            const selected_id = track.id;
            const selected_occurrence = state.playing_occurrence;
            const start_frame = state.requested_start_frame;
            const initially_paused = state.resume_paused or session.unplug_pause.pending;
            const identity = MusicSession.sourceIdentity(track);
            state.requested_track = null;
            const entry = volume.findPath(path) catch |failure| {
                if (state.requested_track != null) continue;
                return failure;
            };
            if (state.requested_track != null) continue;
            var reader = try volume.reader(try entry.file());
            // Filesystem waits may service input. A newer explicit selection
            // owns the pending metadata slot and wins before this reader starts.
            if (state.requested_track != null) continue;
            session.prepareReader(&reader, identity);
            state.playing_track = state.track_store.begin() orelse return error.InvalidSelection;
            if (state.playing_track.?.id != selected_id) return error.InvalidSelection;
            state.playing_occurrence = selected_occurrence;
            state.pending_frame.ready = false;
            state.major = true;
            state.dirty = true;
            session.playing = true;
            index.playing = true;
            var measured = player.Report.empty();
            var playback_failed = false;
            volume.device.keep_alive = null;
            covers.idle_yield = null;
            diag.report.stage = 2;
            const result = player.playFile(&reader, entry.size, volume.device, .{
                .attenuation = state.attenuation,
                .seek_cache = seek_cache,
                .source_identity = identity,
                .sequence = if (state.playing_occurrence != 0) .{ .context = &session, .first = .{ .occurrence = state.playing_occurrence, .revision = state.track_store.order.membership_revision, .length = entry.size, .gain_q24 = state.replay_gain.gain(state.playing_track.?.meta.gain), .source_identity = identity }, .open_next = MusicSession.openNext, .audible = MusicSession.audible } else null,
                .force_output_24 = true,
                .gain_q24 = state.replay_gain.gain(state.playing_track.?.meta.gain),
                .start_frame = start_frame,
                .initially_paused = initially_paused,
                .measure_stacks = options.maintenance,
                .report_out = &measured,
                .background = .{ .context = &session, .poll = MusicSession.background },
                .routing = .{ .context = &session, .poll = MusicSession.route },
                .storage_work = .{ .context = &session, .run = MusicSession.storageWork },
            }, .{ .context = &session, .poll = MusicSession.control }) catch |failure| failed: {
                diag.failed(1, failure);
                playback_failed = true;
                break :failed measured;
            };
            diag.report.stage = 0;
            volume.device.keep_alive = MusicSession.keepIdleResponsive;
            covers.idle_yield = .{ .context = &session, .poll = MusicSession.idlePoll };
            session.playing = false;
            index.playing = false;
            if (state.failure and diag.report.failure != 0) diag.failed(9, @errorFromInt(@as(u16, @intCast(diag.report.failure))));
            diag.playback(result);
            state.attenuation = result.playback.attenuation;
            if (result.final_status) |final| state.setPlaybackStatus(final);
            state.track_store.order.committed_count = 0;
            state.playbackFinished(result.playback, playback_failed);
            const handoff_began = Timer.now();
            // A completed scan already published its new catalogue, and a
            // cancelled scan withdrew its preview before reclaiming memory.
            // Track changes alone do not change library membership or order.
            index.finish();
            session.savePreferences(true);
            session.saveListening(true);
            session.flushLibrary();
            diag.flush();
            input.resync();
            _ = LcdDma.resetForDirect();
            state.pending_frame.ready = false;
            state.major = true;
            state.dirty = true;
            diag.report.playback_handoff_max = @max(diag.report.playback_handoff_max, Timer.elapsed(handoff_began));
            continue;
        }
        if (index.requested or session.theme_pending or session.libraryNeedsWork()) MusicSession.storageWork(&session, .{ .context = &session, .poll = MusicSession.idlePoll });
        covers.service(volume);
        text.serviceWithYield(.{ .context = &session, .poll = MusicSession.idlePoll });
        @import("f20_display.zig").idleLaunch();
        if (!state.isAnimating(session.now())) {
            diag.samplePower(pmic);
            if (Timer.elapsed(last_flush) >= Timer.milliseconds(60_000)) {
                last_flush = Timer.now();
                diag.flush();
            }
        }
        if (index.pending != null or index.error_pending != null) {
            index.finish();
        }
        Timer.delayMicroseconds(1000);
    }
}
