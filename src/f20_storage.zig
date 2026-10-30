const x1000 = @import("x1000.zig");
const board = @import("f20_v27.zig");
const sd = @import("sd.zig");

pub const Controller = sd.Controller(board.storage);
pub const DmaDescriptor = x1000.Msc0.DmaDescriptor;
pub const fat32 = @import("fat32.zig");
pub const wav = @import("wav.zig");
