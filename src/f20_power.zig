//! F20 PMIC discovery and board wiring; portable register policy lives in axp192.
const board = @import("f20_v27.zig");
const i2c = @import("i2c.zig");
const axp = @import("axp192.zig");

pub const Controller = axp.Device(i2c.Bus);

pub fn initialize() !Controller {
    var primary = Controller.init(i2c.Bus.init(board.pmic.primary.scl, board.pmic.primary.sda), board.pmic.address);
    primary.identify() catch {
        var alternate = Controller.init(i2c.Bus.init(board.pmic.alternate.scl, board.pmic.alternate.sda), board.pmic.address);
        try alternate.identify();
        try alternate.configureJackInputs();
        return alternate;
    };
    try primary.configureJackInputs();
    return primary;
}
