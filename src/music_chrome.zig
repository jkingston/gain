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
    pub const battery_top = header_center - 5;
    pub const detail_right = right - 48;
    pub const scan_indicator_left = right - 43;

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
    c.fill(Layout.left, 54, Layout.width, 1, line);
    batteryIcon(c, status);
}

pub fn batteryIcon(c: draw.Canvas, status: battery.Status) void {
    const left = Layout.right - 24;
    const top = Layout.battery_top;
    const color = if (status.kind == .low or status.kind == .empty) draw.rgb(174, 65, 47) else accent;
    c.fill(left, top, 21, 10, muted);
    c.fill(left + 1, top + 1, 19, 8, paper);
    c.fill(Layout.right - 2, top + 3, 2, 4, muted);
    if (status.kind == .unknown) {
        c.fill(left + 8, top + 4, 5, 2, muted);
    } else if (status.level > 0) {
        const width: u16 = if (status.level == 4) 17 else @as(u16, status.level) * 4;
        c.fill(left + 2, top + 2, width, 6, color);
    } else {
        c.fill(left + 2, top + 2, 1, 6, color);
    }
    if (status.charging) {
        // The bolt has its own fixed space; neither icon nor title shifts.
        const offsets = [_]u8{ 4, 3, 2, 1, 0, 3, 2, 2, 1, 1 };
        const widths = [_]u8{ 2, 2, 3, 4, 6, 3, 3, 2, 2, 1 };
        for (offsets, widths, 0..) |offset, width, row| c.fill(left - 10 + @as(i32, offset), top + @as(i32, @intCast(row)), width, 1, accent);
    }
}

test "full battery fills its entire inset and unknown cannot resemble empty" {
    const std = @import("std");
    const ui = @import("ui.zig");
    var pixels: [ui.pixel_count]u16 = undefined;
    const c = draw.Canvas.init(&pixels);
    c.clear(paper);
    batteryIcon(c, battery.Status.fromVoltage(4200, false));
    for (22..28) |y| for (282..299) |x| try std.testing.expectEqual(accent, pixels[y * 320 + x]);
    c.clear(paper);
    batteryIcon(c, battery.Status.fromVoltage(0, false));
    try std.testing.expectEqual(muted, pixels[24 * 320 + 288]);
    try std.testing.expectEqual(paper, pixels[22 * 320 + 282]);
    c.clear(paper);
    batteryIcon(c, battery.Status.fromVoltage(3300, false));
    try std.testing.expect(pixels[22 * 320 + 282] != paper);
    try std.testing.expectEqual(paper, pixels[24 * 320 + 288]);
}
