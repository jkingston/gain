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
const fat32 = @import("fat32.zig");
const ui = @import("ui.zig");
const player_view = @import("player_view.zig");
const LcdDma = @import("f20_display.zig");

const memory = board.memory;
const Timer = x1000.Timer;
const Watchdog = x1000.Watchdog;
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
const visible_rows = player_view.visible_rows;
const sd_descriptor: *volatile storage.DmaDescriptor = @ptrFromInt(memory.sd_control.uncached());
const sd_switch_status: *align(4) [64]u8 = @ptrFromInt(memory.sd_control.uncached() + 0x100);
const sd_scratch: *[fat32.sector_bytes]u8 = @ptrFromInt(memory.filesystem_sector.uncached());
const Browser = @import("file_browser.zig").Browser(Volume);

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

const PlaybackUi = struct {
    browser: *const Browser,
    entry: *const fat32.DirectoryEntry,
    battery_mv: u32,
    indexed: ?@import("library.zig").Metadata = null,
    screen: @import("player_screen.zig").State,
};

fn buttonState() u8 {
    var sample: u8 = 0;
    for (board.buttons) |button| {
        if (!button.pin.get()) sample |= button.id.mask();
    }
    return sample;
}

fn playbackPoll(context: *anyopaque, status: media.PlaybackStatus) media.PlaybackCommand {
    Watchdog.kick();
    usb.poll();
    if (usb.needsHandoff() or (options.maintenance and maintenance.pending())) return .stop;
    const state: *PlaybackUi = @ptrCast(@alignCast(context));
    return state.screen.poll(LcdDma, buttonState(), playbackTrack(state), state.battery_mv, view_theme, status);
}

const isVisibleEntry = @import("file_browser.zig").isVisibleEntry;

const view_theme = ui.dark_theme;

fn clippedName(name: []const u8, maximum: usize) []const u8 {
    return name[0..@min(name.len, maximum)];
}

fn drawBrowser(volume: *Volume, browser: *const Browser, battery_mv: u32, attenuation: u8, previous: ?player_view.BrowserState) !bool {
    var surface = Display.surface;
    surface.text_cache = LcdDma.text_cache;
    if (surface.text_cache) |cache| cache.beginFrame();
    var scene = ui.Ui.init(surface);
    try browser.draw(volume, &scene, battery_mv, attenuation, view_theme);
    scene.finish();
    const damage = player_view.browserDamage(previous, browserViewState(browser, attenuation));
    if (damage.full) return Display.present();
    for (damage.regions[0..damage.count]) |region| {
        if (!LcdDma.start(region.x, region.y, region.width, region.height) or !LcdDma.wait()) return false;
    }
    return true;
}

fn browserViewState(browser: *const Browser, attenuation: u8) player_view.BrowserState {
    const selected = browser.selection();
    return .{
        .directory = browser.directory().first_cluster,
        .first = if (selected >= visible_rows) selected - (visible_rows - 1) else 0,
        .selected = selected,
        .attenuation = attenuation,
    };
}

fn playbackTrack(state: *const PlaybackUi) player_view.Track {
    if (state.indexed) |meta| return .{ .name = meta.title, .artist = meta.artist, .album = meta.album };
    const artist_depth = if (state.browser.depth > 1) state.browser.depth - 1 else state.browser.depth;
    const artist = state.browser.titles[artist_depth][0..state.browser.title_lengths[artist_depth]];
    return .{
        .name = state.entry.name(),
        .artist = if (state.browser.depth > 0) artist else "",
        .album = if (state.browser.depth > 0) state.browser.title() else "",
    };
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

fn playEntry(
    volume: *Volume,
    browser: *const Browser,
    entry: fat32.DirectoryEntry,
    battery_mv: u32,
    attenuation: u8,
    pmic: *@import("f20_power.zig").Controller,
) !media.Result {
    var file_reader = try volume.reader(try entry.file());
    var playback_ui = PlaybackUi{
        .browser = browser,
        .entry = &entry,
        .battery_mv = battery_mv,
        .screen = @import("player_screen.zig").State.init(attenuation),
    };
    if (diag.catalog) |*catalogue| {
        var buffer: [4096]u8 = undefined;
        var path: std.Io.Writer = .fixed(&buffer);
        for (1..browser.depth + 1) |depth| {
            path.print("{s}/", .{browser.titles[depth][0..browser.title_lengths[depth]]}) catch break;
        }
        path.writeAll(entry.name()) catch {};
        for (catalogue.value.tracks) |track| if (std.mem.eql(u8, track.path, path.buffered())) {
            playback_ui.indexed = track.meta;
            break;
        };
    }
    defer _ = LcdDma.resetForDirect();
    volume.device.keep_alive = null;
    diag.report.failure = 0;
    diag.report.stage = 2;
    var measured = player.Report.empty();
    defer {
        volume.device.keep_alive = keepAlive;
        diag.report.stage = 0;
        diag.playback(measured);
        diag.flush();
    }
    const result = player.playFile(
        &file_reader,
        entry.size,
        volume.device,
        .{
            .storage_work = if (text_loader) |loader| .{ .context = loader, .run = legacyTextStorage } else null,
            .descriptor_count = 120,
            .buffer_count = 3,
            .attenuation = attenuation,
            .report_out = &measured,
            .background = .{ .context = pmic, .poll = playbackPower },
        },
        .{ .context = &playback_ui, .poll = playbackPoll },
    ) catch |failure| {
        diag.failed(1, failure);
        return failure;
    };

    if (playback_ui.screen.failed) return error.DisplayFailure;
    return result.playback;
}

fn legacyTextStorage(context: *anyopaque, service: player.StorageService) void {
    const loader: *@import("f20_text.zig").Loader = @ptrCast(@alignCast(context));
    loader.yield = .{ .context = service.context, .poll = service.poll };
    loader.service();
    loader.yield = null;
}

fn playSelection(
    volume: *Volume,
    browser: *Browser,
    first_entry: fat32.DirectoryEntry,
    battery_mv: u32,
    attenuation: *u8,
    pmic: *@import("f20_power.zig").Controller,
) !void {
    var entry = first_entry;
    while (true) {
        const result = try playEntry(volume, browser, entry, battery_mv, attenuation.*, pmic);
        attenuation.* = result.attenuation;
        if (usb.needsHandoff()) return;
        const direction: i2 = switch (result.exit) {
            .next => 1,
            .previous => -1,
            .completed, .stopped => return,
        };
        entry = (try browser.adjacentTrack(volume, direction)) orelse return;
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
    var bookmark: ?Browser.Bookmark = null;
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

        var browser = Browser.init(&volume) catch |failure| {
            _ = showError("DIRECTORY", failure);
            waitForErrorDismiss(&input);
            if (usb.needsHandoff()) runUsbMode(&pmic);
            continue;
        };
        if (bookmark) |saved| browser.restore(&volume, saved) catch {};
        browseMusic(&volume, &browser, battery_mv, &attenuation, &input, &pmic) catch |failure| {
            _ = showError("DIRECTORY", failure);
            waitForErrorDismiss(&input);
        };
        // playFile has joined every task before browse returns. No decoder,
        // SD prefetch, FAT reader or audio callback can now touch the card.
        bookmark = browser.bookmark(&volume) catch null;
        diag.flush();
        diag.detached();
        if (usb.needsHandoff()) runUsbMode(&pmic);
        input.resync();
    }
}

fn runUsbMode(pmic: *@import("f20_power.zig").Controller) void {
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
        const power = @import("battery.zig").Status.fromVoltage(if (diag.report.power_valid & 1 != 0) diag.report.battery_mv else 0, diag.report.power_valid & (1 << 5) != 0);
        if (previous_phase == null or previous_phase.? != phase or !std.meta.eql(previous_power, power)) {
            view.render(@import("canvas.zig").Canvas.init(LcdDma.framebuffer), phase, power);
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

fn browse(volume: *Volume, browser: *Browser, battery_mv: u32, attenuation_ptr: *u8, input: *Input, pmic: *@import("f20_power.zig").Controller) !void {
    var attenuation = attenuation_ptr.*;
    defer attenuation_ptr.* = attenuation;
    var power_started: ?u32 = null;
    var needs_scan = false;
    var last_flush = Timer.now();
    diag.booted();
    if (!(drawBrowser(volume, browser, battery_mv, attenuation, null) catch |failure| return failure)) return error.DisplayFailure;
    var text_revision: u32 = if (text_loader) |loader| loader.cache.revision.load(.acquire) else 0;
    while (true) {
        if (text_loader) |loader| {
            loader.service();
            const revision = loader.cache.revision.load(.acquire);
            if (revision != text_revision) {
                text_revision = revision;
                if (!(try drawBrowser(volume, browser, battery_mv, attenuation, null))) return error.DisplayFailure;
            }
        }
        Watchdog.kick();
        usb.poll();
        if (usb.needsHandoff()) return;
        diag.samplePower(pmic);
        if (Timer.elapsed(last_flush) >= Timer.milliseconds(60_000)) {
            last_flush = Timer.now();
            diag.flush();
        }
        var remote: ?UiEvent = null;
        if (options.maintenance) if (maintenance.take()) |command| {
            switch (command.action) {
                .quick, .verify, .rebuild => {
                    runIndex(volume, pmic, input, if (command.action == .quick) .quick else .verify);
                    needs_scan = false;
                },
                .play => {
                    if (diag.catalog) |*catalogue| if (command.value < catalogue.value.tracks.len) {
                        const path = catalogue.value.tracks[command.value].path;
                        if (selectPath(volume, browser, path)) |entry| {
                            playSelection(volume, browser, entry, battery_mv, &attenuation, pmic) catch |failure| diag.failed(1, failure);
                        } else |failure| diag.failed(1, failure);
                    };
                },
                .stop => {},
                .input => remote = @fromBackingInt(@intCast(command.value)),
                .input_sample => input.injected = null,
                .reconnect => {
                    diag.flush();
                    usb.reconnect();
                },
                .rom => {
                    diag.flush();
                    maintenance.returnRom();
                },
                .flush => diag.flush(),
            }
            if (!(try drawBrowser(volume, browser, battery_mv, attenuation, null))) return error.DisplayFailure;
        };
        if (needs_scan) {
            needs_scan = false;
            runIndex(volume, pmic, input, .quick);
            if (usb.needsHandoff()) return;
            if (!(try drawBrowser(volume, browser, battery_mv, attenuation, null))) return error.DisplayFailure;
        }
        const physical = input.poll();
        if (remote orelse physical) |event| {
            var previous: ?player_view.BrowserState = browserViewState(browser, attenuation);
            switch (event) {
                .up => browser.move(-1),
                .down => browser.move(1),
                .back => browser.back(),
                .home => return,
                .volume_up => attenuation = if (attenuation > 16) attenuation - 4 else 16,
                .volume_down => attenuation = if (attenuation < 124) attenuation + 4 else 128,
                .select => {
                    previous = null; // Playback/errors can replace the displayed screen.
                    const selected = browser.selectedEntry(volume) catch |failure| {
                        _ = showError("DIRECTORY", failure);
                        waitForErrorDismiss(input);
                        if (usb.needsHandoff()) return;
                        // The error overlay replaced the whole screen.
                        if (!(drawBrowser(volume, browser, battery_mv, attenuation, null) catch |redraw_failure|
                            return redraw_failure)) return error.DisplayFailure;
                        continue;
                    };
                    if (selected) |entry| {
                        if (entry.kind == .directory) {
                            browser.enter(volume, entry) catch |failure| {
                                _ = showError("DIRECTORY", failure);
                                waitForErrorDismiss(input);
                            };
                        } else {
                            playSelection(volume, browser, entry, battery_mv, &attenuation, pmic) catch |failure| {
                                _ = showError("PLAYBACK", failure);
                                waitForErrorDismiss(input);
                            };
                            input.resync();
                        }
                    }
                },
            }
            if (usb.needsHandoff()) return;
            if (!(drawBrowser(volume, browser, battery_mv, attenuation, previous) catch |failure|
                return failure)) return error.DisplayFailure;
        }

        const power_down = input.stable_buttons & board.ButtonId.power.mask() != 0;
        if (power_down) {
            if (power_started == null) power_started = Timer.now();
            if (Timer.elapsed(power_started.?) > Timer.milliseconds(1_500)) powerOff(pmic);
        } else power_started = null;
        Timer.delayMicroseconds(1_000);
    }
}

fn keepAlive() void {
    Watchdog.kick();
}

const ScanUi = struct {
    pmic: *@import("f20_power.zig").Controller,
    last_draw: u32 = 0,
    input: *Input,
    last_input: u32 = 0,
    cancelled: bool = false,

    fn poll(context: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.cancelled) return true;
        Watchdog.kick();
        usb.poll();
        diag.samplePower(self.pmic);
        if (Timer.elapsed(self.last_input) >= Timer.milliseconds(1)) {
            self.last_input = Timer.now();
            if (self.input.poll()) |action| if (action == .back or action == .home) {
                self.cancelled = true;
                return true;
            };
        }
        return usb.needsHandoff() or (options.maintenance and maintenance.pending());
    }

    fn progress(context: *anyopaque, phase: []const u8, stats: @import("library.zig").Stats, covers: u32) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        diag.report.index_parsed = stats.parsed;
        diag.report.index_reused = stats.reused;
        diag.report.index_errors = stats.errors;
        if (Timer.elapsed(self.last_draw) < Timer.milliseconds(100)) return;
        self.last_draw = Timer.now();
        Display.clear(Display.black);
        Display.text(24, 64, "LIBRARY", Display.white, 3);
        Display.text(24, 116, phase, Display.cyan, 1);
        var value: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&value, "{d} TRACKS  {d} COVERS", .{ stats.visited, covers }) catch return;
        Display.text(24, 148, text, Display.white, 1);
        _ = Display.present();
    }
};

fn runIndex(volume: *Volume, pmic: *@import("f20_power.zig").Controller, input: *Input, mode: @import("library.zig").Mode) void {
    var observer = ScanUi{ .pmic = pmic, .input = input };
    ScanUi.progress(&observer, "Finding music", .{}, 0);
    diag.scan(volume, .{ .context = &observer, .poll = ScanUi.poll, .progress = ScanUi.progress }, mode) catch |failure| {
        if (failure != error.Cancelled) diag.failed(2, failure);
    };
    diag.flush();
}

fn selectPath(volume: *Volume, browser: *Browser, path: []const u8) !fat32.DirectoryEntry {
    browser.home();
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        var found: ?fat32.DirectoryEntry = null;
        for (0..browser.counts[browser.depth]) |_| {
            const entry = (try browser.selectedEntry(volume)) orelse break;
            if (std.mem.eql(u8, entry.name(), part)) {
                found = entry;
                break;
            }
            browser.move(1);
        }
        const entry = found orelse return error.NotFound;
        if (parts.peek() == null) return entry;
        try browser.enter(volume, entry);
    }
    return error.NotFound;
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
                    self.state.queue(&catalogue.value.tracks[command.value]);
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
        self.state.refreshBattery(if (diag.report.power_valid & 1 != 0) diag.report.battery_mv else 0, diag.report.power_valid & (1 << 5) != 0, now_ms);
        self.state.frame(self.now());
        if (self.state.failure) return .stop;
        return result;
    }

    fn idlePoll(context: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = control(self, self.state.status);
        @import("f20_display.zig").idleLaunch();
        if (!self.state.isAnimating(self.now())) diag.samplePower(self.pmic);
        return usb.needsHandoff() or self.return_rom or self.power_off or self.reconnect_pending or
            self.state.requested_track != null or self.state.requested_folders;
    }

    fn keepIdleResponsive() void {
        if (idle_music_session) |session| {
            _ = control(session, session.state.status);
            @import("f20_display.zig").idleLaunch();
        }
    }
};

fn browseMusic(volume: *Volume, browser: *Browser, battery_mv: u32, attenuation: *u8, input: *Input, pmic: *@import("f20_power.zig").Controller) !void {
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
    var state = @import("f20_music_ui.zig").State{ .index = &index, .covers = &covers.cache, .text_cache = &text.cache, .attenuation = attenuation.*, .battery_mv = battery_mv, .track_store = @import("track_selection.zig").Store.init(memory.scan_artwork.cachedSlice(u8)) };
    var session = MusicSession{ .state = &state, .input = input, .pmic = pmic };
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
        if (state.requested_folders) {
            state.requested_folders = false;
            index.finish();
            volume.device.keep_alive = keepAlive;
            covers.idle_yield = null;
            try browse(volume, browser, battery_mv, &state.attenuation, input, pmic);
            volume.device.keep_alive = MusicSession.keepIdleResponsive;
            covers.idle_yield = .{ .context = &session, .poll = MusicSession.idlePoll };
            if (diag.catalog) |*catalogue| try index.projection.publish(&catalogue.value, catalogue.value.tracks, volume.serial, true);
            covers.cache.clearRequests();
            input.resync();
            state.navigate(.home);
            continue;
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
            state.screen = .player;
            state.pending_frame.ready = false;
            state.major = true;
            state.dirty = true;
            session.playing = true;
            index.playing = true;
            var measured = player.Report.empty();
            volume.device.keep_alive = null;
            covers.idle_yield = null;
            diag.report.stage = 2;
            const result = player.playFile(&reader, entry.size, volume.device, .{
                .attenuation = state.attenuation,
                .measure_stacks = options.maintenance,
                .report_out = &measured,
                .background = .{ .context = pmic, .poll = playbackPower },
                .storage_work = .{ .context = &index, .run = @import("f20_index.zig").State.run },
            }, .{ .context = &session, .poll = MusicSession.control }) catch |failure| failed: {
                diag.failed(1, failure);
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
            if (result.playback.exit == .next or result.playback.exit == .previous) {
                if (state.neighbouringTrack(if (result.playback.exit == .previous) -1 else 1)) |next| state.queue(next);
            }
            index.finish();
            if (diag.catalog) |*catalogue| try index.projection.publish(&catalogue.value, catalogue.value.tracks, volume.serial, true);
            diag.flush();
            input.resync();
            _ = LcdDma.resetForDirect();
            state.pending_frame.ready = false;
            state.major = true;
            state.dirty = true;
            continue;
        }
        if (index.requested) @import("f20_index.zig").State.run(&index, .{ .context = &session, .poll = MusicSession.idlePoll });
        covers.service(volume);
        text.yield = .{ .context = &session, .poll = MusicSession.idlePoll };
        text.service();
        text.yield = null;
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
            if (diag.catalog) |*catalogue| try index.projection.publish(&catalogue.value, catalogue.value.tracks, volume.serial, true);
        }
        Timer.delayMicroseconds(1000);
    }
}
