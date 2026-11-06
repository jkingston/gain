//! One-owner Unicode layout and grayscale rasterisation. All upstream engines
//! use a bounded Zig pool; fonts are seekable SD streams, never whole-file RAM.
const std = @import("std");
const c = @import("text_c");
const abi = @import("contract.zig");
const pack = @import("pack.zig");
const runtime = @import("runtime.zig");
const Pool = @import("../codec_pool.zig").Pool;
const max_scalars = abi.max_text_bytes;
const max_glyphs = 8192;
const page_bytes = 4096;
const page_count = 32;
const Glyph = struct { family: u16, index: u32, x: i32, y: i32 };

const FaceSlot = struct {
    face: c.FT_Face = null,
    font: ?*c.hb_font_t = null,
    family: u16 = 0xffff,
    role: abi.Role = .body,
    offset: u32 = 0,
    stream: c.FT_StreamRec = std.mem.zeroes(c.FT_StreamRec),
    used: u32 = 0,
    heavy: bool = false,
};
comptime {
    _ = runtime;
}

var pool: ?Pool = null;
var auxiliary_pool: ?Pool = null;
var source: abi.Source = undefined;
var header: ?pack.Header = null;
var ft_library: c.FT_Library = null;
var ft_face: c.FT_Face = null;
var hb_font: ?*c.hb_font_t = null;
var face_slots: [2]FaceSlot = @splat(.{});
var face_clock: u32 = 0;
var baselines: [5]?i32 = @splat(null);
var ft_memory: c.FT_MemoryRec_ = undefined;
var pages: [page_count][page_bytes]u8 = undefined;
var tags: [page_count]u32 = @splat(0xffffffff);
var page_next: usize = 0;
var scalars: [max_scalars + 1]u32 = undefined;
var scripts: [max_scalars + 1]u32 = undefined;
var families: [max_scalars + 1]u16 = undefined;
var breaks: [max_scalars + 2]usize = undefined;
var glyphs: [max_glyphs]Glyph = undefined;
var face_records: [pack.max_faces][pack.face_bytes]u8 = undefined;
var range_records: [pack.max_ranges][pack.range_bytes]u8 = undefined;
var glyph_count: usize = 0;
var ink_left: i32 = 0;
var ink_right: i32 = 0;
var cancelled: bool = false;
var io_failed: bool = false;
var missing: u16 = 0;
var statistics: abi.Statistics = .{};
var attempt_failures: u32 = 0;
var selected_locale: abi.Locale = .automatic;
var face_open_count: u32 = 0;

pub const api = abi.Api{ .initialize = initialize, .prepare = prepare, .shutdown = shutdown, .statistics = snapshot };

comptime {
    if (@import("builtin").cpu.arch == .mipsel) {
        @export(&gain_text_malloc, .{ .name = "malloc" });
        @export(&gain_text_calloc, .{ .name = "calloc" });
        @export(&gain_text_realloc, .{ .name = "realloc" });
        @export(&gain_text_free, .{ .name = "free" });
    }
}

fn rememberPeak() void {
    const live = (if (pool) |p| p.statistics.live else @as(u32, 0)) + (if (auxiliary_pool) |p| p.statistics.live else @as(u32, 0));
    statistics.heap_peak = @max(statistics.heap_peak, live);
}

export fn gain_text_malloc(bytes: usize) ?*anyopaque {
    if (bytes == 0) return null;
    const primary = if (pool) |*p| p else return null;
    var selected = primary;
    if (auxiliary_pool) |*auxiliary| {
        const preferred = if (bytes < 64 * 1024) auxiliary else primary;
        const fallback = if (preferred == primary) auxiliary else primary;
        if (preferred.largestFreeBlock() >= bytes) selected = preferred else if (fallback.largestFreeBlock() >= bytes) selected = fallback;
    }
    const result = selected.allocate(bytes);
    if (result == null) statistics.allocation_failure_bytes = @intCast(@min(bytes, std.math.maxInt(u32)));
    rememberPeak();
    return result;
}

fn owner(pointer: *anyopaque) ?*Pool {
    const address = @intFromPtr(pointer);
    if (auxiliary_pool) |*p| {
        const start = @intFromPtr(p.storage.ptr);
        if (address >= start and address < start + p.storage.len) return p;
    }
    if (pool) |*p| {
        const start = @intFromPtr(p.storage.ptr);
        if (address >= start and address < start + p.storage.len) return p;
    }
    return null;
}

export fn gain_text_free(pointer: ?*anyopaque) void {
    const address = pointer orelse return;
    (owner(address) orelse @trap()).release(address);
}

export fn gain_text_realloc(pointer: ?*anyopaque, bytes: usize) ?*anyopaque {
    const old = pointer orelse return gain_text_malloc(bytes);
    if (bytes == 0) {
        gain_text_free(old);
        return null;
    }
    const p = owner(old) orelse @trap();
    const old_bytes = p.allocationSize(old);
    if (bytes <= old_bytes) return p.resize(old, bytes);
    const replacement = gain_text_malloc(bytes) orelse return null;
    @memcpy(@as([*]u8, @ptrCast(replacement))[0..old_bytes], @as([*]const u8, @ptrCast(old))[0..old_bytes]);
    p.release(old);
    return replacement;
}

export fn gain_text_calloc(count: usize, bytes: usize) ?*anyopaque {
    const total = std.math.mul(usize, count, bytes) catch return null;
    const ptr = gain_text_malloc(total) orelse return null;
    @memset(@as([*]u8, @ptrCast(ptr))[0..total], 0);
    return ptr;
}

// Path-based FT entry points are intentionally unavailable. Only the checked
// SD stream callback above can supply font bytes, on the storage owner.
export fn FT_Stream_Open(_: c.FT_Stream, _: [*c]const u8) c.FT_Error {
    return c.FT_Err_Cannot_Open_Resource;
}

export fn FT_New_Memory() c.FT_Memory {
    // This engine is initialized only through FT_New_Library. Declining the
    // hosted convenience constructor prevents a second allocator ownership.
    return null;
}

export fn FT_Done_Memory(_: c.FT_Memory) void {}

// A few libc numeric helpers report parse/range errors through errno. The
// text owner has one private error cell; it never requires an OS TLS pointer.
export fn __errno_location() *c_int {
    return &runtime.errno;
}

export fn gain_text_strdup(value: [*:0]const u8) ?[*:0]u8 {
    const bytes = std.mem.span(value);
    const pointer = gain_text_malloc(bytes.len + 1) orelse return null;
    const output: [*]u8 = @ptrCast(pointer);
    @memcpy(output[0..bytes.len], bytes);
    output[bytes.len] = 0;
    return @ptrCast(output);
}

export fn gain_text_getenv(_: [*:0]const u8) ?[*:0]const u8 {
    // Font behaviour is fixed by the pack, never by the host environment.
    return null;
}

fn ftAllocate(_: c.FT_Memory, size: c_long) callconv(.c) ?*anyopaque {
    return if (size > 0) gain_text_malloc(@intCast(size)) else null;
}

fn ftFree(_: c.FT_Memory, pointer: ?*anyopaque) callconv(.c) void {
    gain_text_free(pointer);
}

fn ftResize(_: c.FT_Memory, _: c_long, size: c_long, pointer: ?*anyopaque) callconv(.c) ?*anyopaque {
    return if (size > 0) gain_text_realloc(pointer, @intCast(size)) else null;
}

fn poll() !void {
    if (cancelled) return error.Cancelled;
    if (source.poll(source.context)) {
        cancelled = true;
        return error.Cancelled;
    }
}

fn read(at: u32, output: []u8) !void {
    if (@as(u64, at) + output.len > source.bytes) return error.InvalidPack;
    var copied: usize = 0;
    while (copied < output.len) {
        try poll();
        const offset = at + @as(u32, @intCast(copied));
        const tag = offset / page_bytes;
        var slot: ?usize = null;
        for (tags, 0..) |old, i| if (old == tag) {
            slot = i;
            break;
        };
        if (slot == null) {
            statistics.page_reads +%= 1;
            slot = page_next;
            page_next = (page_next + 1) % page_count;
            tags[slot.?] = 0xffffffff;
            const count: u32 = @min(page_bytes, source.bytes - tag * page_bytes);
            if (source.read(source.context, tag * page_bytes, &pages[slot.?], count) != count) {
                io_failed = true;
                return error.Io;
            }
            tags[slot.?] = tag;
        } else statistics.page_hits +%= 1;
        const inside = offset % page_bytes;
        const count = @min(output.len - copied, page_bytes - inside);
        @memcpy(output[copied..][0..count], pages[slot.?][inside..][0..count]);
        copied += count;
    }
}

fn ftRead(input: c.FT_Stream, at: c_ulong, buffer: [*c]u8, length: c_ulong) callconv(.c) c_ulong {
    const stream = input.*;
    if (at > stream.size or length > stream.size - at) return if (length == 0) 1 else 0;
    if (length == 0) return 0;
    const offset: *const u32 = @ptrCast(@alignCast(stream.descriptor.pointer));
    read(offset.* + @as(u32, @intCast(at)), buffer[0..length]) catch return 0;
    return length;
}

fn releaseFace(slot: *FaceSlot) void {
    if (slot.font) |font| c.hb_font_destroy(font);
    if (slot.face != null) _ = c.FT_Done_Face(slot.face);
    slot.* = .{};
}

fn closeFace() void {
    for (&face_slots) |*slot| releaseFace(slot);
    hb_font = null;
    ft_face = null;
}

fn pixelSize(role: abi.Role) c_uint {
    return switch (role) {
        .body => 14,
        .title => 19,
        .serif => 27,
        .caption => 12,
        .reading => 16,
    };
}

fn largeLayoutTables(file: pack.Face) !bool {
    var sfnt: [12]u8 = undefined;
    try read(file.offset, &sfnt);
    const count = std.mem.readInt(u16, sfnt[4..6], .big);
    if (count > 256 or 12 + @as(u32, count) * 16 > file.bytes) return error.InvalidFont;
    var total: u64 = 0;
    for (0..count) |i| {
        var record: [16]u8 = undefined;
        try read(file.offset + 12 + @as(u32, @intCast(i)) * 16, &record);
        if (std.mem.eql(u8, record[0..4], "GSUB") or std.mem.eql(u8, record[0..4], "GPOS")) total += std.mem.readInt(u32, record[12..16], .big);
    }
    return total > pool.?.storage.len / 2;
}

fn openFace(family: u16, role: abi.Role) !void {
    face_clock +%= 1;
    const h = header orelse return error.InvalidPack;
    if (family >= h.faces) return error.InvalidPack;
    const weight: usize = switch (role) {
        .body, .caption => 0,
        .reading, .serif => 1,
        .title => 2,
    };
    const file = try pack.face(&face_records[family], weight, h);
    for (&face_slots) |*slot| {
        if (slot.face != null and slot.offset == file.offset) {
            if (slot.role != role) {
                if (c.FT_Set_Pixel_Sizes(slot.face, 0, pixelSize(role)) != 0) return error.InvalidFont;
                c.hb_ft_font_changed(slot.font);
            }
            slot.family = family;
            slot.role = role;
            slot.used = face_clock;
            ft_face = slot.face;
            hb_font = slot.font;
            return;
        }
    }
    const heavy = try largeLayoutTables(file);
    // Big contextual tables get one face, not two cached copies. Ordinary
    // Latin/CJK combinations keep the useful two-face fast path.
    if (heavy or face_slots[0].heavy or face_slots[1].heavy) closeFace();
    var slot = &face_slots[0];
    for (&face_slots) |*candidate| {
        if (candidate.face == null) {
            slot = candidate;
            break;
        }
        if (face_clock -% candidate.used > face_clock -% slot.used) slot = candidate;
    }
    releaseFace(slot);
    ft_face = null;
    hb_font = null;
    slot.offset = file.offset;
    slot.heavy = heavy;
    slot.stream.size = file.bytes;
    slot.stream.read = ftRead;
    slot.stream.descriptor.pointer = &slot.offset;
    var args = std.mem.zeroes(c.FT_Open_Args);
    args.flags = c.FT_OPEN_STREAM;
    args.stream = &slot.stream;
    if (comptime @import("builtin").is_test) face_open_count += 1;
    if (c.FT_Open_Face(ft_library, &args, 0, &slot.face) != 0) return error.InvalidFont;
    errdefer releaseFace(slot);
    if (c.FT_Set_Pixel_Sizes(slot.face, 0, pixelSize(role)) != 0) return error.InvalidFont;
    slot.font = c.hb_ft_font_create_referenced(slot.face) orelse return error.Exhausted;
    c.hb_ft_font_set_load_flags(slot.font, c.FT_LOAD_DEFAULT | c.FT_LOAD_TARGET_NORMAL);
    slot.family = family;
    slot.role = role;
    slot.used = face_clock;
    ft_face = slot.face;
    hb_font = slot.font;
}

fn familyFor(cp: u32, regional: bool) !u16 {
    const h = header.?;
    // Kana is a strong Japanese script. The pack's first-coverage fallback
    // may be another region's pan-CJK font; mixing that with Japanese Han
    // changes typography and needlessly opens two large CJK faces.
    if (regional and isKana(cp) and h.cjk[0] != 0xffff) return h.cjk[0];
    // Shared East Asian punctuation belongs with the regional CJK face too.
    // First-coverage mapping can otherwise introduce a third, Hong Kong face
    // into Latin/Japanese titles and thrash the two-face cache on every pass.
    if (regional and (isCjkPunctuation(cp) or (cp >= 0x3400 and cp <= 0x9fff) or (cp >= 0x20000 and cp <= 0x323af))) {
        const index: usize = switch (selected_locale) {
            .automatic, .japanese => 0,
            .simplified_chinese => 1,
            .traditional_chinese => 2,
            .korean => 3,
        };
        if (h.cjk[index] != 0xffff) return h.cjk[index];
    }
    var low: u32 = 0;
    var high = h.ranges;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const record = &range_records[middle];
        const first = pack.word(record, 0);
        const last = pack.word(record, 4);
        const family = pack.half(record, 8);
        if (first > last or last > 0x10ffff or family >= h.faces) return error.InvalidPack;
        if (cp < first) high = middle else if (cp > last) low = middle + 1 else return family;
    }
    return 0;
}

fn isKana(cp: u32) bool {
    return (cp >= 0x3040 and cp <= 0x30ff) or (cp >= 0x31f0 and cp <= 0x31ff) or
        (cp >= 0xff66 and cp <= 0xff9f) or (cp >= 0x1aff0 and cp <= 0x1afff) or
        (cp >= 0x1b000 and cp <= 0x1b16f);
}

fn isCjkPunctuation(cp: u32) bool {
    return (cp >= 0x3000 and cp <= 0x303f) or (cp >= 0xfe10 and cp <= 0xfe1f) or
        (cp >= 0xfe30 and cp <= 0xfe4f) or (cp >= 0xff01 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffee);
}

fn ignorable(cp: u32) bool {
    return cp == 0x200c or cp == 0x200d or cp == 0xfeff or (cp >= 0xfe00 and cp <= 0xfe0f) or
        (cp >= 0xe0100 and cp <= 0xe01ef) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069) or cp == 0x061c or cp == 0x200e or cp == 0x200f or (cp >= 0xe0020 and cp <= 0xe007f);
}

fn covers(family: u16, role: abi.Role, text: []const u32) !bool {
    try openFace(family, role);
    for (text) |cp| if (!ignorable(cp) and c.FT_Get_Char_Index(ft_face, cp) == 0) return false;
    return true;
}

fn chooseFamily(role: abi.Role, text: []const u32) !u16 {
    const mapped = try familyFor(text[0], false);
    const regional = try familyFor(text[0], true);
    if (regional != mapped and try covers(regional, role, text)) return regional;
    const preferred: u16 = if (mapped == 0 and role == .serif) 1 else mapped;
    if (text.len == 1 and preferred != 1) return preferred;
    if (try covers(preferred, role, text)) return preferred;
    // Try the cluster's base and mark mappings as whole-cluster candidates.
    // Never split an emoji sequence, conjunct or combining sequence by font.
    for (text) |cp| {
        if (ignorable(cp)) continue;
        const candidate = try familyFor(cp, false);
        if (try covers(candidate, role, text)) return candidate;
    }
    return try familyFor(text[0], false);
}

fn shapeRun(start: usize, end: usize, total: usize, script: u32, rtl: bool, role: abi.Role, cursor: *i32) !void {
    try openFace(families[start], role);
    const buffer = c.hb_buffer_create() orelse return error.Exhausted;
    defer c.hb_buffer_destroy(buffer);
    c.hb_buffer_set_direction(buffer, if (rtl) c.HB_DIRECTION_RTL else c.HB_DIRECTION_LTR);
    c.hb_buffer_set_script(buffer, script);
    const language: [*:0]const u8 = switch (selected_locale) {
        .automatic => "und",
        .japanese => "ja",
        .simplified_chinese => "zh-Hans",
        .traditional_chinese => "zh-Hant",
        .korean => "ko",
    };
    c.hb_buffer_set_language(buffer, c.hb_language_from_string(language, -1));
    c.hb_buffer_add_utf32(buffer, &scalars, @intCast(total), @intCast(start), @intCast(end - start));
    c.hb_shape(hb_font, buffer, null, 0);
    if (c.hb_buffer_allocation_successful(buffer) == 0) return error.Exhausted;
    var count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(buffer, &count);
    const positions = c.hb_buffer_get_glyph_positions(buffer, &count);
    if (count > max_glyphs - glyph_count) return error.Limit;
    for (0..count) |i| {
        const p = positions[i];
        glyphs[glyph_count] = .{ .family = families[start], .index = infos[i].codepoint, .x = cursor.* + p.x_offset, .y = p.y_offset };
        var extents: c.hb_glyph_extents_t = undefined;
        if (c.hb_font_get_glyph_extents(hb_font, infos[i].codepoint, &extents) != 0) {
            const left = cursor.* + p.x_offset + extents.x_bearing;
            ink_left = @min(ink_left, left);
            ink_right = @max(ink_right, left + extents.width);
        }
        if (infos[i].codepoint == 0) missing +|= 1;
        glyph_count += 1;
        cursor.* = std.math.add(i32, cursor.*, p.x_advance) catch return error.Limit;
    }
}

const Layout = struct { width: u32, rtl: bool };
fn layout(count: usize, role: abi.Role, base: u8) !Layout {
    glyph_count = 0;
    ink_left = 0;
    ink_right = 0;
    missing = 0;
    if (count == 0) return .{ .width = 0, .rtl = base == 1 };
    var seq = c.SBCodepointSequence{ .stringEncoding = c.SBStringEncodingUTF32, .stringBuffer = &scalars, .stringLength = count };
    const algorithm = c.SBAlgorithmCreate(&seq) orelse return error.Exhausted;
    defer c.SBAlgorithmRelease(algorithm);
    const paragraph = c.SBAlgorithmCreateParagraph(algorithm, 0, count, base) orelse return error.Exhausted;
    defer c.SBParagraphRelease(paragraph);
    const line = c.SBParagraphCreateLine(paragraph, 0, count) orelse return error.Exhausted;
    defer c.SBLineRelease(line);
    const locator = c.SBScriptLocatorCreate() orelse return error.Exhausted;
    defer c.SBScriptLocatorRelease(locator);
    c.SBScriptLocatorLoadCodepoints(locator, &seq);
    while (c.SBScriptLocatorMoveNext(locator) != 0) {
        const agent = c.SBScriptLocatorGetAgent(locator).*;
        if (agent.offset + agent.length > count) return error.InvalidText;
        @memset(scripts[agent.offset..][0..agent.length], c.SBScriptGetUnicodeTag(agent.script));
    }
    var grapheme_state: i32 = 0;
    var start: usize = 0;
    for (1..count + 1) |i| {
        if (i == count or c.utf8proc_grapheme_break_stateful(@intCast(scalars[i - 1]), @intCast(scalars[i]), &grapheme_state)) {
            const family = try chooseFamily(role, scalars[start..i]);
            @memset(families[start..i], family);
            start = i;
        }
    }
    var cursor: i32 = 0;
    const run_count = c.SBLineGetRunCount(line);
    const runs = c.SBLineGetRunsPtr(line)[0..run_count];
    for (runs) |run| {
        try poll();
        const end = @min(count, run.offset + run.length);
        const rtl = run.level & 1 != 0;
        if (rtl) {
            var right = end;
            while (right > run.offset) {
                var left = right - 1;
                while (left > run.offset and families[left - 1] == families[right - 1] and scripts[left - 1] == scripts[right - 1]) left -= 1;
                try shapeRun(left, right, count, scripts[left], true, role, &cursor);
                right = left;
            }
        } else {
            var left = run.offset;
            while (left < end) {
                var right = left + 1;
                while (right < end and families[right] == families[left] and scripts[right] == scripts[left]) right += 1;
                try shapeRun(left, right, count, scripts[left], false, role, &cursor);
                left = right;
            }
        }
    }
    return .{ .width = @intCast(@max(0, @divFloor(@max(cursor, ink_right) - ink_left + 63, 64))), .rtl = c.SBParagraphGetBaseLevel(paragraph) & 1 != 0 };
}

fn initialize(input: *const abi.Source, workspace: *const abi.Workspace) callconv(.c) abi.Result {
    cancelled = false;
    io_failed = false;
    attempt_failures = allocationFailures();
    shutdown();
    source = input.*;
    tags = @splat(0xffffffff);
    baselines = @splat(null);
    page_next = 0;
    if (pool == null) {
        pool = Pool.init(workspace.primary[0..workspace.primary_bytes]) catch return .exhausted;
        if (workspace.auxiliary) |storage| auxiliary_pool = Pool.init(storage[0..workspace.auxiliary_bytes]) catch return .exhausted;
        ft_memory = .{ .user = null, .alloc = ftAllocate, .free = ftFree, .realloc = ftResize };
        if (c.FT_New_Library(&ft_memory, &ft_library) != 0) return .exhausted;
        c.FT_Add_Default_Modules(ft_library);
    }
    var bytes_header: [pack.header_bytes]u8 = undefined;
    read(0, &bytes_header) catch return failure();
    header = pack.Header.decode(&bytes_header, source.bytes) catch return .invalid_pack;
    const h = header.?;
    read(h.face_offset, std.mem.sliceAsBytes(face_records[0..h.faces])) catch return failure();
    read(h.range_offset, std.mem.sliceAsBytes(range_records[0..h.ranges])) catch return failure();
    var previous: ?u32 = null;
    for (range_records[0..h.ranges]) |record| {
        const first = pack.word(&record, 0);
        const last = pack.word(&record, 4);
        if (first > last or last > 0x10ffff or pack.half(&record, 8) >= h.faces or
            (previous != null and first <= previous.?))
        {
            header = null;
            return .invalid_pack;
        }
        previous = last;
    }
    return .ready;
}

fn allocationFailures() u32 {
    return (if (pool) |p| p.statistics.failures else @as(u32, 0)) +% (if (auxiliary_pool) |p| p.statistics.failures else @as(u32, 0));
}

fn failure() abi.Result {
    return if (cancelled) .cancelled else if (io_failed) .io_error else if (allocationFailures() != attempt_failures) .exhausted else .invalid_pack;
}

fn prepare(request: *const abi.Request, output: *abi.Label) callconv(.c) abi.Result {
    cancelled = false;
    io_failed = false;
    attempt_failures = allocationFailures();
    output.* = .{};
    if (header == null) return .invalid_pack;
    // Large contextual tables are cold-work scratch, not resident face caches.
    // Dropping them after publication also prevents pixel-size changes from
    // fragmenting the fixed pools while cached label masks stay untouched.
    defer {
        for (&face_slots) |*slot| if (slot.heavy) releaseFace(slot);
        ft_face = null;
        hb_font = null;
    }
    if (request.length > abi.max_text_bytes or request.width > abi.max_width) return .invalid_text;
    const view = std.unicode.Utf8View.init(request.value()) catch return .invalid_text;
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint()) |cp| {
        // Labels are one line. Preserve the source but display separators as
        // spaces rather than passing paragraph breaks into a single-line UBA.
        scalars[count] = if (cp == 10 or cp == 13 or cp == 9 or cp == 0x2028 or cp == 0x2029) ' ' else cp;
        count += 1;
    }
    if (count == 0 or request.width == 0) return .ready;
    selected_locale = request.locale;
    var result = layout(count, request.role, c.SBLevelDefaultLTR) catch return failure();
    const rtl = result.rtl;
    if (result.width > request.width and request.ellipsis != 0) {
        var boundary_count: usize = 1;
        breaks[0] = 0;
        var state: i32 = 0;
        for (1..count) |i| {
            if (c.utf8proc_grapheme_break_stateful(@intCast(scalars[i - 1]), @intCast(scalars[i]), &state)) {
                breaks[boundary_count] = i;
                boundary_count += 1;
            }
        }
        var low: usize = 0;
        var high = boundary_count;
        // Re-shape at every candidate joining boundary. Save/restore only the
        // replaced scalar; original UTF-8 metadata is never changed.
        while (low + 1 < high) {
            const middle = low + (high - low) / 2;
            const cut = breaks[middle];
            const saved = scalars[cut];
            scalars[cut] = 0x2026;
            const candidate = layout(cut + 1, request.role, @intFromBool(rtl)) catch return failure();
            scalars[cut] = saved;
            if (candidate.width <= request.width) low = middle else high = middle;
        }
        var cut = breaks[low];
        scalars[cut] = 0x2026;
        result = layout(cut + 1, request.role, @intFromBool(rtl)) catch return failure();
        // Width need not be monotonic in a shaping font. Guarantee the final
        // candidate fits even when a ligature changes at a truncation point.
        while (result.width > request.width and low > 0) {
            low -= 1;
            cut = breaks[low];
            scalars[cut] = 0x2026;
            result = layout(cut + 1, request.role, @intFromBool(rtl)) catch return failure();
        }
        output.truncated = 1;
        if (result.width > request.width) {
            output.rtl = @intFromBool(rtl);
            return .ready;
        }
    }
    output.rtl = @intFromBool(rtl);
    output.missing = missing;
    raster(request.role, request.width, result.width, output) catch return failure();
    if (allocationFailures() != attempt_failures) {
        output.* = .{};
        return .exhausted;
    }
    statistics.labels +%= 1;
    statistics.glyphs +%= @intCast(glyph_count);
    return .ready;
}

fn raster(role: abi.Role, limit: u16, advance: u32, output: *abi.Label) !void {
    // Gather actual hinted bitmap bounds before blending. Negative bearings
    // and marks above the ascender must not be silently clipped.
    var min_x: i32 = 0;
    var max_x: i32 = @intCast(@min(advance, 65535));
    const line_height: u32 = switch (role) {
        .caption => 18,
        .body => 21,
        .reading => 24,
        .title => 28,
        .serif => 40,
    };
    const role_index = @backingInt(role);
    if (baselines[role_index] == null) {
        try openFace(if (role == .serif) 1 else 0, role);
        baselines[role_index] = @intCast(@divFloor(ft_face.*.size.*.metrics.ascender + 63, 64));
    }
    const baseline = baselines[role_index].?;
    var min_y: i32 = -baseline;
    var max_y: i32 = @as(i32, @intCast(line_height)) - baseline;
    for (glyphs[0..glyph_count]) |g| {
        try openFace(g.family, role);
        if (c.FT_Load_Glyph(ft_face, g.index, c.FT_LOAD_DEFAULT) != 0) return error.InvalidFont;
        const metrics = ft_face.*.glyph.*.metrics;
        const x = @divFloor(g.x + 32, 64) + @divFloor(metrics.horiBearingX, 64);
        const y = -@divFloor(g.y + 32, 64) - @divFloor(metrics.horiBearingY + 63, 64);
        min_x = @min(min_x, @as(i32, @intCast(x)));
        max_x = @max(max_x, @as(i32, @intCast(x + @divFloor(metrics.width + 63, 64))));
        min_y = @min(min_y, @as(i32, @intCast(y)));
        max_y = @max(max_y, @as(i32, @intCast(y + @divFloor(metrics.height + 63, 64))));
    }
    const natural_height: u32 = @intCast(@max(1, max_y - min_y));
    const height = line_height;
    // Very tall combining stacks scale uniformly into the bounded line mask.
    const numerator: u32 = @min(height, natural_height);
    const denominator = natural_height;
    const width: u32 = @min(limit, (@as(u32, @intCast(@max(0, max_x - min_x))) * numerator + denominator - 1) / denominator);
    output.width = @intCast(width);
    output.height = @intCast(height);
    const top: i32 = @intCast((height - @min(height, natural_height)) / 2);
    for (glyphs[0..glyph_count]) |g| {
        try poll();
        try openFace(g.family, role);
        if (c.FT_Load_Glyph(ft_face, g.index, c.FT_LOAD_DEFAULT) != 0 or c.FT_Render_Glyph(ft_face.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0) return error.InvalidFont;
        const slot = ft_face.*.glyph.*;
        const bitmap = slot.bitmap;
        if (bitmap.pixel_mode != c.FT_PIXEL_MODE_GRAY and bitmap.width != 0) return error.InvalidFont;
        const left = @divFloor(g.x + 32, 64) + slot.bitmap_left - min_x;
        const upper = -@divFloor(g.y + 32, 64) - slot.bitmap_top - min_y;
        const pitch: usize = @intCast(@abs(bitmap.pitch));
        for (0..bitmap.rows) |yy| {
            const source_row = if (bitmap.pitch < 0) bitmap.rows - 1 - yy else yy;
            const y = top + @divFloor((upper + @as(i32, @intCast(yy))) * @as(i32, @intCast(numerator)), @as(i32, @intCast(denominator)));
            if (y < 0 or y >= height) continue;
            for (0..bitmap.width) |xx| {
                const x = @divFloor((left + @as(i32, @intCast(xx))) * @as(i32, @intCast(numerator)), @as(i32, @intCast(denominator)));
                if (x < 0 or x >= width) continue;
                const alpha = bitmap.buffer[source_row * pitch + xx];
                const index = @as(usize, @intCast(y)) * abi.max_width + @as(usize, @intCast(x));
                const old: u32 = output.pixels[index];
                output.pixels[index] = @intCast(old + ((255 - old) * alpha + 127) / 255);
            }
        }
    }
}

fn shutdown() callconv(.c) void {
    closeFace();
    header = null;
    // HarfBuzz and SheenBidi keep process-lifetime default objects. Their pool
    // remains valid across media remounts; only the face/stream is replaced.
}

export fn ___errno_location() *c_int {
    return &runtime.errno;
}

fn snapshot(output: *abi.Statistics) callconv(.c) void {
    output.* = statistics;
    if (pool) |p| {
        output.heap_live = p.statistics.live;
        output.heap_failures = p.statistics.failures;
    }
    if (auxiliary_pool) |p| {
        output.heap_live += p.statistics.live;
        output.heap_failures += p.statistics.failures;
    }
}

/// Test builds compare the complete layout path with a direct, independently
/// itemised HarfBuzz buffer using the same pinned font and FT load settings.
pub const testing = if (@import("builtin").is_test) struct {
    pub fn faceOpens() u32 {
        return face_open_count;
    }

    pub fn expectLatinJapaneseFamilies() !void {
        var latin = false;
        var japanese = false;
        for (glyphs[0..glyph_count]) |g| {
            if (g.family == 0) latin = true else if (g.family == header.?.cjk[0]) japanese = true else return error.UnexpectedFallbackFace;
        }
        try std.testing.expect(latin and japanese);
    }

    pub fn expectJapaneseFamily() !void {
        try std.testing.expect(glyph_count != 0);
        for (glyphs[0..glyph_count]) |g| try std.testing.expectEqual(header.?.cjk[0], g.family);
    }

    pub fn expectRegionalFamily(cp: u32, region: usize) !void {
        try std.testing.expectEqual(header.?.cjk[region], try familyFor(cp, true));
    }

    pub fn expectDirectShaping(value: []const u8, role: abi.Role) !void {
        try std.testing.expect(glyph_count > 0);
        const family = glyphs[0].family;
        for (glyphs[0..glyph_count]) |g| try std.testing.expectEqual(family, g.family);
        try openFace(family, role);
        const buffer = c.hb_buffer_create().?;
        defer c.hb_buffer_destroy(buffer);
        c.hb_buffer_add_utf8(buffer, value.ptr, @intCast(value.len), 0, @intCast(value.len));
        c.hb_buffer_set_language(buffer, c.hb_language_from_string("und", -1));
        c.hb_buffer_guess_segment_properties(buffer);
        c.hb_shape(hb_font, buffer, null, 0);
        var count: c_uint = 0;
        const info = c.hb_buffer_get_glyph_infos(buffer, &count);
        const positions = c.hb_buffer_get_glyph_positions(buffer, &count);
        try std.testing.expectEqual(glyph_count, count);
        var cursor: i32 = 0;
        for (glyphs[0..glyph_count], 0..) |g, i| {
            try std.testing.expectEqual(info[i].codepoint, g.index);
            try std.testing.expectEqual(cursor + positions[i].x_offset, g.x);
            try std.testing.expectEqual(positions[i].y_offset, g.y);
            cursor += positions[i].x_advance;
        }
    }
} else struct {};
