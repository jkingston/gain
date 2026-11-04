//! Stable boundary between the UI, its storage worker and the optional engine.
const std = @import("std");
pub const Role = @import("../font_data.zig").Role;
pub const version = 2;
pub const max_text_bytes = 4096;
pub const max_width = 320;
pub const max_height = 48;
pub const mask_bytes = max_width * max_height;
pub const Locale = enum(u8) { automatic, japanese, simplified_chinese, traditional_chinese, korean };
pub const Result = enum(u32) { ready, invalid_text, unsupported, invalid_pack, exhausted, cancelled, io_error };
pub const Label = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    missing: u16 = 0,
    truncated: u8 = 0,
    rtl: u8 = 0,
    pixels: [mask_bytes]u8 = @splat(0),
};
pub const Request = extern struct {
    length: u16 = 0,
    width: u16 = max_width,
    role: Role = .body,
    locale: Locale = .automatic,
    ellipsis: u8 = 1,
    reserved: u8 = 0,
    text: [max_text_bytes]u8 = undefined,

    pub fn init(text: []const u8, role: Role, width: u16, locale: Locale, ellipsis: bool) !Request {
        if (text.len > max_text_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
        var request = Request{ .length = @intCast(text.len), .width = @min(width, max_width), .role = role, .locale = locale, .ellipsis = @intFromBool(ellipsis) };
        @memcpy(request.text[0..text.len], text);
        return request;
    }

    pub fn value(self: *const Request) []const u8 {
        return self.text[0..self.length];
    }
};
// Callbacks execute only on the storage owner. A short read is an error. Poll
// feeds the audio reservoir/watchdog and may cancel after USB takes ownership.
pub const Source = extern struct {
    context: *anyopaque,
    bytes: u32,
    read: *const fn (*anyopaque, u32, [*]u8, u32) callconv(.c) u32,
    poll: *const fn (*anyopaque) callconv(.c) bool,
};
pub const Statistics = extern struct {
    heap_live: u32 = 0,
    heap_peak: u32 = 0,
    heap_failures: u32 = 0,
    page_reads: u32 = 0,
    page_hits: u32 = 0,
    labels: u32 = 0,
    glyphs: u32 = 0,
    allocation_failure_bytes: u32 = 0,
};
/// Caller-owned buffers remain valid for the engine lifetime, including
/// shutdown/remount cycles: upstream process-wide caches retain small objects.
pub const Workspace = extern struct {
    primary: [*]align(16) u8,
    primary_bytes: u32,
    auxiliary: ?[*]align(16) u8 = null,
    auxiliary_bytes: u32 = 0,
};
pub const Api = extern struct {
    version: u32 = version,
    initialize: *const fn (*const Source, *const Workspace) callconv(.c) Result,
    prepare: *const fn (*const Request, *Label) callconv(.c) Result,
    shutdown: *const fn () callconv(.c) void,
    statistics: *const fn (*Statistics) callconv(.c) void,
};
