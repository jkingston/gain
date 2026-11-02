const std = @import("std");

pub const screen_width: u16 = 320;
pub const screen_height: u16 = 240;
pub const pixel_count = @as(usize, screen_width) * screen_height;
pub const maximum_commands = 192;
pub const maximum_text_bytes = 4_096;

pub const Color = u16;

pub fn rgb(red: u8, green: u8, blue: u8) Color {
    return (@as(u16, red >> 3) << 11) |
        (@as(u16, green >> 2) << 5) |
        (blue >> 3);
}

pub const Rect = extern struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,

    pub fn inset(self: Rect, amount: u16) Rect {
        const twice = amount *| 2;
        return .{
            .x = self.x +| @as(i32, amount),
            .y = self.y +| @as(i32, amount),
            .width = self.width -| twice,
            .height = self.height -| twice,
        };
    }
};

pub const Align = enum { start, center, end };

pub const TextStyle = struct {
    color: Color,
    scale: u2 = 1,
    alignment: Align = .start,
};

pub const Theme = struct {
    background: Color,
    surface: Color,
    surface_raised: Color,
    text: Color,
    muted: Color,
    accent: Color,
    accent_text: Color,
    danger: Color,
    spacing: u8 = 6,
    padding: u8 = 10,
};

pub const dark_theme = Theme{
    .background = rgb(5, 12, 8),
    .surface = rgb(16, 29, 20),
    .surface_raised = rgb(27, 45, 33),
    .text = rgb(236, 246, 239),
    .muted = rgb(139, 163, 146),
    .accent = rgb(112, 244, 151),
    .accent_text = rgb(4, 17, 8),
    .danger = rgb(255, 105, 105),
};

pub const light_theme = Theme{
    .background = rgb(235, 239, 235),
    .surface = rgb(216, 226, 218),
    .surface_raised = rgb(198, 214, 202),
    .text = rgb(20, 31, 23),
    .muted = rgb(78, 99, 84),
    .accent = rgb(18, 104, 49),
    .accent_text = rgb(245, 255, 248),
    .danger = rgb(166, 30, 30),
};

pub const Surface = struct {
    pixels: *[pixel_count]Color,
    clip: Rect = .{ .x = 0, .y = 0, .width = screen_width, .height = screen_height },

    pub fn clear(self: Surface, color: Color) void {
        @memset(self.pixels, color);
    }

    pub fn fill(self: Surface, rect: Rect, color: Color) void {
        const right = @as(i32, rect.x) +| rect.width;
        const bottom = @as(i32, rect.y) +| rect.height;
        if (right <= 0 or bottom <= 0 or rect.x >= screen_width or rect.y >= screen_height) return;
        const x0: usize = @intCast(@max(@max(rect.x, self.clip.x), 0));
        const y0: usize = @intCast(@max(@max(rect.y, self.clip.y), 0));
        const x1: usize = @intCast(@max(0, @min(@min(@as(i32, screen_width), @as(i32, self.clip.x) +| self.clip.width), right)));
        const y1: usize = @intCast(@max(0, @min(@min(@as(i32, screen_height), @as(i32, self.clip.y) +| self.clip.height), bottom)));
        if (x0 >= x1 or y0 >= y1) return;
        var y = y0;
        while (y < y1) : (y += 1) {
            @memset(self.pixels[y * screen_width + x0 .. y * screen_width + x1], color);
        }
    }

    pub fn text(self: Surface, rect: Rect, value: []const u8, style: TextStyle) void {
        if (style.scale == 0) return;
        const width = textWidth(value, style.scale);
        var clipped = self;
        clipped.clip = intersection(self.clip, rect);
        const origin_x: i32 = switch (style.alignment) {
            .start => rect.x,
            .center => rect.x +| @as(i32, (rect.width -| width) / 2),
            .end => rect.x +| @as(i32, rect.width -| width),
        };

        var x = origin_x;
        for (value) |character| {
            if (x >= @min(@as(i32, screen_width), rect.x +| rect.width)) break;
            drawGlyph(clipped, x, rect.y, character, style.color, style.scale);
            x += @intCast(6 * @as(u16, style.scale));
        }
    }
};

pub const VisibleRange = struct { first: usize, count: usize };

pub fn visibleRange(item_count: usize, selected: usize, viewport_height: u16, row_height: u16) VisibleRange {
    if (item_count == 0 or row_height == 0) return .{ .first = 0, .count = 0 };
    const capacity = @max(@as(usize, 1), viewport_height / row_height);
    const bounded = @min(selected, item_count - 1);
    const first = if (bounded >= capacity) bounded - capacity + 1 else 0;
    return .{ .first = @min(first, item_count - 1), .count = @min(capacity, item_count - first) };
}

const Command = union(enum) {
    fill: struct { rect: Rect, color: Color },
    text: struct { rect: Rect, offset: u16, length: u16, style: TextStyle },
};

pub const Error = error{ CommandCapacityExceeded, TextCapacityExceeded };

pub const Ui = struct {
    surface: Surface,
    commands: [maximum_commands]Command = undefined,
    command_count: usize = 0,
    text_storage: [maximum_text_bytes]u8 = undefined,
    text_count: usize = 0,

    pub fn init(surface: Surface) Ui {
        return .{ .surface = surface };
    }

    pub fn fill(self: *Ui, rect: Rect, color: Color) Error!void {
        try self.append(.{ .fill = .{ .rect = rect, .color = color } });
    }

    pub fn text(self: *Ui, rect: Rect, value: []const u8, style: TextStyle) Error!void {
        if (value.len > self.text_storage.len - self.text_count) return error.TextCapacityExceeded;
        if (self.command_count == self.commands.len) return error.CommandCapacityExceeded;
        const start = self.text_count;
        @memcpy(self.text_storage[start..][0..value.len], value);
        self.text_count += value.len;
        try self.append(.{ .text = .{
            .rect = rect,
            .offset = @intCast(start),
            .length = @intCast(value.len),
            .style = style,
        } });
    }

    pub fn progress(self: *Ui, rect: Rect, value: u32, maximum: u32, track: Color, fill_color: Color) Error!void {
        if (self.commands.len - self.command_count < 2) return error.CommandCapacityExceeded;
        try self.fill(rect, track);
        const width: u16 = if (maximum == 0) 0 else @intCast(@min(rect.width, @as(u64, rect.width) * value / maximum));
        try self.fill(.{ .x = rect.x, .y = rect.y, .width = width, .height = rect.height }, fill_color);
    }

    pub fn render(self: *const Ui, surface: Surface) void {
        for (self.commands[0..self.command_count]) |command| switch (command) {
            .fill => |fill_command| surface.fill(fill_command.rect, fill_command.color),
            .text => |text_command| surface.text(text_command.rect, self.text_storage[text_command.offset..][0..text_command.length], text_command.style),
        };
    }

    pub fn finish(self: *Ui) void {
        for (self.commands[0..self.command_count]) |command| switch (command) {
            .fill => |fill_command| self.surface.fill(fill_command.rect, fill_command.color),
            .text => |text_command| self.surface.text(text_command.rect, self.text_storage[text_command.offset..][0..text_command.length], text_command.style),
        };
        self.command_count = 0;
        self.text_count = 0;
    }

    fn append(self: *Ui, command: Command) Error!void {
        if (self.command_count == self.commands.len) return error.CommandCapacityExceeded;
        self.commands[self.command_count] = command;
        self.command_count += 1;
    }
};

pub const Column = struct {
    bounds: Rect,
    cursor: u16 = 0,
    gap: u8,

    pub fn init(bounds: Rect, gap: u8) Column {
        return .{ .bounds = bounds, .gap = gap };
    }

    pub fn take(self: *Column, height: u16) Rect {
        const available_height = self.bounds.height -| self.cursor;
        const actual = @min(height, available_height);
        const rect = Rect{
            .x = self.bounds.x,
            .y = self.bounds.y +| @as(i32, self.cursor),
            .width = self.bounds.width,
            .height = actual,
        };
        self.cursor +|= actual +| self.gap;
        return rect;
    }

    pub fn remaining(self: *Column) Rect {
        return self.take(self.bounds.height -| self.cursor);
    }
};

pub const Row = struct {
    bounds: Rect,
    cursor: u16 = 0,
    gap: u8,

    pub fn init(bounds: Rect, gap: u8) Row {
        return .{ .bounds = bounds, .gap = gap };
    }

    pub fn take(self: *Row, width: u16) Rect {
        const remaining_width = self.bounds.width -| self.cursor;
        const actual = @min(width, remaining_width);
        const rect = Rect{
            .x = self.bounds.x +| @as(i32, self.cursor),
            .y = self.bounds.y,
            .width = actual,
            .height = self.bounds.height,
        };
        self.cursor +|= actual +| self.gap;
        return rect;
    }

    pub fn remaining(self: *Row) Rect {
        return self.take(self.bounds.width -| self.cursor);
    }
};

pub fn textWidth(value: []const u8, scale: u2) u16 {
    if (value.len == 0) return 0;
    return @intCast(@min(32700, (@min(value.len, 5000) * 6 - 1) * @as(usize, scale)));
}

fn drawGlyph(surface: Surface, x: i32, y: i32, character: u8, color: Color, scale: u2) void {
    const rows = glyph(if (character >= 'a' and character <= 'z') character - 32 else character);
    for (rows, 0..) |bits, row| {
        var column: u3 = 0;
        while (column < 5) : (column += 1) {
            if (bits & (@as(u8, 0x10) >> column) == 0) continue;
            surface.fill(.{
                .x = x +| @as(i32, @intCast(@as(u16, column) * scale)),
                .y = y +| @as(i32, @intCast(row * scale)),
                .width = scale,
                .height = scale,
            }, color);
        }
    }
}

fn glyph(character: u8) [7]u8 {
    return switch (character) {
        'A' => .{ 14, 17, 17, 31, 17, 17, 17 },
        'B' => .{ 30, 17, 17, 30, 17, 17, 30 },
        'C' => .{ 14, 17, 16, 16, 16, 17, 14 },
        'D' => .{ 30, 17, 17, 17, 17, 17, 30 },
        'E' => .{ 31, 16, 16, 30, 16, 16, 31 },
        'F' => .{ 31, 16, 16, 30, 16, 16, 16 },
        'G' => .{ 14, 17, 16, 23, 17, 17, 15 },
        'H' => .{ 17, 17, 17, 31, 17, 17, 17 },
        'I' => .{ 14, 4, 4, 4, 4, 4, 14 },
        'J' => .{ 7, 2, 2, 2, 18, 18, 12 },
        'K' => .{ 17, 18, 20, 24, 20, 18, 17 },
        'L' => .{ 16, 16, 16, 16, 16, 16, 31 },
        'M' => .{ 17, 27, 21, 21, 17, 17, 17 },
        'N' => .{ 17, 25, 21, 19, 17, 17, 17 },
        'O' => .{ 14, 17, 17, 17, 17, 17, 14 },
        'P' => .{ 30, 17, 17, 30, 16, 16, 16 },
        'Q' => .{ 14, 17, 17, 17, 21, 18, 13 },
        'R' => .{ 30, 17, 17, 30, 20, 18, 17 },
        'S' => .{ 15, 16, 16, 14, 1, 1, 30 },
        'T' => .{ 31, 4, 4, 4, 4, 4, 4 },
        'U' => .{ 17, 17, 17, 17, 17, 17, 14 },
        'V' => .{ 17, 17, 17, 17, 17, 10, 4 },
        'W' => .{ 17, 17, 17, 21, 21, 21, 10 },
        'X' => .{ 17, 17, 10, 4, 10, 17, 17 },
        'Y' => .{ 17, 17, 10, 4, 4, 4, 4 },
        'Z' => .{ 31, 1, 2, 4, 8, 16, 31 },
        '0' => .{ 14, 17, 19, 21, 25, 17, 14 },
        '1' => .{ 4, 12, 4, 4, 4, 4, 14 },
        '2' => .{ 14, 17, 1, 2, 4, 8, 31 },
        '3' => .{ 30, 1, 1, 14, 1, 1, 30 },
        '4' => .{ 2, 6, 10, 18, 31, 2, 2 },
        '5' => .{ 31, 16, 16, 30, 1, 1, 30 },
        '6' => .{ 14, 16, 16, 30, 17, 17, 14 },
        '7' => .{ 31, 1, 2, 4, 8, 8, 8 },
        '8' => .{ 14, 17, 17, 14, 17, 17, 14 },
        '9' => .{ 14, 17, 17, 15, 1, 1, 14 },
        '+' => .{ 0, 4, 4, 31, 4, 4, 0 },
        '-' => .{ 0, 0, 0, 31, 0, 0, 0 },
        ':' => .{ 0, 4, 4, 0, 4, 4, 0 },
        '/' => .{ 1, 1, 2, 4, 8, 16, 16 },
        '.' => .{ 0, 0, 0, 0, 0, 12, 12 },
        '>' => .{ 16, 8, 4, 2, 4, 8, 16 },
        '\'' => .{ 4, 4, 2, 0, 0, 0, 0 },
        '%' => .{ 17, 2, 4, 8, 17, 0, 0 },
        '<' => .{ 1, 2, 4, 8, 4, 2, 1 },
        '?' => .{ 14, 17, 1, 2, 4, 0, 4 },
        '_' => .{ 0, 0, 0, 0, 0, 0, 31 },
        '=' => .{ 0, 31, 0, 31, 0, 0, 0 },
        else => .{ 0, 0, 0, 0, 0, 0, 0 },
    };
}

test "column layout is bounded" {
    var column = Column.init(.{ .x = 4, .y = 6, .width = 100, .height = 50 }, 2);
    try std.testing.expectEqual(@as(u16, 20), column.take(20).height);
    try std.testing.expectEqual(@as(i32, 28), column.take(20).y);
    try std.testing.expectEqual(@as(u16, 6), column.remaining().height);
}

test "fixed command buffer renders deterministically" {
    var pixels: [pixel_count]Color = undefined;
    var framework = Ui.init(.{ .pixels = &pixels });
    try framework.fill(.{ .x = 0, .y = 0, .width = screen_width, .height = screen_height }, dark_theme.background);
    try framework.fill(.{ .x = 10, .y = 10, .width = 12, .height = 8 }, dark_theme.accent);
    framework.finish();
    try std.testing.expectEqual(dark_theme.background, pixels[0]);
    try std.testing.expectEqual(dark_theme.accent, pixels[10 * screen_width + 10]);
}

test "virtual lists render a bounded window for large libraries" {
    const range = visibleRange(10_000, 9_999, 180, 30);
    try std.testing.expectEqual(@as(usize, 9_994), range.first);
    try std.testing.expectEqual(@as(usize, 6), range.count);
}

pub fn intersection(a: Rect, b: Rect) Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @max(@as(i32, x), @min(@as(i32, a.x) +| a.width, @as(i32, b.x) +| b.width));
    const bottom = @max(@as(i32, y), @min(@as(i32, a.y) +| a.height, @as(i32, b.y) +| b.height));
    return .{ .x = x, .y = y, .width = @intCast(right - x), .height = @intCast(bottom - y) };
}

/// Render both live scenes through clipping, rather than replaying prebaked
/// frames. The caller supplies the output canvas and owns presentation timing.
pub fn slide(previous: *const Ui, next: *const Ui, pixels: *[pixel_count]Color, offset: u16) void {
    const bounded = @min(offset, screen_width);
    @memset(pixels, 0);
    // Commands, including text, are translated before clipping to the output.
    renderTranslated(previous, pixels, -@as(i32, bounded));
    renderTranslated(next, pixels, @intCast(screen_width - bounded));
}

fn renderTranslated(scene: *const Ui, pixels: *[pixel_count]Color, dx: i32) void {
    const surface = Surface{ .pixels = pixels };
    for (scene.commands[0..scene.command_count]) |command| switch (command) {
        .fill => |fill_command| {
            var rect = fill_command.rect;
            rect.x = @intCast(@as(i32, rect.x) +| dx);
            surface.fill(rect, fill_command.color);
        },
        .text => |text_command| {
            var rect = text_command.rect;
            rect.x = @intCast(@as(i32, rect.x) +| dx);
            surface.text(rect, scene.text_storage[text_command.offset..][0..text_command.length], text_command.style);
        },
    };
}

test "scene text survives relocation and caller scratch reuse" {
    var output: [pixel_count]u16 = @splat(0);
    var original = Ui.init(.{ .pixels = &output });
    var scratch = [_]u8{ 'G', 'A', 'I', 'N' };
    try original.text(.{ .x = 10, .y = 10, .width = 24, .height = 7 }, &scratch, .{ .color = 0xffff });
    const moved = original;
    @memset(&scratch, 0);
    @memset(&original.text_storage, 0);
    moved.render(.{ .pixels = &output });
    try std.testing.expectEqual(@as(u16, 0xffff), output[10 * 320 + 11]);
}

test "capacity failures are atomic and progress needs two command slots" {
    var pixels: [pixel_count]u16 = undefined;
    var scene = Ui.init(.{ .pixels = &pixels });
    const rect = Rect{ .x = 0, .y = 0, .width = 320, .height = 240 };
    const bytes: [maximum_text_bytes]u8 = @splat('A');
    try scene.text(rect, &bytes, .{ .color = 1 });
    try std.testing.expectError(error.TextCapacityExceeded, scene.text(rect, "X", .{ .color = 1 }));
    try std.testing.expectEqual(@as(usize, 1), scene.command_count);
    while (scene.command_count < maximum_commands - 1) try scene.fill(rect, 0);
    try std.testing.expectError(error.CommandCapacityExceeded, scene.progress(rect, 1, 2, 0, 1));
    try std.testing.expectEqual(maximum_commands - 1, scene.command_count);
    try scene.fill(rect, 0);
    const previous_text = scene.text_count;
    try std.testing.expectError(error.CommandCapacityExceeded, scene.text(rect, "", .{ .color = 1 }));
    try std.testing.expectEqual(previous_text, scene.text_count);
}

test "glyphs respect their own rectangle and surface clip with canaries" {
    var memory: [pixel_count + 2]u16 = @splat(0xa55a);
    const pixels: *[pixel_count]u16 = @ptrCast(&memory[1]);
    @memset(pixels, 0);
    const rect = Rect{ .x = -3, .y = -2, .width = 11, .height = 8 };
    const surface = Surface{ .pixels = pixels, .clip = .{ .x = 2, .y = 1, .width = 3, .height = 3 } };
    surface.text(rect, "AAAA", .{ .color = 1, .scale = 3 });
    for (pixels, 0..) |pixel, index| {
        if (pixel != 0) try std.testing.expect(index % 320 >= 2 and index % 320 < 5 and index / 320 >= 1 and index / 320 < 4);
    }
    surface.fill(.{ .x = std.math.maxInt(i32), .y = 0, .width = 65535, .height = 65535 }, 1);
    surface.text(.{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32), .width = 65535, .height = 65535 }, "AAAA", .{ .color = 1, .scale = 3 });
    try std.testing.expect(memory[0] == 0xa55a and memory[pixel_count + 1] == 0xa55a);
}

test "visible range clamps invalid selection without unsigned underflow" {
    try std.testing.expectEqual(VisibleRange{ .first = 0, .count = 2 }, visibleRange(2, std.math.maxInt(usize), 180, 30));
    try std.testing.expectEqual(VisibleRange{ .first = 0, .count = 0 }, visibleRange(0, 100, 180, 30));
}
