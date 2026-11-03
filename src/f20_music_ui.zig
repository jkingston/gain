//! Concrete F20 adapter for the shared music interface.
const Platform = struct {
    pub const Display = @import("f20_display.zig");
    pub const Index = @import("f20_index.zig");
    pub const Diagnostics = @import("f20_diagnostics.zig");
    pub const now = @import("x1000.zig").Timer.now;
    pub const trace = @import("display_trace.zig").record;
};

pub const State = @import("music_ui.zig").Controller(Platform);
