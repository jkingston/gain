//! Native desktop app boundary, not a firmware plugin interface.
//! Pixels use the same geometry and RGB565 values as the production renderer.
const ui = @import("ui.zig");

pub const width = ui.screen_width;
pub const height = ui.screen_height;
pub const Pixels = [ui.pixel_count]u16;
pub const abi_version = 2;
pub const pixel_format: u32 = 565;
pub const snapshot_capacity = 64 * 1024;

pub const Input = enum(u32) { up, down, select, back, menu, previous, next, volume_up, volume_down, power };

pub const Phase = enum(u32) { press, release, repeat };

pub const Event = extern struct { input: Input, phase: Phase = .press };

pub const Api = extern struct {
    version: u32 = abi_version,
    size: u32 = @sizeOf(Api),
    width: u32 = ui.screen_width,
    height: u32 = ui.screen_height,
    format: u32 = pixel_format,
    init: ?*const fn (u64) callconv(.c) void = null,
    input: ?*const fn (Event, u64) callconv(.c) void = null,
    /// Return false when pixels are unchanged. Time is monotonic milliseconds.
    frame: ?*const fn (*Pixels, u64) callconv(.c) bool = null,
    /// Optional paired callbacks. Oversized or rejected state cancels a reload.
    save: ?*const fn ([*]u8, usize) callconv(.c) usize = null,
    restore: ?*const fn ([*]const u8, usize, u64) callconv(.c) bool = null,

    /// Release app-owned resources before the module is unloaded.
    deinit: ?*const fn () callconv(.c) void = null,

    pub fn validate(self: *const Api) !void {
        if (self.version != abi_version) return error.IncompatibleAppVersion;
        if (self.size != @sizeOf(Api)) return error.IncompatibleAppLayout;
        if (self.width != ui.screen_width or self.height != ui.screen_height or self.format != pixel_format) return error.IncompatibleDisplay;
        if (self.init == null or self.input == null or self.frame == null) return error.MissingAppCallback;
        if ((self.save == null) != (self.restore == null)) return error.IncompleteSnapshotCallbacks;
    }
};
