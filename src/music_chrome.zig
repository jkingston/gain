//! Cohesive music-screen geometry, palette and header rendering.
const draw = @import("canvas.zig");
const battery = @import("battery.zig");

pub const paper = draw.rgb(247, 247, 242);
pub const ink = draw.rgb(31, 42, 44);
pub const muted = draw.rgb(102, 114, 113);
pub const line = draw.rgb(217, 222, 216);
pub const accent = draw.rgb(35, 101, 91);
pub const selected = draw.rgb(226, 234, 225);

pub const Layout = struct {
    pub const left = 16;
    pub const right = 304;
    pub const width = right - left;
    pub const row_top = 64;
    pub const row_height = 32;
    pub const footer_top = 216;
    pub const timeline_top = 192;
    pub const header_center = 25;
    pub const battery_width = 28;
    pub const battery_height = 12;
    pub const battery_left = right - battery_width - 2;
    pub const battery_top = header_center - battery_height / 2;
    pub const power_badge_left = right - 44;
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
    const detail_right = Layout.detail_right;
    const title_right: i32 = if (detail.len == 0) detail_right else detail_right - @as(i32, draw.textWidth(detail, .caption)) - 12;
    c.ellipsis(Layout.left, Layout.headerText(.serif), @intCast(@max(0, title_right - Layout.left)), title, .serif, ink);
    c.right(detail_right, Layout.headerText(.caption), detail, .caption, muted);
    c.fill(Layout.left, Layout.header_rule_top, Layout.width, 1, line);
    batteryIcon(c, status);
}

pub fn batteryIcon(c: draw.Canvas, status: battery.Status) void {
    const left = Layout.battery_left;
    const top = Layout.battery_top;
    const color = if (status.kind == .low or status.kind == .empty) draw.rgb(174, 65, 47) else accent;
    // Own the entire fixed slot so removing a power badge leaves no stale pixels.
    c.fill(Layout.power_badge_left, top, Layout.right - Layout.power_badge_left, Layout.battery_height, paper);
    c.fill(left, top, Layout.battery_width, Layout.battery_height, muted);
    c.pixel(left, top, paper);
    c.pixel(left + Layout.battery_width - 1, top, paper);
    c.pixel(left, top + Layout.battery_height - 1, paper);
    c.pixel(left + Layout.battery_width - 1, top + Layout.battery_height - 1, paper);
    c.fill(left + 1, top + 1, Layout.battery_width - 2, Layout.battery_height - 2, paper);
    c.fill(Layout.right - 2, top + 4, 2, 4, muted);
    const fill_width = Layout.battery_width - 4;
    const fill_height = Layout.battery_height - 4;
    if (status.kind == .unknown) {
        c.fill(left + Layout.battery_width / 2 - 2, top + Layout.battery_height / 2 - 1, 5, 2, muted);
    } else if (status.level > 0) {
        const width: u16 = @as(u16, @min(status.level, 4)) * fill_width / 4;
        c.fill(left + 2, top + 2, width, fill_height, color);
    } else {
        c.fill(left + 2, top + 2, 1, fill_height, color);
    }
    const badge_left = Layout.power_badge_left;
    if (status.badge() == .charging) {
        // The bolt has its own fixed space; neither icon nor title shifts.
        const offsets = [_]u8{ 6, 5, 4, 3, 2, 1, 4, 4, 3, 2, 2, 1 };
        const widths = [_]u8{ 2, 2, 2, 2, 6, 7, 3, 2, 2, 2, 1, 1 };
        for (offsets, widths, 0..) |offset, width, row| c.fill(badge_left + 1 + @as(i32, offset), top + @as(i32, @intCast(row)), width, 1, accent);
    } else if (status.badge() == .plugged) {
        c.fill(badge_left + 2, top, 2, 3, accent);
        c.fill(badge_left + 6, top, 2, 3, accent);
        c.fill(badge_left + 1, top + 3, 8, 4, accent);
        c.fill(badge_left + 2, top + 7, 6, 1, accent);
        c.fill(badge_left + 3, top + 8, 4, 1, accent);
        c.fill(badge_left + 4, top + 9, 2, 3, accent);
    }
}

test "full battery fills its entire inset and unknown cannot resemble empty" {
    const std = @import("std");
    const ui = @import("ui.zig");
    var pixels: [ui.pixel_count]u16 = undefined;
    const c = draw.Canvas.init(&pixels);
    c.clear(paper);
    batteryIcon(c, battery.Status.fromVoltage(4200, false));
    for (21..29) |y| for (276..300) |x| try std.testing.expectEqual(accent, pixels[y * 320 + x]);
    c.clear(paper);
    batteryIcon(c, battery.Status.fromVoltage(0, false));
    try std.testing.expectEqual(muted, pixels[24 * 320 + 286]);
    try std.testing.expectEqual(paper, pixels[21 * 320 + 276]);
    c.clear(paper);
    batteryIcon(c, battery.Status.fromVoltage(3300, false));
    try std.testing.expect(pixels[21 * 320 + 276] != paper);
    try std.testing.expectEqual(paper, pixels[24 * 320 + 286]);
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
