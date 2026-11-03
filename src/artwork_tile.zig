//! Decoder-independent artwork pixels, including the retained aspect-fit box.
pub const edge = 112;
pub const pixel_count = edge * edge;

pub const Tile = struct {
    pixels: [pixel_count]u16 = @splat(0),
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,
};
