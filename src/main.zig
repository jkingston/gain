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
        surface.text(.{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(width -| x), .height = @intCast(height -| y) }, value, .{ .color = color, .scale = @intCast(scale) });
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

const UiEvent = enum {
    select,
    back,
    home,
    up,
    down,
    volume_up,
    volume_down,
};

const Input = struct {
    raw_buttons: u8 = 0,
    stable_buttons: u8 = 0,
    stable_samples: u3 = 0,
    old_wheel: u2,
    wheel_accumulator: i8 = 0,

    fn init() Input {
        for (board.buttons) |button| button.pin.input();
        board.wheel.phase_a.input();
        board.wheel.phase_b.input();
        return .{ .old_wheel = wheelState() };
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
    }
};

const PlaybackUi = struct {
    browser: *const Browser,
    entry: *const fat32.DirectoryEntry,
    battery_mv: u32,
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
    if (usb.needsHandoff()) return .stop;
    const state: *PlaybackUi = @ptrCast(@alignCast(context));
    return state.screen.poll(LcdDma, buttonState(), playbackTrack(state), state.battery_mv, view_theme, status);
}

const isVisibleEntry = @import("file_browser.zig").isVisibleEntry;

const view_theme = ui.dark_theme;
fn clippedName(name: []const u8, maximum: usize) []const u8 {
    return name[0..@min(name.len, maximum)];
}

fn drawBrowser(volume: *Volume, browser: *const Browser, battery_mv: u32, attenuation: u8, previous: ?player_view.BrowserState) !bool {
    var scene = ui.Ui.init(Display.surface);
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
    return .{ .directory = browser.directory().first_cluster, .first = if (selected >= visible_rows) selected - (visible_rows - 1) else 0, .selected = selected, .attenuation = attenuation };
}

fn playbackTrack(state: *const PlaybackUi) player_view.Track {
    const artist_depth = if (state.browser.depth > 1) state.browser.depth - 1 else state.browser.depth;
    const artist = state.browser.titles[artist_depth][0..state.browser.title_lengths[artist_depth]];
    return .{ .name = state.entry.name(), .artist = if (state.browser.depth > 0) artist else "", .album = if (state.browser.depth > 0) state.browser.title() else "" };
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
        if (input.poll()) |event| {
            if (event == .back or event == .select or event == .home) return;
        }
        Timer.delayMicroseconds(1_000);
    }
}

fn playEntry(
    volume: *Volume,
    browser: *const Browser,
    entry: fat32.DirectoryEntry,
    battery_mv: u32,
    attenuation: u8,
) !media.Result {
    var file_reader = try volume.reader(try entry.file());
    var playback_ui = PlaybackUi{
        .browser = browser,
        .entry = &entry,
        .battery_mv = battery_mv,
        .screen = @import("player_screen.zig").State.init(attenuation),
    };
    defer _ = LcdDma.resetForDirect();
    const result = try player.playFile(
        &file_reader,
        entry.size,
        volume.device,
        .{ .descriptor_count = 120, .buffer_count = 3, .attenuation = attenuation },
        .{ .context = &playback_ui, .poll = playbackPoll },
    );
    if (playback_ui.screen.failed) return error.DisplayFailure;
    return result.playback;
}

fn playSelection(
    volume: *Volume,
    browser: *Browser,
    first_entry: fat32.DirectoryEntry,
    battery_mv: u32,
    attenuation: *u8,
) !void {
    var entry = first_entry;
    while (true) {
        const result = try playEntry(volume, browser, entry, battery_mv, attenuation.*);
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
    if (!Display.init()) rawPanicBlink();
    display_ready = true;
    Watchdog.start(.external, .by_1024, board.watchdog_timeout_ticks);
    Watchdog.kick();

    var input = Input.init();
    var pmic = @import("f20_power.zig").initialize() catch |failure| fatalError("POWER", failure);
    // A failed/disabled ADC is unknown, never a fabricated empty battery.
    const telemetry = pmic.telemetry() catch null;
    const battery_mv: u32 = if (telemetry) |value| value.battery_mv orelse 0 else 0;

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
        // Recreate the controller, FAT cache and browser after every ownership
        // change. Host edits may have replaced directories and cluster chains.
        card = storage.Controller.initialize(resources) catch |failure| {
            card.capacity_sectors = 0;
            if (usb.needsRemount()) usb.remounted();
            _ = showError("SD CARD", failure);
            waitForErrorDismiss(&input);
            if (usb.needsHandoff()) runUsbMode();
            continue;
        };
        if (usb.needsRemount()) usb.remounted();
        var volume = Volume.mount(&card, sd_scratch) catch |failure| {
            _ = showError("FILESYSTEM", failure);
            waitForErrorDismiss(&input);
            if (usb.needsHandoff()) runUsbMode();
            continue;
        };
        var browser = Browser.init(&volume) catch |failure| {
            _ = showError("DIRECTORY", failure);
            waitForErrorDismiss(&input);
            if (usb.needsHandoff()) runUsbMode();
            continue;
        };
        if (bookmark) |saved| browser.restore(&volume, saved) catch {};
        browse(&volume, &browser, battery_mv, &attenuation, &input, &pmic) catch |failure| {
            _ = showError("DIRECTORY", failure);
            waitForErrorDismiss(&input);
        };
        // playFile has joined every task before browse returns. No decoder,
        // SD prefetch, FAT reader or audio callback can now touch the card.
        bookmark = browser.bookmark(&volume) catch null;
        if (usb.needsHandoff()) runUsbMode();
        input.resync();
    }
}

fn runUsbMode() void {
    Display.clear(Display.black);
    Display.text(32, 68, "USB CONNECTED", Display.white, 3);
    Display.text(32, 124, "EJECT ON COMPUTER TO RETURN", Display.cyan, 1);
    _ = Display.present();
    while (true) {
        Watchdog.kick();
        usb.poll();
        switch (usb.session().state) {
            .quiescing => usb.grantHost() catch {},
            .host, .ejecting => {},
            .remounting, .player, .ejected => return,
        }
        Timer.delayMicroseconds(100);
    }
}

fn browse(volume: *Volume, browser: *Browser, battery_mv: u32, attenuation_ptr: *u8, input: *Input, pmic: *@import("f20_power.zig").Controller) !void {
    var attenuation = attenuation_ptr.*;
    defer attenuation_ptr.* = attenuation;
    var power_started: ?u32 = null;
    if (!(drawBrowser(volume, browser, battery_mv, attenuation, null) catch |failure| return failure)) return error.DisplayFailure;
    while (true) {
        Watchdog.kick();
        usb.poll();
        if (usb.needsHandoff()) return;
        if (input.poll()) |event| {
            var previous: ?player_view.BrowserState = browserViewState(browser, attenuation);
            switch (event) {
                .up => browser.move(-1),
                .down => browser.move(1),
                .back => browser.back(),
                .home => browser.home(),
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
                            playSelection(volume, browser, entry, battery_mv, &attenuation) catch |failure| {
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
