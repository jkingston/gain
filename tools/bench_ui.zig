//! Repeatable RAM-only UI performance, snapshot ownership and pixel checks.
//! No SD, NAND or audio operations; concurrent scheduling is qualified separately.
const gain = @import("gain");

const ui = gain.ui;
const view = gain.player_view;
const Display = gain.display;
const x = gain.soc;
const board = gain.hardware.display;
const protocol = @import("ui_bench_report.zig");

const Report = protocol.Report;
const report: *volatile Report = @ptrFromInt(protocol.report_address);
const canvas = Display.framebuffer;
const raw: *[320 * 240 * 3]u8 = @ptrFromInt(0xa0600000);
const scratch: *[320 * 240]u16 = @ptrFromInt(0xa0380000);
const track = view.Track{ .name = "01 - The Production Renderer.FLAC", .artist = "Gain", .album = "Native Zig" };

export fn benchmark_main() callconv(.c) void {
    report.* = .{};
    x.Timer.initialize();
    campaign() catch |failure| {
        report.failure = @intFromError(failure);
        const name = @errorName(failure);
        const count = @min(name.len, report.error_name.len);
        for (0..count) |index| report.error_name[index] = name[index];
    };
    report.completed = 1;
    asm volatile ("sync" ::: .{ .memory = true });
}

fn scene(player: bool, pixels: *[ui.pixel_count]u16) !ui.Ui {
    var result = ui.Ui.init(.{ .pixels = pixels });
    if (player) try view.player(&result, track, .{
        .sample_rate = 192000,
        .total_frames = 192000 * 60,
        .played_frames = 192000 * 20,
        .bits = 24,
    }, 4100, 64, ui.dark_theme) else {
        try view.browser(&result, "MUSIC", false, 4100, 64, ui.dark_theme);
        for (0..6) |row| try view.browserRow(&result, row, track.name, row == 0, row == 2, ui.dark_theme);
    }
    return result;
}

fn present() !void {
    const began = x.Timer.now();
    try Display.prepare(.{ .x = 0, .y = 0, .width = 320, .height = 240 });
    report.prepare_ticks = @max(report.prepare_ticks, x.Timer.elapsed(began));
    const launch = x.Timer.now();
    try Display.commit();
    if (!Display.wait()) return error.DisplayWait;
    report.transfer_ticks = @max(report.transfer_ticks, x.Timer.elapsed(launch));
    report.transfers += 1;
}

fn readback(expected: *[ui.pixel_count]u16) !void {
    // Diagnostic GPIO capture only after the production driver released DMA.
    const began = x.Timer.now();
    while (x.Lcd.mcu_state.read() & x.Lcd.mcu_busy != 0) if (x.Timer.elapsed(began) > 120000) return error.ReadBusy;
    const bytes = [_]u32{ x.Lcd.command_flag | 0x2a, 0, 0, 1, 63, x.Lcd.command_flag | 0x2b, 0, 0, 0, 239, x.Lcd.command_flag | 0x2e };
    for (bytes) |value| {
        while (x.Lcd.mcu_state.read() & x.Lcd.mcu_busy != 0) {}
        x.Lcd.mcu_data.write(value);
    }
    while (x.Lcd.mcu_state.read() & x.Lcd.mcu_busy != 0) {}
    const wr = x.Gpio.Pin{ .port = .b, .index = 17 };
    const dc = x.Gpio.Pin{ .port = .b, .index = 20 };
    wr.output(true);
    dc.output(true);
    inline for (0..8) |pin| (x.Gpio.Pin{ .port = .a, .index = pin }).input();
    defer {
        board.read_strobe.set(true);
        x.Gpio.selectFunction1(.a, 0xff);
        x.Gpio.selectFunction1(.b, wr.mask() | dc.mask());
    }
    x.Timer.delayMicroseconds(2);
    _ = readPins();
    for (raw) |*b| b.* = readPins();
    for (expected, 0..) |want, index| {
        const got = (@as(u16, raw[index * 3] >> 3) << 11) | (@as(u16, raw[index * 3 + 1] >> 2) << 5) | (raw[index * 3 + 2] >> 3);
        if (got != want) {
            if (report.mismatches == 0) {
                report.first_bad = @intCast(index);
                report.expected = want;
                report.actual = got;
            }
            report.mismatches += 1;
        }
    }
    report.checked_pixels += ui.pixel_count;
    if (report.mismatches != 0) return error.PanelMismatch;
}

fn readPins() u8 {
    board.read_strobe.set(false);
    x.Timer.delayMicroseconds(1);
    const value: u8 = @truncate(x.Register32(0xb0010000).read());
    board.read_strobe.set(true);
    x.Timer.delayMicroseconds(1);
    return value;
}

fn campaign() !void {
    report.stage = 1;
    try Display.initialize();
    const build_begin = x.Timer.now();
    const browser = try scene(false, canvas);
    const player = try scene(true, canvas);
    report.build_ticks = x.Timer.elapsed(build_begin);
    report.stage = 2;
    var began = x.Timer.now();
    browser.render(.{ .pixels = canvas });
    report.render_ticks = x.Timer.elapsed(began);
    try present();
    try readback(canvas);
    // Full frame snapshot must stay frozen while its logical canvas changes.
    report.stage = 3;
    player.render(.{ .pixels = canvas });
    @memcpy(scratch, canvas);
    try Display.prepare(.{ .x = 0, .y = 0, .width = 320, .height = 240 });
    @memset(canvas, 0xf800);
    try Display.commit();
    if (!Display.wait()) return error.DisplayWait;
    report.transfers += 1;
    try readback(scratch);
    report.stage = 4;
    for (0..2) |direction| for (0..17) |frame| {
        const offset: u16 = @intCast(frame * 20);
        began = x.Timer.now();
        if (direction == 0) ui.slide(&browser, &player, canvas, offset) else ui.slide(&player, &browser, canvas, offset);
        report.slide_ticks = @max(report.slide_ticks, x.Timer.elapsed(began));
        try present();
    };
    try readback(canvas);
    report.stage = 5;
    player.render(.{ .pixels = canvas });
    try present();
    for (0..160) |index| {
        var update = ui.Ui.init(.{ .pixels = canvas });
        const progress = index % 4 == 0;
        began = x.Timer.now();
        if (progress) try view.progress(&update, .{
            .sample_rate = 192000,
            .total_frames = 192000 * 60,
            .played_frames = index * 192000 / 3,
            .bits = 24,
        }, ui.dark_theme) else try view.volume(&update, @intCast(16 + (index % 29) * 4), ui.dark_theme);
        update.finish();
        const render_ticks = x.Timer.elapsed(began);
        report.region_render_ticks = @max(report.region_render_ticks, render_ticks);
        const region = if (progress) view.progress_region else view.volume_region;
        const preparation = x.Timer.now();
        if (!Display.start(region.x, region.y, region.width, region.height)) return error.RegionWait;
        const preparation_ticks = x.Timer.elapsed(preparation);
        report.region_prepare_ticks = @max(report.region_prepare_ticks, preparation_ticks);
        report.region_job_ticks = @max(report.region_job_ticks, render_ticks + preparation_ticks);
        if (!Display.wait()) return error.RegionWait;
        report.transfers += 1;
    }
    try readback(canvas);
    report.stage = 6;
    for ([_]@import("gain").display.Region{ .{
        .x = 319,
        .y = 1,
        .width = 1,
        .height = 23,
    }, .{ .x = 1, .y = 109, .width = 43, .height = 23 }, .{ .x = 0, .y = 239, .width = 319, .height = 1 } }) |region| {
        (ui.Surface{ .pixels = canvas }).fill(.{ .x = region.x, .y = region.y, .width = region.width, .height = region.height }, 0x07e0);
        if (!Display.start(region.x, region.y, region.width, region.height) or !Display.wait()) return error.EdgeWait;
        report.transfers += 1;
    }
    try readback(canvas);
    report.stage = 7;
    var selected: usize = 0;
    browser.render(.{ .pixels = canvas });
    // The fixture browser initially selected row 2.
    selected = 2;
    try present();
    for (0..view.visible_rows) |_| {
        const next = (selected + 1) % view.visible_rows;
        var declaration = ui.Ui.init(.{ .pixels = canvas });
        try view.browser(&declaration, "MUSIC", false, 4100, 64, ui.dark_theme);
        for (0..view.visible_rows) |row| try view.browserRow(&declaration, row, track.name, row == 0, row == next, ui.dark_theme);
        declaration.finish();
        const damage = view.browserDamage(.{
            .directory = 2,
            .first = 0,
            .selected = selected,
            .attenuation = 64,
        }, .{ .directory = 2, .first = 0, .selected = next, .attenuation = 64 });
        if (damage.full or damage.count != 2) return error.SelectionDamage;
        for (damage.regions[0..damage.count]) |region| {
            if (!Display.start(region.x, region.y, region.width, region.height) or !Display.wait()) return error.SelectionWait;
            report.transfers += 1;
        }
        try readback(canvas);
        selected = next;
    }
    report.stage = protocol.final_stage;
}
