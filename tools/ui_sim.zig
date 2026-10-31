//! UI development adapter: fixture media, shared production views, no audio.
const std = @import("std");
const ui = @import("gain_ui").ui;
const view = @import("gain_ui").player_view;
extern fn getenv([*:0]const u8) ?[*:0]const u8;
const desktop = @import("sdl_bridge.zig");
const names = [_][]const u8{ "01 - First Light.FLAC", "02 - Open Water.FLAC", "03 - Evening.FLAC", "04 - A Longer Track Title.FLAC", "05 - Quiet.FLAC", "06 - Home.FLAC" };
pub fn main() !void {
    var window = try desktop.Window.init("gain UI", 320, 240, 3);
    defer window.deinit();
    std.debug.print("gain UI: Up/Down select, Enter play, Esc back, +/- volume, T theme. Fixture media; no audio.\n", .{});
    var pixels: [ui.pixel_count]u16 = undefined;
    var old = ui.Ui.init(.{ .pixels = &pixels });
    var scene = ui.Ui.init(.{ .pixels = &pixels });
    var selected: usize = 0;
    var playing = false;
    var attenuation: u8 = 64;
    var light = false;
    var changed = true;
    var transition: ?u64 = null;
    var started = desktop.nowMilliseconds();
    var previous_second: u64 = 0;
    const smoke = getenv("GAIN_UI_SMOKE") != null;
    var iteration: u32 = 0;
    while (true) {
        const now = desktop.nowMilliseconds();
        var scripted: desktop.Event = if (smoke) switch (iteration) {
            2 => .play,
            40 => .volume_up,
            80 => .back,
            120 => .theme,
            160 => .quit,
            else => .none,
        } else .none;
        while (true) {
            const event = if (scripted != .none) value: {
                const value = scripted;
                scripted = .none;
                break :value value;
            } else window.poll();
            if (event == .none) break;
            if (event == .quit) return;
            const previous = playing;
            switch (event) {
                .play => {
                    playing = true;
                    started = now;
                },
                .back => playing = false,
                .wheel_up => selected = (selected + names.len - 1) % names.len,
                .wheel_down => selected = (selected + 1) % names.len,
                .volume_up => attenuation = attenuation -| 4,
                .volume_down => attenuation = @min(128, attenuation +| 4),
                .theme => light = !light,
                else => {},
            }
            attenuation = @max(16, attenuation);
            if (previous != playing) {
                old = scene;
                transition = now;
            }
            changed = true;
        }
        const second = if (playing) (now - started) / 1000 else 0;
        changed = changed or second != previous_second;
        previous_second = second;
        if (changed) {
            scene = ui.Ui.init(.{ .pixels = &pixels });
            const theme = if (light) ui.light_theme else ui.dark_theme;
            if (playing) {
                try view.player(&scene, .{ .name = names[selected], .artist = "Artist", .album = "Album" }, .{ .sample_rate = 192000, .total_frames = 192000 * 240, .played_frames = @as(u64, @min(second, 240)) * 192000, .bits = 24 }, 4100, attenuation, theme);
            } else {
                try view.browser(&scene, "MUSIC", false, 4100, attenuation, theme);
                for (names, 0..) |name, row| try view.browserRow(&scene, row, name, false, row == selected, theme);
            }
            changed = false;
        }
        if (transition) |at| {
            const offset = @min(320, (now - at) * 320 / 250);
            ui.slide(&old, &scene, &pixels, @intCast(offset));
            if (offset == 320) transition = null;
        } else scene.render(.{ .pixels = &pixels });
        try window.present(&pixels, 640);
        if (smoke) switch (iteration) {
            1 => try desktop.saveBitmap("/tmp/gain-ui-browser.bmp", &pixels, 320, 240, 640),
            39 => try desktop.saveBitmap("/tmp/gain-ui-player.bmp", &pixels, 320, 240, 640),
            159 => try desktop.saveBitmap("/tmp/gain-ui-light.bmp", &pixels, 320, 240, 640),
            else => {},
        };
        iteration += 1;
        desktop.delayMilliseconds(8);
    }
}
