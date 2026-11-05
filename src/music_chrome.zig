//! Cohesive music-screen geometry, palette and header rendering.
const draw = @import("canvas.zig");
const battery = @import("battery.zig");

pub const Palette = struct {
    paper: draw.Color,
    ink: draw.Color,
    muted: draw.Color,
    line: draw.Color,
    accent: draw.Color,
    selected: draw.Color,
};

pub const Appearance = enum {
    light,
    dark,

    pub fn palette(self: Appearance) Palette {
        return switch (self) {
            .light => light,
            .dark => dark,
        };
    }
};

pub const light = Palette{
    .paper = draw.rgb(247, 247, 242),
    .ink = draw.rgb(31, 42, 44),
    .muted = draw.rgb(102, 114, 113),
    .line = draw.rgb(217, 222, 216),
    .accent = draw.rgb(35, 101, 91),
    .selected = draw.rgb(226, 234, 225),
};
pub const dark = Palette{
    .paper = draw.rgb(22, 28, 29),
    .ink = draw.rgb(235, 239, 232),
    .muted = draw.rgb(159, 176, 172),
    .line = draw.rgb(60, 74, 71),
    .accent = draw.rgb(142, 207, 184),
    .selected = draw.rgb(43, 65, 59),
};
// Compatibility for static callers; live controllers carry their own palette.
pub const paper = light.paper;
pub const ink = light.ink;
pub const muted = light.muted;
pub const line = light.line;
pub const accent = light.accent;
pub const selected = light.selected;

pub const Layout = struct {
    pub const left = 16;
    pub const right = 304;
    pub const width = right - left;
    pub const row_top = 64;
    pub const row_height = 32;
    pub const footer_top = 216;
    pub const timeline_top = 192;
    pub const header_center = 25;
    pub const battery_width = 24;
    pub const battery_height = 14;
    pub const battery_left = right - battery_width - 2;
    pub const battery_top = header_center - battery_height / 2;
    pub const power_badge_height = 12;
    pub const power_badge_left = right - 40;
    pub const detail_right = right - 48;
    pub const header_rule_top = 54;
    pub const scan_indicator_left = right - 3;

    // The atlas includes transparent line padding. Align visible capitals,
    // rather than centring those differently sized bitmap containers.
    pub fn capTop(top: i32, role: draw.fonts.Role) i32 {
        return top - draw.fonts.glyph(role, 'H').ink_y;
    }

    pub fn capBottom(bottom: i32, role: draw.fonts.Role) i32 {
        const glyph = draw.fonts.glyph(role, 'H');
        return bottom - glyph.ink_y - glyph.ink_height;
    }

    pub fn headerText(role: draw.fonts.Role) i32 {
        return capTop(header_center - @divTrunc(@as(i32, draw.fonts.glyph(role, 'H').ink_height), 2), role);
    }

    pub fn rowText(top: i32, role: draw.fonts.Role) i32 {
        return capTop(top + @divTrunc(row_height - @as(i32, draw.fonts.glyph(role, 'H').ink_height), 2), role);
    }
};

pub fn header(c: draw.Canvas, title: []const u8, detail: []const u8, status: battery.Status) void {
    headerThemed(c, title, detail, status, light);
}

pub fn headerThemed(c: draw.Canvas, title: []const u8, detail: []const u8, status: battery.Status, palette: Palette) void {
    const detail_right = Layout.detail_right;
    const title_right: i32 = if (detail.len == 0) detail_right else detail_right - @as(i32, draw.textWidth(detail, .caption)) - 12;
    c.ellipsis(Layout.left, Layout.headerText(.serif), @intCast(@max(0, title_right - Layout.left)), title, .serif, palette.ink);
    c.right(detail_right, Layout.headerText(.caption), detail, .caption, palette.muted);
    c.fill(Layout.left, Layout.header_rule_top, Layout.width, 1, palette.line);
    batteryIconThemed(c, status, palette);
}

pub fn batteryIcon(c: draw.Canvas, status: battery.Status) void {
    batteryIconThemed(c, status, light);
}

pub fn batteryIconThemed(c: draw.Canvas, status: battery.Status, palette: Palette) void {
    const left = Layout.battery_left;
    const top = Layout.battery_top;
    const color = if (status.kind == .low or status.kind == .empty) draw.rgb(174, 65, 47) else palette.accent;
    // Own the entire fixed slot so removing a power badge leaves no stale pixels.
    c.fill(Layout.power_badge_left, top, Layout.right - Layout.power_badge_left, Layout.battery_height, palette.paper);
    c.fill(left, top, Layout.battery_width, Layout.battery_height, palette.muted);
    c.pixel(left, top, palette.paper);
    c.pixel(left + Layout.battery_width - 1, top, palette.paper);
    c.pixel(left, top + Layout.battery_height - 1, palette.paper);
    c.pixel(left + Layout.battery_width - 1, top + Layout.battery_height - 1, palette.paper);
    c.fill(left + 1, top + 1, Layout.battery_width - 2, Layout.battery_height - 2, palette.paper);
    c.fill(Layout.right - 2, top + (Layout.battery_height - 4) / 2, 2, 4, palette.muted);
    const fill_width = Layout.battery_width - 4;
    const fill_height = Layout.battery_height - 4;
    if (status.kind == .unknown) {
        c.fill(left + Layout.battery_width / 2 - 2, top + Layout.battery_height / 2 - 1, 5, 2, palette.muted);
    } else if (status.level > 0) {
        const width: u16 = @as(u16, @min(status.level, 4)) * fill_width / 4;
        c.fill(left + 2, top + 2, width, fill_height, color);
    } else {
        c.fill(left + 2, top + 2, 1, fill_height, color);
    }
    const badge_left = Layout.power_badge_left;
    const badge_top = top + (Layout.battery_height - Layout.power_badge_height) / 2;
    if (status.badge() == .charging) {
        // The bolt has its own fixed space; neither icon nor title shifts.
        const offsets = [_]u8{ 6, 5, 4, 3, 2, 1, 4, 4, 3, 2, 2, 1 };
        const widths = [_]u8{ 2, 2, 2, 2, 6, 7, 3, 2, 2, 2, 1, 1 };
        for (offsets, widths, 0..) |offset, width, row| c.fill(badge_left + 1 + @as(i32, offset), badge_top + @as(i32, @intCast(row)), width, 1, palette.accent);
    } else if (status.badge() == .plugged) {
        c.fill(badge_left + 2, badge_top, 2, 3, palette.accent);
        c.fill(badge_left + 6, badge_top, 2, 3, palette.accent);
        c.fill(badge_left + 1, badge_top + 3, 8, 4, palette.accent);
        c.fill(badge_left + 2, badge_top + 7, 6, 1, palette.accent);
        c.fill(badge_left + 3, badge_top + 8, 4, 1, palette.accent);
        c.fill(badge_left + 4, badge_top + 9, 2, 3, palette.accent);
    }
}

test "full battery fills its entire inset and unknown cannot resemble empty" {
    const std = @import("std");
    const ui = @import("ui.zig");
    var pixels: [ui.pixel_count]u16 = undefined;
    const c = draw.Canvas.init(&pixels);
    c.clear(paper);
    batteryIcon(c, battery.Status.fromVoltage(4200, false));
    for (20..30) |y| for (280..300) |x| try std.testing.expectEqual(accent, pixels[y * 320 + x]);
    c.clear(paper);
    batteryIcon(c, battery.Status.fromVoltage(0, false));
    try std.testing.expectEqual(muted, pixels[24 * 320 + 288]);
    try std.testing.expectEqual(paper, pixels[20 * 320 + 280]);
    c.clear(paper);
    batteryIcon(c, battery.Status.fromVoltage(3300, false));
    try std.testing.expect(pixels[20 * 320 + 280] != paper);
    try std.testing.expectEqual(paper, pixels[24 * 320 + 288]);
}

test "power transitions preserve capacity, erase old badges and stay inside the header slot" {
    const std = @import("std");
    const ui = @import("ui.zig");
    const untouched = draw.rgb(255, 0, 255);
    var retained: [ui.pixel_count]u16 = undefined;
    var fresh: [ui.pixel_count]u16 = undefined;
    var unplugged: [ui.pixel_count]u16 = undefined;
    const c = draw.Canvas.init(&retained);
    c.clear(untouched);
    for ([_]u32{ 0, 3300, 3600, 3800, 4000, 4200 }) |millivolts| {
        const reference = draw.Canvas.init(&unplugged);
        reference.clear(untouched);
        batteryIcon(reference, battery.Status.fromPower(millivolts, false, false));
        for ([_]battery.Badge{ .charging, .plugged, .none }) |badge| {
            const status = battery.Status.fromPower(millivolts, badge == .charging, badge != .none);
            batteryIcon(c, status);
            const expected = draw.Canvas.init(&fresh);
            expected.clear(untouched);
            batteryIcon(expected, status);
            try std.testing.expectEqualSlices(u16, &fresh, &retained);
            for (retained, 0..) |pixel, index| {
                const x = index % ui.screen_width;
                const y = index / ui.screen_width;
                const in_slot = x >= Layout.power_badge_left and x < Layout.right and y >= Layout.battery_top and y < Layout.battery_top + Layout.battery_height;
                if (!in_slot) try std.testing.expectEqual(untouched, pixel);
                if (x >= Layout.battery_left) try std.testing.expectEqual(unplugged[index], pixel);
            }
        }
    }
}
