//! Native music widgets. Built-in and file themes share this renderer.
//! Rendering has no parser, filesystem or allocator dependency.
const std = @import("std");
const theme = @import("runtime_theme.zig");
const draw = @import("canvas.zig");
const core = @import("library.zig");
const views = @import("progressive_view.zig");
const covers = @import("cover_cache.zig");
const flow = @import("cover_flow.zig");
const C = draw.Canvas;
pub const Item = struct { name: []const u8 = "", detail: []const u8 = "", secondary: []const u8 = "", chevron: bool = false };
pub const Context = struct {
    page: theme.Page,
    title: []const u8,
    empty_message: []const u8,
    jump_title: []const u8,
    detail: []const u8,
    phase: []const u8,
    snapshot: *const views.Snapshot,
    cache: *covers.Cache,
    items: []const Item,
    first: usize,
    selection: usize,
    total: usize,
    track: ?*const core.Track,
    artwork: core.Artwork,
    artwork_id: u64,
    power: @import("battery.zig").Status,
    shuffled: bool = false,
    repeat: @import("play_queue.zig").Repeat = .off,
    cards: []const flow.Card = &.{},
    flow_position: f32,
    scanning: bool,
    scan_visited: u32,
    scan_total: u32,
    elapsed: u64,
    duration: u64,
    sample_rate: u32,
    volume_mix: f32,
    volume_value: f32,
    playback_phase: @import("f20_media.zig").PlaybackPhase = .preparing,
    summary_selected: bool = false,
    jump: usize,
};

fn capTop(top: i32, role: draw.fonts.Role) i32 {
    return top - draw.fonts.glyph(role, 'H').ink_y;
}

fn label(c: C, rect: theme.Rect, value: []const u8, role: draw.fonts.Role, color: u16, alignment: theme.Alignment) void {
    labelPrepared(c, rect, @intCast(capTop(0, role)), value, role, color, alignment);
}

fn labelPrepared(c: C, rect: theme.Rect, baseline_offset: i16, value: []const u8, role: draw.fonts.Role, color: u16, alignment: theme.Alignment) void {
    switch (role) {
        inline else => |specific| labelRole(specific, c, rect, baseline_offset, value, color, alignment),
    }
}

fn labelRole(comptime role: draw.fonts.Role, c: C, rect: theme.Rect, baseline_offset: i16, value: []const u8, color: u16, alignment: theme.Alignment) void {
    var clipped = c;
    clipped.surface.clip = @import("ui.zig").intersection(c.surface.clip, .{ .x = rect.x, .y = rect.y, .width = rect.w, .height = rect.h });
    const top = @as(i32, rect.y) + baseline_offset;
    switch (alignment) {
        .left => clipped.ellipsis(rect.x, top, rect.w, value, role, color),
        .center => clipped.centered(rect.x, top, rect.w, value, role, color),
        .right => clipped.right(@as(i32, rect.x) + rect.w, top, value, role, color),
    }
}

fn text(plan: *const theme.Plan, op: *const theme.Op, context: Context, buffer: []u8) []const u8 {
    const album = if (context.snapshot.album_count > 0) &context.snapshot.albums[@min(context.selection, context.snapshot.album_count - 1)] else null;
    const track = context.track;
    const value: []const u8 = switch (op.binding) {
        .literal => return plan.literal(op),
        .page_title => context.title,
        .page_detail => context.detail,
        .album_title => if (album) |a| a.title else "Albums",
        .album_artist => if (album) |a| a.artist else "",
        .track_title => if (track) |t| t.meta.title else "Choose a track",
        .track_artist => if (track) |t| t.meta.artist else "",
        .track_album => if (track) |t| t.meta.album else "",
        .codec => if (track) |t| t.meta.codec else "",
        .transport_state => if (track == null) "" else switch (context.playback_phase) {
            .preparing => "Preparing",
            .playing => "Playing",
            .paused => "Paused",
        },
        .library_phase => context.phase,
        .empty_message => context.empty_message,
        .jump_title => context.jump_title,
        .track_summary => if (track) |t| std.fmt.bufPrint(buffer, "{s} · {s}", .{ t.meta.artist, t.meta.album }) catch t.meta.artist else "",
        .jump_percent => std.fmt.bufPrint(buffer, "{d}%", .{context.jump * 5}) catch "",
        else => "",
    };
    if (op.literal_length == 0) return value;
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ plan.literal(op), value }) catch value;
}

fn nowPlaying(c: C, op: *const theme.Op, context: Context, muted: u16) void {
    const track = context.track orelse return;
    var clipped = c;
    clipped.surface.clip = @import("ui.zig").intersection(c.surface.clip, .{ .x = op.rect.x, .y = op.rect.y, .width = op.rect.w, .height = op.rect.h });
    const selected = context.page == .home and context.summary_selected;
    if (selected) clipped.rounded(op.rect.x, op.rect.y, op.rect.w, op.rect.h, op.radius, op.focus);
    const color = if (selected) op.focus_text else op.color;
    const inset: u16 = 8;
    const height: u16 = if (op.lines == 2) 20 else op.rect.h;
    const top: i16 = if (op.lines == 2) 2 else @intCast(@divTrunc(@as(i32, op.rect.h) - draw.fonts.glyph(op.role, 'H').ink_height, 2));
    label(clipped, .{ .x = op.rect.x + inset, .y = op.rect.y + top, .w = op.rect.w - inset * 2 - 14, .h = height }, track.meta.title, op.role, color, .left);
    if (op.lines == 2) label(clipped, .{ .x = op.rect.x + inset, .y = op.rect.y + @as(i16, @intCast(op.rect.h)) - 13, .w = op.rect.w - inset * 2 - 14, .h = 12 }, track.meta.artist, .caption, if (selected) color else muted, .left);
    clipped.chevron(@as(i32, op.rect.x) + op.rect.w - 18, @as(i32, op.rect.y) + @divTrunc(op.rect.h - 9, 2), color);
}

fn artwork(c: C, op: *const theme.Op, context: Context) void {
    context.cache.request(0, context.artwork_id, context.artwork);
    const tile = context.cache.get(context.artwork_id, context.artwork) orelse {
        c.rounded(op.rect.x, op.rect.y, op.rect.w, op.rect.h, op.radius, op.background);
        return;
    };
    if (tile.width == 0 or tile.height == 0) return;
    // Same prepared column walk as the production artwork path: bounds are
    // validated at theme activation, and row mapping avoids per-pixel division.
    const first: usize = @intCast(@max(0, c.surface.clip.y - op.rect.y));
    const last: usize = @intCast(@min(op.rect.h, c.surface.clip.y + c.surface.clip.height - op.rect.y));
    if (first >= last) return;
    const first_source = first * flow.texture_edge / op.rect.h;
    const first_remainder = first * flow.texture_edge % op.rect.h;
    for (0..op.rect.w) |x| {
        const sx = x * flow.texture_edge / op.rect.w;
        if (sx < tile.x or sx >= tile.x + tile.width) continue;
        const dx = @as(i32, op.rect.x) + @as(i32, @intCast(x));
        if (dx < c.surface.clip.x or dx >= c.surface.clip.x + c.surface.clip.width) continue;
        var sy = first_source;
        var remainder = first_remainder;
        var destination = (@as(usize, @intCast(op.rect.y)) + first) * 320 + @as(usize, @intCast(op.rect.x)) + x;
        for (first..last) |_| {
            if (sy >= tile.y and sy < tile.y + tile.height) c.surface.pixels[destination] = tile.pixels[sx * flow.texture_edge + sy];
            destination += 320;
            remainder += flow.texture_edge;
            while (remainder >= op.rect.h) {
                remainder -= op.rect.h;
                sy += 1;
            }
        }
    }
}

const scrollbar_width = 2;
const scrollbar_gutter = 6;
const minimum_thumb_height = 6;

const ScrollThumb = struct { top: u16, height: u16 };

fn scrollThumb(extent: u16, visible_rows: usize, total_rows: usize, first_row: usize) ?ScrollThumb {
    if (extent == 0 or visible_rows == 0 or total_rows <= visible_rows) return null;
    // Firmware counts are 32-bit. Wider host fixtures keep the same exact
    // endpoint arithmetic without overflowing on adversarial simulator input.
    const Wide = if (@bitSizeOf(usize) > 32) u128 else u64;
    const height: u16 = @intCast(@min(extent, @max(@min(extent, minimum_thumb_height), @as(Wide, extent) * visible_rows / total_rows)));
    const first = @min(first_row, total_rows - visible_rows);
    const top: u16 = @intCast(@as(Wide, first) * (extent - height) / (total_rows - visible_rows));
    return .{ .top = top, .height = height };
}

fn list(c: C, op: *const theme.Op, context: Context, muted: u16) void {
    // Reserve the same trailing gutter for short and long lists, keeping text
    // and chevrons aligned when an overflow indicator appears or disappears.
    const gutter: u16 = @min(scrollbar_gutter, op.cell_width -| 16);
    for (context.items, 0..) |item, i| {
        const column = i % op.columns;
        const cell_width = op.cell_width - (if (column + 1 == op.columns) gutter else 0);
        const row = i / op.columns;
        const y = op.rect.y + @as(i32, @intCast(row * @as(usize, op.row_stride)));
        if (y + op.row_height > @as(i32, op.rect.y) + op.rect.h) break;
        const x = op.rect.x + @as(i32, @intCast(column * @as(usize, op.cell_stride)));
        const selected = context.first + i == context.selection;
        const color = if (selected) op.focus_text else op.color;
        if (selected or op.columns > 1) c.rounded(x, y, cell_width, op.row_height, op.radius, if (selected) op.focus else op.background);
        const inset: u16 = 8;
        const label_top = y + op.row_label_offset;
        const text_rect = theme.Rect{ .x = @intCast(x + inset), .y = @intCast(label_top), .w = cell_width - 2 * inset, .h = 24 };
        if (selected and item.secondary.len != 0 and op.columns == 1 and op.row_height >= 26) {
            var title_rect = text_rect;
            title_rect.y = @intCast(y + 1);
            labelPrepared(c, title_rect, op.baseline_offset, item.name, op.role, color, op.alignment);
            label(c, .{ .x = text_rect.x, .y = @intCast(y + op.row_height - 11), .w = text_rect.w, .h = 11 }, item.secondary, .caption, draw.blend(color, op.focus, 64), .left);
        } else {
            var primary = text_rect;
            if (item.chevron and item.detail.len == 0) primary.w -|= 12;
            if (item.detail.len != 0) primary.w = primary.w -| @as(u16, @intCast(@min(primary.w, draw.textWidth(item.detail, .caption) + 12)));
            labelPrepared(c, primary, op.baseline_offset, item.name, op.role, color, op.alignment);
        }
        if (item.chevron and item.detail.len == 0 and op.columns == 1) c.chevron(x + cell_width - 14, y + op.detail_label_offset, muted);
        if (op.detail != 0 or item.detail.len != 0) {
            const detail_width = @min(124, cell_width - 2 * inset);
            const detail_rect = if (op.columns > 1) theme.Rect{ .x = @intCast(x + inset), .y = @intCast(y + 30), .w = cell_width - 2 * inset, .h = 18 } else theme.Rect{ .x = @intCast(x + cell_width - inset - detail_width), .y = @intCast(y + op.detail_label_offset), .w = detail_width, .h = 18 };
            label(c, detail_rect, item.detail, .caption, if (selected) op.focus_text else muted, if (op.columns > 1) .left else .right);
        }
        if (op.detail == 0 and op.literal_length > 0) c.chevron(x + cell_width - 14, y + op.detail_label_offset, muted);
    }
    if (gutter >= scrollbar_width) {
        const rows = op.rect.h / @max(1, op.row_stride);
        const total_rows = context.total / op.columns + @intFromBool(context.total % op.columns != 0);
        if (scrollThumb(op.rect.h, rows, total_rows, context.first / op.columns)) |thumb| c.fill(@as(i32, op.rect.x) + op.rect.w - scrollbar_width, @as(i32, op.rect.y) + thumb.top, scrollbar_width, thumb.height, muted);
    }
}

fn coverScene(c: C, op: *const theme.Op, context: Context) void {
    c.fill(op.rect.x, op.rect.y, op.rect.w, op.rect.h, op.background);
    // Horizontal artwork bleed is deliberate; vertical ownership remains bounded.
    const top: usize = @intCast(@max(op.rect.y, c.surface.clip.y));
    const bottom: usize = @intCast(@min(@as(i32, op.rect.y) + op.rect.h, c.surface.clip.y + c.surface.clip.height));
    if (top >= bottom) return;
    const offset = top * 320;
    flow.paintScene(.{ .pixels = c.surface.pixels[offset..][0 .. (bottom - top) * 320], .height = bottom - top, .origin_y = top }, context.cards);
}

fn transport(c: C, op: *const theme.Op, context: Context) void {
    switch (op.progress) {
        inline else => |style| transportStyle(style, c, op, context),
    }
}

fn box(c: C, x: i32, y: i32, width: u16, height: u16, radius: u16, color: u16) void {
    if (radius == 0) c.fill(x, y, width, height, color) else c.rounded(x, y, width, height, radius, color);
}

fn transportStyle(comptime style: theme.Progress, c: C, op: *const theme.Op, context: Context) void {
    c.fill(op.rect.x, op.rect.y, op.rect.w, op.rect.h, op.background);
    const line_height: u16 = op.line_height;
    const radius: u16 = op.line_radius;
    const progress_width: u16 = @intCast(if (context.duration > 0) @min(op.rect.w, context.elapsed * op.rect.w / context.duration) else 0);
    const volume_width: u16 = @intFromFloat(std.math.clamp(context.volume_value / 100, 0, 1) * @as(f32, @floatFromInt(op.rect.w)));
    const opacity: u8 = @intFromFloat(context.volume_mix * 255);
    box(c, op.rect.x, op.rect.y, op.rect.w, line_height, radius, op.color);
    if (volume_width > 0) box(c, op.rect.x, op.rect.y, volume_width, line_height, radius, draw.blend(op.color, op.focus, opacity));
    if (progress_width > 0) box(c, op.rect.x, op.rect.y, progress_width, line_height, radius, draw.blend(op.color, op.focus, 255 - opacity));
    const overlap = @min(volume_width, progress_width);
    if (overlap > 0) box(c, op.rect.x, op.rect.y, overlap, line_height, radius, op.focus);
    if (style == .thumb) {
        const thumb: i32 = @intFromFloat(@as(f32, @floatFromInt(progress_width)) * (1 - context.volume_mix) + @as(f32, @floatFromInt(volume_width)) * context.volume_mix);
        box(c, op.rect.x + std.math.clamp(thumb, 3, @as(i32, op.rect.w) - 3) - 3, op.rect.y - 2, 6, 6, 3, op.focus);
    }
    var a: [48]u8 = undefined;
    var b: [48]u8 = undefined;
    const right = if (context.volume_mix < 0.5) std.fmt.bufPrint(&b, "{d}:{d:0>2}", .{ context.duration / @max(1, context.sample_rate) / 60, context.duration / @max(1, context.sample_rate) % 60 }) catch "" else "";
    const left = if (context.volume_mix < 0.5) std.fmt.bufPrint(&a, "{d}:{d:0>2}", .{ context.elapsed / @max(1, context.sample_rate) / 60, context.elapsed / @max(1, context.sample_rate) % 60 }) catch "" else "";
    const y = op.rect.y + @as(i32, op.label_offset);
    if (context.volume_mix < 0.5) label(c, .{ .x = op.rect.x, .y = @intCast(y), .w = 80, .h = 18 }, left, .caption, draw.blend(op.focus_text, op.background, @intFromFloat(context.volume_mix * 2 * 255)), .left) else @import("playback_icons.zig").paintFaded(c, op.rect.x, y - 3, .speaker, op.focus_text, @intFromFloat((context.volume_mix - 0.5) * 2 * 255));
    label(c, .{ .x = @intCast(@as(i32, op.rect.x) + op.rect.w - 80), .y = @intCast(y), .w = 80, .h = 18 }, right, .caption, draw.blend(op.focus_text, op.background, @intFromFloat(@min(1, context.volume_mix * 2) * 255)), .right);
}

pub fn render(plan: *const theme.Plan, pixels: *[320 * 240]u16, context: Context, cache: ?*@import("text/cache.zig").Cache, transport_only: bool, covers_only: bool) void {
    renderPass(plan, pixels, context, cache, transport_only, covers_only, null);
}

pub const Band = struct { top: i32, bottom: i32, mask: u32 };

/// Recompose every intersecting layer, including backgrounds, when scan state
/// changes. A full-width band preserves the rasterizer's contiguous row stride.
/// The plan determines its extent; it is not tied to a particular theme layout.
pub fn renderScanUpdate(plan: *const theme.Plan, pixels: *[320 * 240]u16, context: Context, cache: ?*@import("text/cache.zig").Cache, state_changed: bool) ?theme.Rect {
    const span = plan.pages[@backingInt(context.page)];
    const top = if (state_changed) span.scan_top else span.progress_top;
    const bottom = if (state_changed) span.scan_bottom else span.progress_bottom;
    const mask = if (state_changed) span.scan_mask else span.progress_mask;
    if (top >= bottom) return null;
    renderPass(plan, pixels, context, cache, false, false, .{ .top = top, .bottom = bottom, .mask = mask });
    return .{ .x = 0, .y = @intCast(top), .w = 320, .h = bottom - top };
}

fn renderPass(plan: *const theme.Plan, pixels: *[320 * 240]u16, context: Context, cache: ?*@import("text/cache.zig").Cache, transport_only: bool, covers_only: bool, band: ?Band) void {
    var c = C.init(pixels);
    c.text_cache = cache;
    if (cache) |text_cache| text_cache.beginFrame();
    const span = plan.pages[@backingInt(context.page)];
    if (transport_only) {
        const bounds = plan.transport;
        renderPass(plan, pixels, context, cache, false, false, .{ .top = bounds.y, .bottom = @as(i32, bounds.y) + bounds.h, .mask = span.transport_mask });
        return;
    }
    if (covers_only) {
        const scene = plan.ops[span.covers].rect;
        renderPass(plan, pixels, context, cache, false, false, .{ .top = scene.y, .bottom = @as(i32, scene.y) + scene.h, .mask = span.covers_mask });
        return;
    }
    if (band) |damage| {
        c.surface.clip = .{ .x = 0, .y = damage.top, .width = 320, .height = @intCast(damage.bottom - damage.top) };
        c.fill(0, damage.top, 320, @intCast(damage.bottom - damage.top), plan.paper);
    } else if (!transport_only and !covers_only) c.clear(plan.paper);
    for (plan.slice(context.page), 0..) |*op, rank| {
        if (band) |damage| if (damage.mask & (@as(u32, 1) << @intCast(rank)) == 0) continue;
        if (band == null and rank == 0 and !transport_only and !covers_only and op.kind == .rect and op.color == plan.paper) continue;
        if (transport_only and op.kind != .transport) continue;
        if (covers_only and op.kind != .covers) continue;
        const visible = switch (op.condition) {
            .always => true,
            .track => context.track != null,
            .empty => context.track == null,
            .scanning => context.scanning,
            .empty_list => context.total == 0,
        };
        if (!visible) continue;
        switch (op.kind) {
            .progress => {
                const width: u16 = if (op.binding == .scan_progress and context.scan_total > 0) @intCast(@min(op.rect.w, @as(u64, context.scan_visited) * op.rect.w / context.scan_total)) else if (op.binding == .jump_progress) @intCast(context.jump * op.rect.w / 20) else 0;
                c.fill(op.rect.x, op.rect.y, op.rect.w, op.rect.h, op.color);
                if (width > 0) c.fill(op.rect.x, op.rect.y, width, op.rect.h, op.focus);
            },
            .rect => if (op.radius == 0) c.fill(op.rect.x, op.rect.y, op.rect.w, op.rect.h, op.color) else c.rounded(op.rect.x, op.rect.y, op.rect.w, op.rect.h, op.radius, op.color),
            .text => {
                var buffer: [512]u8 = undefined;
                const value = text(plan, op, context, &buffer);
                if (op.lines == 1 or draw.textWidth(value, op.role) <= op.rect.w) {
                    labelPrepared(c, op.rect, op.baseline_offset, value, op.role, op.color, op.alignment);
                } else {
                    var it = (std.unicode.Utf8View.init(value) catch continue).iterator();
                    var last: usize = 0;
                    var word: usize = 0;
                    var cursor: u32 = 0;
                    var extent: u32 = 0;
                    while (it.nextCodepoint()) |cp| {
                        const glyph = draw.fonts.glyph(op.role, cp);
                        extent = @max(extent, cursor + glyph.width - 1);
                        cursor += glyph.advance;
                        if (it.i > 256 or @max(extent, cursor) > op.rect.w) break;
                        last = it.i;
                        if (cp == ' ') word = it.i;
                    }
                    const split = if (word > 0) word else last;
                    labelPrepared(c, op.rect, op.baseline_offset, std.mem.trim(u8, value[0..split], " "), op.role, op.color, op.alignment);
                    var next = op.rect;
                    next.y += 26;
                    next.h = next.h -| 26;
                    labelPrepared(c, next, op.baseline_offset, std.mem.trimStart(u8, value[split..], " "), op.role, op.color, op.alignment);
                }
            },
            .battery => @import("music_chrome.zig").batteryAt(c, context.power, .{ .paper = plan.paper, .ink = plan.ink, .muted = op.color, .line = plan.line, .accent = op.focus, .selected = plan.selected }, op.rect.x, op.rect.y),
            .playback_modes => {
                const icons = @import("playback_icons.zig");
                if (context.shuffled) icons.paint(c, op.rect.x, op.rect.y, .shuffle, op.color);
                if (context.repeat != .off) icons.paint(c, op.rect.x + 29, op.rect.y, if (context.repeat == .one) .repeat_one else .repeat_all, op.color);
            },
            .playback_state => if (context.track != null) @import("music_chrome.zig").playbackAt(c, op.rect.x, op.rect.y, context.playback_phase, op.color),
            .now_playing => nowPlaying(c, op, context, plan.muted),
            .artwork => artwork(c, op, context),
            .list => list(c, op, context, plan.muted),
            .covers => coverScene(c, op, context),
            .transport => transport(c, op, context),
        }
    }
    context.cache.publishRequests();
}

test "overflow thumb is proportional, bounded and reaches both ends for rows and grids" {
    try std.testing.expect(scrollThumb(160, 6, 6, 0) == null);
    try std.testing.expect(scrollThumb(160, 0, 9, 0) == null);
    try std.testing.expectEqual(ScrollThumb{ .top = 0, .height = 106 }, scrollThumb(160, 6, 9, 0).?);
    try std.testing.expectEqual(ScrollThumb{ .top = 54, .height = 106 }, scrollThumb(160, 6, 9, 3).?);
    for (1..241) |extent| for ([_]usize{ 7, 9, 1024, 8192, std.math.maxInt(usize) }) |total| {
        const first = scrollThumb(@intCast(extent), 6, total, 0).?;
        const last = scrollThumb(@intCast(extent), 6, total, std.math.maxInt(usize)).?;
        try std.testing.expectEqual(0, first.top);
        try std.testing.expect(first.height > 0 and first.height <= extent);
        try std.testing.expectEqual(extent, @as(usize, last.top) + last.height);
    };
}

test "list overflow paint stays in its trailing gutter and respects damage clips" {
    var pixels: [320 * 240]u16 = @splat(0x1234);
    const view = try std.testing.allocator.create(views.Snapshot);
    defer std.testing.allocator.destroy(view);
    try view.build(&.{}, &.{}, 1, true, 1);
    const cache = try std.testing.allocator.create(covers.Cache);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    var context = Context{ .page = .home, .title = "", .empty_message = "", .jump_title = "", .detail = "", .phase = "", .snapshot = view, .cache = cache, .items = &.{}, .first = 0, .selection = 0, .total = 9, .track = null, .artwork = .{}, .artwork_id = 0, .power = .{}, .flow_position = 0, .scanning = false, .scan_visited = 0, .scan_total = 0, .elapsed = 0, .duration = 0, .sample_rate = 0, .volume_mix = 0, .volume_value = 0, .jump = 0 };
    const op = theme.Op{ .kind = .list, .rect = .{ .x = 8, .y = 64, .w = 304, .h = 168 }, .columns = 1, .row_height = 28, .row_stride = 28, .cell_width = 304, .cell_stride = 304 };
    var c = C.init(&pixels);
    c.surface.clip = .{ .x = 0, .y = 80, .width = 320, .height = 20 };
    list(c, &op, context, 0xffff);
    for (pixels, 0..) |pixel, i| {
        const x = i % 320;
        const y = i / 320;
        try std.testing.expectEqual(if (x >= 310 and x < 312 and y >= 80 and y < 100) @as(u16, 0xffff) else @as(u16, 0x1234), pixel);
    }
    @memset(&pixels, 0x1234);
    context.total = 6;
    list(C.init(&pixels), &op, context, 0xffff);
    for (pixels) |pixel| try std.testing.expectEqual(0x1234, pixel);
}
