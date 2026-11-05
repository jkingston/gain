//! Static USB handoff screen, using the music UI's native typography and chrome.
const draw = @import("canvas.zig");
const chrome = @import("music_chrome.zig");
const battery = @import("battery.zig");

pub const Phase = enum { connecting, connected, ejecting };

pub fn render(c: draw.Canvas, phase: Phase, power: battery.Status) void {
    renderThemed(c, phase, power, .light);
}

pub fn renderThemed(c: draw.Canvas, phase: Phase, power: battery.Status, appearance: chrome.Appearance) void {
    const palette = appearance.palette();
    c.clear(palette.paper);
    chrome.headerThemed(c, switch (phase) {
        .connecting => "Connecting",
        .connected => "Connected",
        .ejecting => "Finishing",
    }, "", power, palette);
    // A restrained USB trident: integer geometry stays crisp at native size.
    const color = palette.accent;
    c.fill(158, 88, 3, 61, color);
    for (0..7) |i| {
        const inset: i32 = @intCast(i);
        c.fill(160 - inset, 84 + inset, @intCast(1 + 2 * i), 1, color);
    }
    c.rounded(153, 146, 13, 13, 6, color);
    c.fill(137, 108, 3, 20, color);
    c.fill(137, 126, 23, 3, color);
    c.rounded(133, 103, 11, 11, 5, color);
    c.fill(179, 100, 3, 16, color);
    c.fill(160, 114, 22, 3, color);
    c.fill(175, 95, 11, 11, color);
    c.centered(16, chrome.Layout.capTop(178, .body), 288, switch (phase) {
        .connecting => "Preparing your SD card",
        .connected => "Add music from your computer",
        .ejecting => "Finishing your transfer",
    }, .body, palette.ink);
    c.fill(16, 216, 288, 1, palette.line);
    c.centered(16, chrome.Layout.capTop(224, .caption), 288, switch (phase) {
        .connecting => "Music will resume after ejecting",
        .connected => "Eject to return to music",
        .ejecting => "Your music will resume shortly",
    }, .caption, palette.muted);
}

test {
    _ = chrome;
}
