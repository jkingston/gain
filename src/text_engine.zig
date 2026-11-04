//! Fixed-address text component entry, loaded from the SD card by stage two.
pub const panic = @import("std").debug.no_panic;
const engine = @import("text/engine.zig");
const contract = @import("text/contract.zig");

export fn gain_text_api() linksection(".startup") callconv(.c) *const contract.Api {
    return &engine.api;
}
