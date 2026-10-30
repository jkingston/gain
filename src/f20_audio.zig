const x1000 = @import("x1000.zig");
const board = @import("f20_v27.zig");
const audio = @import("audio.zig");

pub const Engine = audio.Engine(board.audio);
pub const Descriptor = x1000.Pdma.Descriptor;
pub const Buffer = audio.Buffer;
pub const Config = audio.Config;
pub const Event = audio.Event;
pub const maximum_descriptors = audio.maximum_descriptors;
pub const maximum_buffers = audio.maximum_buffers;

test "F20 audio specialization compiles its public driver API" {
    @import("std").testing.refAllDecls(Engine);
}
