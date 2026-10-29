const x1000 = @import("x1000.zig");
const board = @import("f20_v27.zig");

const DramInitialization = enum(u32) {
    success,
    phy_configuration_timeout,
    phy_initialization_timeout,
    training_timeout,
    training_error,
    first_memory_test_failed,
    second_memory_test_failed,
};

fn initializeClock() void {
    x1000.Cpm.main_pll.clear(x1000.Cpm.main_pll_change_enable);
    while (x1000.Cpm.main_pll.read() & x1000.Cpm.main_pll_on != 0) asm volatile ("nop");
    x1000.Cpm.main_pll.write(board.clock.main_pll);
    while (x1000.Cpm.main_pll.read() & x1000.Cpm.main_pll_on == 0) asm volatile ("nop");

    x1000.Cpm.ddr_clock.write(
        (x1000.Cpm.ddr_clock.read() & ~board.clock.ddr_field_mask) | board.clock.ddr,
    );
    while (x1000.Cpm.status.read() & x1000.Cpm.ddr_divider_ready == 0) asm volatile ("nop");
    while (x1000.Cpm.ddr_clock.read() & x1000.Cpm.ddr_clock_busy != 0) asm volatile ("nop");
    x1000.Cpm.ddr_clock.clear(x1000.Cpm.ddr_clock_change_enable);
}

fn waitForPhyStatus(first: u32, second: u32, attempt_limit: u32) bool {
    var attempts_left = attempt_limit;
    while (attempts_left != 0) : (attempts_left -= 1) {
        const value = x1000.Ddr.phy.general_status.read();
        if (value == first or value == second) return true;
    }
    return false;
}

fn initializeDram() DramInitialization {
    x1000.Cpm.ungate(.ddr);
    x1000.Cpm.ddr_reset_clock_gate.write(board.ddr.reset_clock_gate_asserted);
    x1000.Timer.delayMicroseconds(3_000);
    x1000.Cpm.ddr_reset_clock_gate.write(board.ddr.reset_clock_gate_released);
    x1000.Timer.delayMicroseconds(3_000);
    x1000.Ddr.apb.phy_reset_config.write(board.ddr.phy_reset_asserted);
    x1000.Timer.delayMicroseconds(3_000);
    x1000.Ddr.apb.phy_reset_config.write(0);
    x1000.Timer.delayMicroseconds(3_000);
    x1000.Ddr.controller.control.write(board.ddr.controller_reset_asserted);
    x1000.Timer.delayMicroseconds(3_000);
    x1000.Ddr.controller.control.write(0);
    x1000.Timer.delayMicroseconds(3_000);

    x1000.Ddr.controller.config.write(board.ddr.controller_config_initial);
    x1000.Ddr.controller.control.write(board.ddr.command_configure);
    x1000.writeAll(&board.ddr.phy_profile);
    if (!waitForPhyStatus(7, x1000.Ddr.phy_training_complete, 10_000)) return .phy_configuration_timeout;

    x1000.Ddr.phy.ac_dll_control.write(0x80000000);
    x1000.Ddr.phy.system_general_config.clear(0x10);
    x1000.Ddr.phy.dll_general_control.set(0x800000);
    x1000.Ddr.phy.initialization.write(0x20020041);
    if (!waitForPhyStatus(0x0f, x1000.Ddr.phy_training_complete, 10_000)) return .phy_initialization_timeout;

    x1000.Ddr.apb.phy_reset_config.write(board.ddr.phy_training_reset);
    x1000.Timer.delayMicroseconds(3_000);
    x1000.Ddr.apb.phy_reset_config.write(0);
    x1000.Timer.delayMicroseconds(3_000);
    x1000.Ddr.controller.config.write(board.ddr.controller_config_training);
    x1000.Ddr.controller.control.write(board.ddr.command_configure);
    x1000.Ddr.phy.initialization.write(0x20020081);

    var attempts_left: u32 = 500_000;
    while (attempts_left != 0) : (attempts_left -= 1) {
        const value = x1000.Ddr.phy.general_status.read();
        if (value == x1000.Ddr.phy_training_complete or value & 0x70 != 0) break;
    }
    if (attempts_left == 0) return .training_timeout;
    const training_status = x1000.Ddr.phy.general_status.read();
    if (training_status & x1000.Ddr.phy_training_error_mask != 0 and training_status != 0) {
        return .training_error;
    }

    x1000.Ddr.controller.control.write(0);
    x1000.Ddr.controller.control.write(board.ddr.command_precharge_all);
    x1000.Ddr.controller.control.write(0);
    x1000.Ddr.controller.config.write(board.ddr.controller_config_initial);
    x1000.writeAll(&board.ddr.controller_profile);
    x1000.Ddr.controller.control.write(board.ddr.command_precharge_all);
    x1000.write32(x1000.Ddr.controller.refresh_count, board.ddr.refresh_count);
    x1000.Ddr.controller.control.write(board.ddr.final_control);
    x1000.writeAll(&board.ddr.remap_profile);
    x1000.Ddr.controller.status.clear(0x40);
    x1000.Cpm.ddr_clock.set(x1000.Cpm.ddr_clock_stop);
    x1000.Ddr.apb.clock_stop_config.write(board.ddr.clock_stop_configuration);
    x1000.Ddr.controller.auto_self_refresh.write(board.ddr.auto_self_refresh_enabled);

    const memory_cell: *volatile u32 = @ptrFromInt(board.ddr.memory_test_address);
    const saved = memory_cell.*;
    memory_cell.* = board.ddr.memory_test_pattern_1;
    if (memory_cell.* != board.ddr.memory_test_pattern_1) return .first_memory_test_failed;
    memory_cell.* = board.ddr.memory_test_pattern_2;
    if (memory_cell.* != board.ddr.memory_test_pattern_2) return .second_memory_test_failed;
    memory_cell.* = saved;
    return .success;
}

export fn spl_main() callconv(.c) void {
    x1000.Cpm.power_switch_0.write(board.power_switches[0]);
    x1000.Cpm.power_switch_1.write(board.power_switches[1]);
    x1000.Cpm.power_switch_2.write(board.power_switches[2]);
    x1000.Cpm.power_switch_3.write(board.power_switches[3]);
    initializeClock();
    x1000.Timer.initialize();
    if (initializeDram() != .success) while (true) asm volatile ("nop");
}
