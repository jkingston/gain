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

fn playbackPower(context: *anyopaque) void {
    diag.samplePower(@ptrCast(@alignCast(context)));
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
            view.renderThemed(@import("canvas.zig").Canvas.init(LcdDma.framebuffer), phase, power, appearance);
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
    state: *@import("f20_music_ui.zig").State,
    input: *Input,
    pmic: *@import("f20_power.zig").Controller,
    return_rom: bool = false,
    playing: bool = false,
    flush_pending: bool = false,
    reconnect_pending: bool = false,
    power_started: ?u64 = null,
    power_off: bool = false,
    input_generation: u32 = 0,
    clock: @import("executive.zig").Clock = .{ .previous = 0 },

    fn now(self: *@This()) u64 {
        const counter = Timer.now();
        if (counter < self.clock.previous) diag.report.ui_clock_wraps += 1;
        return self.clock.sample(counter) / Timer.milliseconds(1);
    }

    fn control(context: *anyopaque, status: media.PlaybackStatus) media.PlaybackCommand {
        const self: *@This() = @ptrCast(@alignCast(context));
        Watchdog.kick();
        usb.poll();
        if (usb.needsHandoff()) return .stop;
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
            .input => remote = @fromBackingInt(@intCast(command.value)),
            .input_sample => self.input.injected = if (command.value == 0xffff) null else command.value,
            .reconnect => {
                self.reconnect_pending = true;
                return .stop;
            },
            .flush => self.flush_pending = true,
        };
        self.state.status = status;
        @import("health.zig").snapshot.playback_phase = @backingInt(status.phase);
        @import("health.zig").snapshot.queue_count = @intCast(self.state.track_store.order.count);
        @import("health.zig").snapshot.queue_cursor = @intCast(self.state.track_store.order.cursor);
        const now_ms = self.now();
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
        const health = &@import("health.zig").snapshot;
        health.ui_locked = @intFromBool(self.state.locked);
        health.ui_appearance = @backingInt(self.state.appearance);
        health.ui_attenuation = self.state.attenuation;
        health.ui_backlight_active = @intFromBool(board.display.backlight.get());
        if (self.state.failure) return .stop;
        return result;
    }

    fn idlePoll(context: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = control(self, self.state.status);
        @import("f20_display.zig").idleLaunch();
        if (!self.state.isAnimating(self.now())) diag.samplePower(self.pmic);
        return usb.needsHandoff() or self.return_rom or self.power_off or self.reconnect_pending or
            self.state.requested_track != null;
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
    var session = MusicSession{ .state = &state, .input = input, .pmic = pmic };
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
    var last_flush = Timer.now();
    diag.booted();
    while (true) {
        _ = MusicSession.control(&session, state.status);
        if (session.power_off) {
            index.finish();
            diag.flush();
            powerOff(pmic);
        }
        if (session.flush_pending) {
            session.flush_pending = false;
            diag.flush();
        }
        if (session.reconnect_pending) {
            index.finish();
            diag.flush();
            usb.reconnect();
            return;
        }
        if (options.maintenance and session.return_rom) {
            index.finish();
            diag.flush();
            maintenance.returnRom();
        }
        if (usb.needsHandoff()) {
            index.finish();
            return;
        }
        if (state.requested_track) |track| {
            var path_buffer: [4096]u8 = undefined;
            if (track.path.len > path_buffer.len) return error.PathTooLong;
            @memcpy(path_buffer[0..track.path.len], track.path);
            const path = path_buffer[0..track.path.len];
            state.requested_track = null;
            const entry = try volume.findPath(path);
            var reader = try volume.reader(try entry.file());
            state.playing_track = state.track_store.begin() orelse return error.InvalidSelection;
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
                .force_output_24 = true,
                .gain_q24 = state.replay_gain.gain(state.playing_track.?.meta.gain),
                .start_frame = state.requested_start_frame,
                .initially_paused = state.resume_paused,
                .measure_stacks = options.maintenance,
                .report_out = &measured,
                .background = .{ .context = pmic, .poll = playbackPower },
                .storage_work = .{ .context = &index, .run = @import("f20_index.zig").State.run },
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
            state.playbackFinished(result.playback, playback_failed);
            const handoff_began = Timer.now();
            // A completed scan already published its new catalogue, and a
            // cancelled scan withdrew its preview before reclaiming memory.
            // Track changes alone do not change library membership or order.
            index.finish();
            diag.flush();
            input.resync();
            _ = LcdDma.resetForDirect();
            state.pending_frame.ready = false;
            state.major = true;
            state.dirty = true;
            diag.report.playback_handoff_max = @max(diag.report.playback_handoff_max, Timer.elapsed(handoff_began));
            continue;
        }
        if (index.requested) @import("f20_index.zig").State.run(&index, .{ .context = &session, .poll = MusicSession.idlePoll });
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
