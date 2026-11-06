//! Native music theme data and compiler, shared by built-in and JSON sources.
const std = @import("std");
const ui = @import("ui.zig");
const fonts = @import("font_data.zig");
pub const max_source = 32 * 1024;
pub const max_ops = 128;
pub const scratch_bytes = 96 * 1024;
pub const Format = enum { json };
pub const Page = enum(u8) { home, albums, tracks, player, library, artists, artist, jump, menu };
pub const Kind = enum(u8) { rect, text, battery, artwork, list, covers, transport, progress, playback_modes, playback_state, now_playing };
pub const Binding = enum(u8) { literal, page_title, page_detail, album_title, album_artist, track_title, track_artist, track_album, codec, track_summary, transport_state, library_phase, home, artists, artist, tracks, library, jump_percent, scan_progress, jump_progress, menu, empty_message, jump_title };
pub const Alignment = enum(u8) { left, center, right };
pub const Condition = enum(u8) { always, track, empty, scanning, empty_list };
pub const Progress = enum(u8) { bar, thin, thumb };
pub const Token = enum(u8) { paper, ink, muted, line, accent, selected, selected_text };
pub const Rect = extern struct { x: i16 = 0, y: i16 = 0, w: u16 = 0, h: u16 = 0 };
pub const Position = struct { x: i16 = 0, y: i16 = 0, w: u16 = 0, h: u16 = 0, right: ?u16 = null, bottom: ?u16 = null, after: ?[]const u8 = null, gap: i16 = 0 };
pub const Node = struct {
    id: []const u8 = "",
    kind: Kind,
    rect: Position,
    binding: Binding = .literal,
    value: []const u8 = "",
    role: fonts.Role = .body,
    alignment: Alignment = .left,
    color: Token = .ink,
    background: Token = .paper,
    focus: Token = .selected,
    focus_text: Token = .accent,
    radius: u8 = 0,
    columns: u8 = 1,
    row_height: u8 = 32,
    gap: u8 = 0,
    lines: u8 = 1,
    label_offset: u8 = 20,
    detail: bool = false,
    when: Condition = .always,
    edge: u16 = 112,
    reflection: u8 = 16,
    progress: Progress = .bar,
};

pub const Palette = struct { paper: []const u8, ink: []const u8, muted: []const u8, line: []const u8, accent: []const u8, selected: []const u8, selected_text: []const u8 };
pub const Screens = struct { home: []const Node, albums: []const Node, tracks: []const Node, player: []const Node, library: []const Node, artists: []const Node, artist: []const Node, jump: []const Node, menu: []const Node };
pub const Document = struct { version: u16, name: []const u8, palette: Palette, header: []const Node, screens: Screens };
pub const Op = extern struct {
    rect: Rect = .{},
    kind: Kind = .rect,
    binding: Binding = .literal,
    role: fonts.Role = .body,
    alignment: Alignment = .left,
    color_slot: Token = .ink,
    background_slot: Token = .paper,
    focus_slot: Token = .selected,
    focus_text_slot: Token = .accent,
    color: u16 = 0,
    background: u16 = 0,
    focus: u16 = 0,
    focus_text: u16 = 0,
    radius: u8 = 0,
    columns: u8 = 1,
    row_height: u8 = 32,
    gap: u8 = 0,
    lines: u8 = 1,
    label_offset: u8 = 20,
    detail: u8 = 0,
    condition: Condition = .always,
    progress: Progress = .bar,
    edge: u16 = 112,
    reflection: u8 = 16,
    literal_length: u8 = 0,
    literal_offset: u16 = 0,
    baseline_offset: i16 = 0,
    row_label_offset: i16 = 0,
    detail_label_offset: i16 = 0,
    cell_width: u16 = 0,
    cell_stride: u16 = 0,
    row_stride: u16 = 0,
    line_height: u8 = 0,
    line_radius: u8 = 0,
};
/// Compiled model dependencies; input polling checks only the relevant fields.
pub const Flags = struct {
    pub const artwork = 1;
    pub const transport = 2;
    pub const row_details = 4;
    pub const page_detail = 8;
    pub const scan_phase = 16;
    pub const playback_phase = 32;
    pub const track_metadata = 64;
    pub const transport_artwork = 128;
};

pub const no_widget = std.math.maxInt(u16);
pub const Span = extern struct {
    first: u16 = 0,
    count: u16 = 0,
    capacity: u16 = 0,
    columns: u8 = 1,
    flags: u16 = 0,
    covers: u16 = no_widget,
    transport: u16 = no_widget,
    now_playing: u16 = no_widget,
    scan_top: u16 = 240,
    scan_bottom: u16 = 0,
    scan_mask: u32 = 0,
    scan_widgets: u32 = 0,
    progress_top: u16 = 240,
    progress_bottom: u16 = 0,
    progress_mask: u32 = 0,
    transport_mask: u32 = 0,
    covers_mask: u32 = 0,
};

pub const Plan = extern struct {
    width: u16 = 320,
    height: u16 = 240,
    count: u16 = 0,
    name_length: u16 = 0,
    paper: u16 = 0,
    ink: u16 = 0,
    muted: u16 = 0,
    accent: u16 = 0,
    line: u16 = 0,
    selected: u16 = 0,
    selected_text: u16 = 0,
    name: [64]u8 = @splat(0),
    pages: [9]Span = @splat(.{}),
    transport: Rect = .{},
    literal_used: u16 = 0,
    literals: [2048]u8 = @splat(0),
    ops: [max_ops]Op = @splat(.{}),
    pub fn literal(self: *const Plan, op: *const Op) []const u8 {
        return self.literals[op.literal_offset..][0..op.literal_length];
    }
    /// Sum of the visible pixel widths is monotonic in the shared scan ratio.
    /// Unlike one hardcoded bar width, this catches changes in every themed bar.
    pub fn scanProgress(self: *const Plan, page: Page, visited: u32, total: u32) u16 {
        if (total == 0) return 0;
        const span = self.pages[@backingInt(page)];
        var pending = span.scan_widgets;
        var pixels: u32 = 0;
        while (pending != 0) {
            const rank = @ctz(pending);
            pending &= pending - 1;
            const width = self.ops[span.first + rank].rect.w;
            pixels += @intCast(@min(width, @as(u64, visited) * width / total));
        }
        return @intCast(pixels);
    }
    pub fn slice(self: *const Plan, page: Page) []const Op {
        const span = self.pages[@backingInt(page)];
        return self.ops[span.first..][0..span.count];
    }
};

pub const Store = struct {
    banks: [2]Plan = undefined,
    active: u1 = 0,
    selected: ?*const Plan = null,
    revision: u32 = 0,
    has_custom: bool = false,
    using_custom: bool = false,

    pub fn current(self: *const Store) *const Plan {
        if (self.using_custom) return &self.banks[self.active];
        return self.selected orelse &@import("builtin_themes.zig").plans[0];
    }

    pub fn select(self: *Store, family: @import("preferences.zig").Theme, appearance: @import("music_chrome.zig").Appearance) void {
        if (family == .custom and self.has_custom) {
            self.using_custom = true;
        } else {
            self.using_custom = false;
            self.selected = &@import("builtin_themes.zig").plans[@backingInt(appearance)];
        }
        self.revision +%= 1;
    }

    pub fn load(self: *Store, bytes: []const u8, scratch: []u8) !void {
        const next = self.active ^ 1;
        try parse(bytes, scratch, &self.banks[next]);
        self.active = next;
        self.has_custom = true;
        self.using_custom = true;
        self.revision +%= 1;
    }
};

fn preflight(bytes: []const u8) !void {
    if (bytes.len > max_source) return error.ThemeTooLarge;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const byte = bytes[i];
        if (quoted) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') quoted = false;
            continue;
        }
        switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > 16) return error.ThemeTooDeep;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidTheme;
                depth -= 1;
            },
            else => {},
        }
    }
}

pub fn parse(bytes: []const u8, scratch: []u8, output: *Plan) !void {
    try preflight(bytes);
    var allocator = std.heap.FixedBufferAllocator.init(scratch);
    const document = try std.json.parseFromSliceLeaky(Document, allocator.allocator(), bytes, .{ .allocate = .alloc_always, .max_value_len = 4096, .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" });
    try compile(document, output);
}

fn color(value: []const u8) !u16 {
    if (value.len != 7 or value[0] != '#') return error.InvalidColor;
    const rgb = std.fmt.parseInt(u32, value[1..], 16) catch return error.InvalidColor;
    return ui.rgb(@intCast(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb));
}

fn pick(palette: Palette, token: Token) !u16 {
    inline for (@typeInfo(Palette).@"struct".field_names) |field| {
        if (std.mem.eql(u8, field, @tagName(token))) return color(@field(palette, field));
    }
    unreachable;
}

fn validRect(rect: Rect, width: u16, height: u16) bool {
    return rect.x >= 0 and rect.y >= 0 and rect.w > 0 and rect.h > 0 and @as(u32, @intCast(rect.x)) + rect.w <= width and @as(u32, @intCast(rect.y)) + rect.h <= height;
}

const Resolver = struct {
    nodes: []const Node,
    states: [32]u2 = @splat(0),
    rectangles: [32]Rect = @splat(.{}),
    fn resolve(self: *Resolver, rank: usize, width: u16, height: u16) anyerror!Rect {
        if (self.states[rank] == 1) return error.AnchorCycle;
        if (self.states[rank] == 2) return self.rectangles[rank];
        self.states[rank] = 1;
        const position = self.nodes[rank].rect;
        const x: i32 = position.x;
        var y: i32 = position.y;
        if (position.after) |name| {
            const target = for (self.nodes, 0..) |node, i| {
                if (std.mem.eql(u8, node.id, name)) break i;
            } else return error.MissingAnchor;
            const parent = try self.resolve(target, width, height);
            y += @as(i32, parent.y) + parent.h + position.gap;
        }
        const w: i32 = if (position.right) |right| @as(i32, width) - right - x else position.w;
        const h: i32 = if (position.bottom) |bottom| @as(i32, height) - bottom - y else position.h;
        if (x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > width or y + h > height) return error.OutsideCanvas;
        const rect = Rect{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(w), .h = @intCast(h) };
        self.rectangles[rank] = rect;
        self.states[rank] = 2;
        return rect;
    }
};

pub const Device = struct { width: u16, height: u16 };
pub fn compile(doc: Document, output: *Plan) !void {
    return compileFor(doc, .{ .width = ui.screen_width, .height = ui.screen_height }, output);
}

pub fn compileFor(doc: Document, device: Device, output: *Plan) !void {
    if (doc.version != 1) return error.UnsupportedThemeVersion;
    if (doc.name.len == 0 or doc.name.len > output.name.len or !std.unicode.utf8ValidateSlice(doc.name)) return error.InvalidName;
    output.* = std.mem.zeroes(Plan);
    output.width = device.width;
    output.height = device.height;
    output.name_length = @intCast(doc.name.len);
    @memcpy(output.name[0..doc.name.len], doc.name);
    output.paper = try color(doc.palette.paper);
    output.ink = try color(doc.palette.ink);
    output.muted = try color(doc.palette.muted);
    output.accent = try color(doc.palette.accent);
    output.line = try color(doc.palette.line);
    output.selected = try color(doc.palette.selected);
    output.selected_text = try color(doc.palette.selected_text);
    inline for (@typeInfo(Screens).@"struct".field_names, 0..) |field, page| {
        var nodes: [32]Node = undefined;
        const body = @field(doc.screens, field);
        if (doc.header.len + body.len > nodes.len) return error.TooManyPageNodes;
        const count = doc.header.len + body.len;
        @memcpy(nodes[0..doc.header.len], doc.header);
        @memcpy(nodes[doc.header.len..][0..body.len], body);
        for (nodes[0..count], 0..) |node, i| {
            if (node.id.len > 32) return error.InvalidId;
            if (node.id.len != 0) for (nodes[0..i]) |before| {
                if (std.mem.eql(u8, before.id, node.id)) return error.DuplicateId;
            };
        }
        var resolver = Resolver{ .nodes = nodes[0..count] };
        var span = Span{ .first = output.count };
        for (nodes[0..count], 0..) |node, i| {
            if (output.count == max_ops) return error.TooManyNodes;
            if (node.value.len > 48 or !std.unicode.utf8ValidateSlice(node.value)) return error.InvalidLiteral;
            if (node.kind == .artwork) span.flags |= Flags.artwork;
            if (node.kind == .transport) span.flags |= Flags.transport;
            const rect = try resolver.resolve(i, output.width, output.height);
            if (node.radius > 32 or node.columns == 0 or node.columns > 4 or node.row_height < 16 or node.lines == 0 or node.lines > 2 or node.reflection > 32 or node.edge < 32 or node.edge > 160) return error.InvalidWidget;
            if (node.kind == .list) {
                span.capacity = rect.h / (@as(u16, node.row_height) + node.gap) * node.columns;
                if (span.capacity == 0 or span.capacity > 12 or span.count > 32) return error.InvalidCapacity;
            }
            var op = Op{ .rect = rect, .kind = node.kind, .binding = node.binding, .role = node.role, .alignment = node.alignment, .color_slot = node.color, .background_slot = node.background, .focus_slot = node.focus, .focus_text_slot = node.focus_text, .color = try pick(doc.palette, node.color), .background = try pick(doc.palette, node.background), .focus = try pick(doc.palette, node.focus), .focus_text = try pick(doc.palette, node.focus_text), .radius = node.radius, .columns = node.columns, .row_height = node.row_height, .gap = node.gap, .lines = node.lines, .label_offset = node.label_offset, .detail = @intFromBool(node.detail), .condition = node.when, .edge = node.edge, .reflection = node.reflection, .progress = node.progress, .literal_length = @intCast(node.value.len) };
            op.literal_offset = try intern(output, node.value);
            op = prepareOp(op);
            output.ops[output.count] = op;
            output.count += 1;
            span.count += 1;
            if (page == @backingInt(Page.player) and node.kind == .transport) {
                const top: u16 = @intCast(@max(0, @as(i32, rect.y) - 4));
                const bottom: u16 = @intCast(@min(output.height, @as(i32, rect.y) + rect.h + 6));
                output.transport = .{ .x = 0, .y = @intCast(top), .w = output.width, .h = bottom - top };
            }
        }
        output.pages[page] = prepareSpan(output, span);
    }
    try validate(output);
}

fn intern(plan: *Plan, value: []const u8) !u16 {
    if (value.len == 0) return 0;
    if (std.mem.indexOf(u8, plan.literals[0..plan.literal_used], value)) |offset| return @intCast(offset);
    if (plan.literal_used + value.len > plan.literals.len) return error.ThemeTextBudget;
    const offset = plan.literal_used;
    @memcpy(plan.literals[offset..][0..value.len], value);
    plan.literal_used += @intCast(value.len);
    return offset;
}

fn prepareOp(input: Op) Op {
    var op = input;
    op.baseline_offset = -@as(i16, fonts.glyph(op.role, 'H').ink_y);
    op.row_label_offset = if (op.detail != 0 and op.columns > 1) 9 else @intCast(@divTrunc(@as(i32, op.row_height) - fonts.glyph(op.role, 'H').ink_height, 2));
    op.detail_label_offset = if (op.columns > 1) 30 else @intCast(@divTrunc(@as(i32, op.row_height) - 9, 2));
    const usable = op.rect.w -| (@as(u16, op.gap) * (op.columns -| 1));
    op.cell_width = usable / @max(1, op.columns);
    op.cell_stride = op.cell_width + op.gap;
    op.row_stride = @as(u16, op.row_height) + op.gap;
    op.line_height = switch (op.progress) {
        .bar => 12,
        .thin => 4,
        .thumb => 2,
    };
    op.line_radius = @min(op.radius, op.line_height / 2);
    return op;
}

fn prepareSpan(plan: *const Plan, input: Span) Span {
    var span = Span{ .first = input.first, .count = input.count, .scan_top = plan.height, .progress_top = plan.height };
    const ops = plan.ops[span.first..][0..span.count];
    for (ops, 0..) |*op, i| {
        if (op.kind == .artwork) span.flags |= Flags.artwork;
        if (op.kind == .transport) {
            span.flags |= Flags.transport;
            span.transport = @intCast(span.first + i);
        }
        if (op.kind == .progress and op.binding == .scan_progress) {
            span.scan_widgets |= @as(u32, 1) << @intCast(i);
            span.progress_top = @min(span.progress_top, @as(u16, @intCast(op.rect.y)));
            span.progress_bottom = @max(span.progress_bottom, @as(u16, @intCast(op.rect.y)) + op.rect.h);
        }
        if (op.kind == .now_playing) span.now_playing = @intCast(span.first + i);
        if (op.kind == .covers) span.covers = @intCast(span.first + i);
        if (op.kind == .list) {
            if (op.detail != 0) span.flags |= Flags.row_details;
            span.columns = op.columns;
            span.capacity = op.rect.h / (@as(u16, op.row_height) + op.gap) * op.columns;
        }
        if (op.binding == .page_detail) span.flags |= Flags.page_detail;
        if (op.binding == .library_phase) span.flags |= Flags.scan_phase;
        if (op.binding == .transport_state or op.kind == .playback_state) span.flags |= Flags.playback_phase;
        if (op.kind == .now_playing or op.kind == .playback_state or op.kind == .artwork or op.binding == .track_title or op.binding == .track_artist or op.binding == .track_album or op.binding == .codec or op.binding == .track_summary) span.flags |= Flags.track_metadata;
        if (op.condition == .scanning or op.binding == .scan_progress) {
            span.scan_top = @min(span.scan_top, @as(u16, @intCast(op.rect.y)));
            span.scan_bottom = @max(span.scan_bottom, @as(u16, @intCast(op.rect.y)) + op.rect.h);
        }
    }
    for (ops, 0..) |*op, i| {
        if (op.rect.y < span.scan_bottom and @as(i32, op.rect.y) + op.rect.h > span.scan_top) span.scan_mask |= @as(u32, 1) << @intCast(i);
        if (span.covers != no_widget) {
            const scene = plan.ops[span.covers].rect;
            if (op.rect.y < @as(i32, scene.y) + scene.h and @as(i32, op.rect.y) + op.rect.h > scene.y) span.covers_mask |= @as(u32, 1) << @intCast(i);
        }
        if (span.transport != no_widget and op.rect.y < @as(i32, plan.transport.y) + plan.transport.h and @as(i32, op.rect.y) + op.rect.h > plan.transport.y) {
            span.transport_mask |= @as(u32, 1) << @intCast(i);
            if (op.kind == .artwork) span.flags |= Flags.transport_artwork;
        }
        if (op.rect.y < span.progress_bottom and @as(i32, op.rect.y) + op.rect.h > span.progress_top) span.progress_mask |= @as(u32, 1) << @intCast(i);
    }
    return span;
}

pub fn validate(plan: *const Plan) !void {
    if (plan.width == 0 or plan.height == 0 or plan.width > 1024 or plan.height > 1024 or plan.count > max_ops or plan.name_length > 64 or plan.literal_used > plan.literals.len) return error.InvalidPlan;
    for (plan.pages, 0..) |span, page| {
        if (@as(u32, span.first) + span.count > plan.count or span.capacity > 12 or span.count > 32) return error.InvalidPlan;
        var navigation = false;
        var lists: usize = 0;
        var galleries: usize = 0;
        var transports: usize = 0;
        var transport = false;
        var title = false;
        for (plan.ops[span.first..][0..span.count]) |op| {
            if (!validRect(op.rect, plan.width, plan.height) or op.literal_length > 48 or op.columns == 0 or op.columns > 4 or op.row_height < 16 or op.radius > 32 or op.lines == 0 or op.lines > 2 or op.reflection > 32 or op.edge < 32 or op.edge > 160) return error.InvalidPlan;
            if (op.kind == .list) {
                lists += 1;
                if (op.rect.w <= @as(u16, op.gap) * (op.columns - 1) + @as(u16, op.columns) * 16) return error.InvalidCapacity;
                const expected: Binding = switch (@as(Page, @fromBackingInt(@intCast(page)))) {
                    .home => .home,
                    .artists => .artists,
                    .artist => .artist,
                    .tracks => .tracks,
                    .library => .library,
                    .menu => .menu,
                    else => return error.InvalidPlan,
                };
                if (op.binding != expected) return error.InvalidPlan;
            }
            if (op.kind == .covers) galleries += 1;
            if (op.kind == .transport) transports += 1;
            if (op.kind == .covers and (op.rect.x != 0 or op.rect.w != plan.width)) return error.InvalidPlan;
            if (op.kind == .playback_modes and (op.rect.w < 51 or op.rect.h < 16)) return error.InvalidPlan;
            if (op.kind == .playback_state and (op.rect.w != 12 or op.rect.h != 12)) return error.InvalidPlan;
            if (op.kind == .now_playing and (op.rect.w < 48 or op.rect.h < 12 or (op.lines == 2 and op.rect.h < 32))) return error.InvalidPlan;
            if (op.kind == .battery and (op.rect.w != 24 or op.rect.h != 14)) return error.InvalidPlan;
            if (op.kind == .transport and (@as(u16, op.label_offset) + 12 > op.rect.h)) return error.InvalidTransport;
            if (@as(u32, op.literal_offset) + op.literal_length > plan.literal_used) return error.InvalidLiteral;
            if (!std.unicode.utf8ValidateSlice(plan.literal(&op))) return error.InvalidLiteral;
            if (!std.meta.eql(op, prepareOp(op))) return error.InvalidPreparedWidget;
            if (op.kind == .list or op.kind == .covers) navigation = true;
            if (op.kind == .transport) transport = true;
            if (op.kind == .text and op.binding == .track_title) title = true;
        }
        if (!std.meta.eql(span, prepareSpan(plan, span))) return error.InvalidPreparedPage;
        if ((page == @backingInt(Page.albums) and galleries != 1) or (page != @backingInt(Page.albums) and galleries != 0) or (page == @backingInt(Page.player) and transports != 1) or (page != @backingInt(Page.player) and transports != 0) or lists > 1) return error.InvalidPlan;
        if (page != @backingInt(Page.player) and page != @backingInt(Page.jump) and !navigation) return error.MissingNavigation;
        if (page == @backingInt(Page.player) and (!transport or !title)) return error.MissingTransport;
    }
    if (!validRect(plan.transport, plan.width, plan.height)) return error.InvalidTransport;
}

test "bundled runtime JSON lowers to the same owned plans as the compiled fallback" {
    const sources = .{ @embedFile("themes/gain-light.json"), @embedFile("themes/gain-dark.json") };
    var scratch: [96 * 1024]u8 = undefined;
    var output: Plan = undefined;
    inline for (sources, 0..) |source, i| {
        try parse(source, &scratch, &output);
        try std.testing.expectEqualDeep(@import("builtin_themes.zig").plans[i], output);
    }
}

test "invalid custom themes retain the active plan and scratch ownership never escapes parsing" {
    var store = Store{};
    var scratch: [96 * 1024]u8 = undefined;
    const source = @embedFile("themes/gain-light.json");
    try store.load(source, &scratch);
    const first = store.current().*;
    @memset(&scratch, 0xaa);
    try std.testing.expectEqualDeep(first, store.current().*);
    const revision = store.revision;
    for ([_][]const u8{ "{}", "{\"version\":999}", "[[[[[[[[[[[[[[[[[0]]]]]]]]]]]]]]]]]", "{\"name\":\"a\",\"name\":\"b\"}" }) |invalid| {
        store.load(invalid, &scratch) catch {};
        try std.testing.expectEqual(revision, store.revision);
        try std.testing.expectEqualDeep(first, store.current().*);
    }
    var copy = store;
    try std.testing.expect(copy.current() != store.current());
    try std.testing.expectEqualDeep(first, copy.current().*);
}

test "missing custom theme uses requested fallback appearance without replacing a valid custom plan" {
    var scratch: [96 * 1024]u8 = undefined;
    for ([_]@import("music_chrome.zig").Appearance{ .light, .dark }) |appearance| {
        var fallback = Store{};
        fallback.select(.classic, appearance);
        var requested = Store{};
        requested.select(.custom, appearance);
        try std.testing.expect(!requested.using_custom and !requested.has_custom);
        try std.testing.expectEqualDeep(fallback.current().*, requested.current().*);
        try requested.load(@embedFile("themes/gain-light.json"), &scratch);
        const custom = requested.current().*;
        requested.select(.custom, appearance);
        try std.testing.expect(requested.using_custom);
        try std.testing.expectEqualDeep(custom, requested.current().*);
    }
}
