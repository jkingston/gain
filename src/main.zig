const x1000 = @import("x1000.zig");
const board = @import("f20_v27.zig");

const Timer = x1000.Timer;
const Pin = x1000.Gpio.Pin;
const Watchdog = x1000.Watchdog;

const I2c = struct {
    scl: Pin,
    sda: Pin,

    fn low(_: I2c, pin: Pin) void {
        pin.output(false);
    }

    fn release(_: I2c, pin: Pin) void {
        pin.input();
    }

    fn clock(self: I2c, high: bool) void {
        if (high) self.release(self.scl) else self.low(self.scl);
        Timer.delayMicroseconds(4);
    }

    fn dataLine(self: I2c, high: bool) void {
        if (high) self.release(self.sda) else self.low(self.sda);
        Timer.delayMicroseconds(4);
    }

    fn start(self: I2c) void {
        self.dataLine(true);
        self.clock(true);
        self.dataLine(false);
        self.clock(false);
    }

    fn stop(self: I2c) void {
        self.dataLine(false);
        self.clock(true);
        self.dataLine(true);
    }

    fn writeByte(self: I2c, value: u8) bool {
        var mask: u8 = 0x80;
        while (mask != 0) : (mask >>= 1) {
            self.dataLine(value & mask != 0);
            self.clock(true);
            self.clock(false);
        }
        self.dataLine(true);
        self.clock(true);
        const acknowledged = !self.sda.get();
        self.clock(false);
        return acknowledged;
    }

    fn readByte(self: I2c) u8 {
        var value: u8 = 0;
        self.dataLine(true);
        var bit: u4 = 0;
        while (bit < 8) : (bit += 1) {
            self.clock(true);
            value = (value << 1) | @intFromBool(self.sda.get());
            self.clock(false);
        }
        self.dataLine(true);
        self.clock(true);
        self.clock(false); // NACK
        return value;
    }

    fn readRegister(self: I2c, device: u7, index: board.pmic.Register, value: *u8) bool {
        self.start();
        if (!self.writeByte(@as(u8, device) << 1) or !self.writeByte(@backingInt(index))) {
            self.stop();
            return false;
        }
        self.start();
        if (!self.writeByte((@as(u8, device) << 1) | 1)) {
            self.stop();
            return false;
        }
        value.* = self.readByte();
        self.stop();
        return true;
    }

    fn writeRegister(self: I2c, device: u7, index: board.pmic.Register, value: u8) bool {
        self.start();
        const ok = self.writeByte(@as(u8, device) << 1) and
            self.writeByte(@backingInt(index)) and self.writeByte(value);
        self.stop();
        return ok;
    }
};

const Display = struct {
    const width = board.display.width;
    const height = board.display.height;
    const pixels: [*]volatile u16 = @ptrFromInt(board.display.framebuffer_address);

    const black: u16 = 0x0000;
    const white: u16 = 0xffff;
    const green: u16 = 0x07e0;
    const red: u16 = 0xf800;
    const cyan: u16 = 0x07ff;
    const yellow: u16 = 0xffe0;

    fn ready() bool {
        var timeout: u32 = 1_000_000;
        while (timeout != 0) : (timeout -= 1) {
            if (x1000.Lcd.mcu_state.read() & x1000.Lcd.mcu_busy == 0) return true;
        }
        return false;
    }

    fn send(value: u32) bool {
        if (!ready()) return false;
        x1000.Lcd.mcu_data.write(value);
        return true;
    }

    fn command(value: board.display.Command) bool {
        return send(x1000.Lcd.command_flag | @as(u32, @backingInt(value)));
    }

    fn data(value: u8) bool {
        return send(value);
    }

    fn init() bool {
        board.display.backlight.output(false);
        board.display.reset.output(false);
        board.display.power.output(false);
        board.display.read_strobe.output(true);
        board.display.chip_enable.output(true);
        x1000.Gpio.selectFunction1(.a, board.display.port_a_function_1);
        x1000.Gpio.selectFunction1(.b, board.display.port_b_function_1);

        board.display.power.set(true);
        Timer.delayMicroseconds(20_000);
        board.display.reset.set(true);
        Timer.delayMicroseconds(12_000);

        x1000.Cpm.lcd_clock.write(board.display.clock_configuration);
        while (x1000.Cpm.lcd_clock.read() & x1000.Cpm.lcd_clock_busy != 0) asm volatile ("nop");
        x1000.Cpm.lcd_clock.clear(x1000.Cpm.lcd_clock_change_enable);
        x1000.Cpm.ungate(.lcd);

        x1000.Lcd.mcu_config.write(board.display.mcu_configuration);
        x1000.Lcd.mcu_config_new.write(0x00000000);
        x1000.Lcd.mcu_control.write(board.display.mcu_control);
        x1000.Lcd.write_time.write(0);
        x1000.Lcd.task_hold.write(0);
        x1000.Lcd.slow_write_time.write(0);
        x1000.Lcd.control.write(x1000.Lcd.direct_command_mode);
        x1000.Lcd.horizontal_area.write(width);
        x1000.Lcd.vertical_area.write(height);

        board.display.read_strobe.set(true);
        board.display.chip_enable.set(true);
        Timer.delayMicroseconds(5_000);
        board.display.chip_enable.set(false);

        for (board.display.initialization) |item| {
            if (board.display.isCommand(item)) {
                if (!command(@fromBackingInt(@intCast(@as(u8, @truncate(item)))))) return false;
            } else if (!data(@truncate(item))) return false;
        }
        if (!command(.sleep_out)) return false;
        Timer.delayMicroseconds(120_000);
        if (!command(.display_on)) return false;
        Timer.delayMicroseconds(20_000);
        return true;
    }

    fn setWindow() bool {
        if (!command(.column_address)) return false;
        if (!data(0) or !data(0) or !data(1) or !data(0x3f)) return false;
        if (!command(.page_address)) return false;
        if (!data(0) or !data(0) or !data(0) or !data(0xef)) return false;
        return command(.memory_write);
    }

    fn clear(color: u16) void {
        var index: usize = 0;
        while (index < width * height) : (index += 1) pixels[index] = color;
    }

    fn rectangle(x: usize, y: usize, rectangle_width: usize, rectangle_height: usize, color: u16) void {
        var py = y;
        while (py < y + rectangle_height and py < Display.height) : (py += 1) {
            var px = x;
            while (px < x + rectangle_width and px < Display.width) : (px += 1) pixels[py * Display.width + px] = color;
        }
    }

    fn glyph(character: u8) [7]u8 {
        return switch (character) {
            'A' => .{ 14, 17, 17, 31, 17, 17, 17 },
            'B' => .{ 30, 17, 17, 30, 17, 17, 30 },
            'C' => .{ 14, 17, 16, 16, 16, 17, 14 },
            'D' => .{ 30, 17, 17, 17, 17, 17, 30 },
            'E' => .{ 31, 16, 16, 30, 16, 16, 31 },
            'F' => .{ 31, 16, 16, 30, 16, 16, 16 },
            'G' => .{ 14, 17, 16, 23, 17, 17, 15 },
            'H' => .{ 17, 17, 17, 31, 17, 17, 17 },
            'I' => .{ 14, 4, 4, 4, 4, 4, 14 },
            'J' => .{ 7, 2, 2, 2, 18, 18, 12 },
            'K' => .{ 17, 18, 20, 24, 20, 18, 17 },
            'L' => .{ 16, 16, 16, 16, 16, 16, 31 },
            'M' => .{ 17, 27, 21, 21, 17, 17, 17 },
            'N' => .{ 17, 25, 21, 19, 17, 17, 17 },
            'O' => .{ 14, 17, 17, 17, 17, 17, 14 },
            'P' => .{ 30, 17, 17, 30, 16, 16, 16 },
            'Q' => .{ 14, 17, 17, 17, 21, 18, 13 },
            'R' => .{ 30, 17, 17, 30, 20, 18, 17 },
            'S' => .{ 15, 16, 16, 14, 1, 1, 30 },
            'T' => .{ 31, 4, 4, 4, 4, 4, 4 },
            'U' => .{ 17, 17, 17, 17, 17, 17, 14 },
            'V' => .{ 17, 17, 17, 17, 17, 10, 4 },
            'W' => .{ 17, 17, 17, 21, 21, 21, 10 },
            'X' => .{ 17, 17, 10, 4, 10, 17, 17 },
            'Y' => .{ 17, 17, 10, 4, 4, 4, 4 },
            'Z' => .{ 31, 1, 2, 4, 8, 16, 31 },
            '0' => .{ 14, 17, 19, 21, 25, 17, 14 },
            '1' => .{ 4, 12, 4, 4, 4, 4, 14 },
            '2' => .{ 14, 17, 1, 2, 4, 8, 31 },
            '3' => .{ 30, 1, 1, 14, 1, 1, 30 },
            '4' => .{ 2, 6, 10, 18, 31, 2, 2 },
            '5' => .{ 31, 16, 16, 30, 1, 1, 30 },
            '6' => .{ 14, 16, 16, 30, 17, 17, 14 },
            '7' => .{ 31, 1, 2, 4, 8, 8, 8 },
            '8' => .{ 14, 17, 17, 14, 17, 17, 14 },
            '9' => .{ 14, 17, 17, 15, 1, 1, 14 },
            '+' => .{ 0, 4, 4, 31, 4, 4, 0 },
            '-' => .{ 0, 0, 0, 31, 0, 0, 0 },
            ':' => .{ 0, 4, 4, 0, 4, 4, 0 },
            '/' => .{ 1, 1, 2, 4, 8, 16, 16 },
            '.' => .{ 0, 0, 0, 0, 0, 12, 12 },
            else => .{ 0, 0, 0, 0, 0, 0, 0 },
        };
    }

    fn text(x_start: usize, y: usize, value: []const u8, color: u16, scale: usize) void {
        var x = x_start;
        for (value) |character| {
            const rows = glyph(character);
            for (rows, 0..) |bits, row| {
                var column: usize = 0;
                while (column < 5) : (column += 1) {
                    if (bits & (@as(u8, 0x10) >> @intCast(column)) != 0) {
                        rectangle(x + column * scale, y + row * scale, scale, scale, color);
                    }
                }
            }
            x += 6 * scale;
        }
    }

    fn present() bool {
        if (!setWindow()) return false;
        var index: usize = 0;
        while (index < width * height) : (index += 1) {
            const pixel = pixels[index];
            if (!data(@truncate(pixel >> 8)) or !data(@truncate(pixel))) return false;
        }
        board.display.backlight.set(true);
        return true;
    }
};

var display_ready = false;

fn panicCode(comptime value: *const [4]u8) u32 {
    return @as(u32, value[0]) << 24 |
        @as(u32, value[1]) << 16 |
        @as(u32, value[2]) << 8 |
        value[3];
}

fn wheelState() u2 {
    return @truncate((@as(u2, @intFromBool(board.wheel.phase_b.get())) << 1) |
        @intFromBool(board.wheel.phase_a.get()));
}

fn hexDigit(value: u4) u8 {
    return if (value < 10) '0' + @as(u8, value) else 'A' + @as(u8, value) - 10;
}

fn hex32(value: u32, output: *[8]u8) void {
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        const shift: u5 = @intCast((7 - index) * 4);
        output[index] = hexDigit(@truncate(value >> shift));
    }
}

fn decimal4(value_initial: u32, output: *[4]u8) void {
    var value = value_initial;
    var index: usize = 4;
    while (index != 0) {
        index -= 1;
        output[index] = '0' + @as(u8, @truncate(value % 10));
        value /= 10;
    }
}

fn rawPanicBlink() noreturn {
    board.display.backlight.output(false);
    while (true) {
        board.display.backlight.set(true);
        Timer.delayMicroseconds(150_000);
        board.display.backlight.set(false);
        Timer.delayMicroseconds(150_000);
    }
}

fn showPanic(cause: u32, epc: u32, status: u32) noreturn {
    if (!display_ready) rawPanicBlink();
    var cause_text: [8]u8 = undefined;
    var epc_text: [8]u8 = undefined;
    var status_text: [8]u8 = undefined;
    hex32(cause, &cause_text);
    hex32(epc, &epc_text);
    hex32(status, &status_text);

    Display.clear(Display.black);
    Display.rectangle(0, 0, Display.width, 34, Display.red);
    Display.text(12, 8, "GAIN PANIC", Display.white, 2);
    Display.text(16, 58, "CAUSE", Display.white, 2);
    Display.text(130, 58, &cause_text, Display.yellow, 2);
    Display.text(16, 94, "EPC", Display.white, 2);
    Display.text(130, 94, &epc_text, Display.yellow, 2);
    Display.text(16, 130, "STATUS", Display.white, 2);
    Display.text(130, 130, &status_text, Display.yellow, 2);
    Display.text(16, 188, "WATCHDOG RESET", Display.cyan, 1);
    if (!Display.present()) rawPanicBlink();
    while (true) asm volatile ("nop");
}

export fn exception_panic(cause: u32, epc: u32, status: u32) callconv(.c) noreturn {
    showPanic(cause, epc, status);
}

fn drawMain(pmic_ok: bool, battery_mv: u32, seen: u8, clockwise: bool, counter_clockwise: bool) bool {
    Display.clear(Display.black);
    Display.rectangle(0, 0, Display.width, 28, 0x18e3);
    Display.text(10, 7, "GAIN PHASE 1", Display.white, 2);
    Display.text(8, 38, "NATIVE ZIG BOOT", Display.cyan, 1);
    Display.text(184, 38, "WDT", Display.white, 1);
    Display.text(220, 38, "ON", Display.green, 1);

    Display.text(8, 56, "PMIC", Display.white, 1);
    Display.text(52, 56, if (pmic_ok) "PASS" else "FAIL", if (pmic_ok) Display.green else Display.red, 1);
    var battery: [4]u8 = undefined;
    decimal4(battery_mv, &battery);
    Display.text(146, 56, "BAT", Display.white, 1);
    Display.text(182, 56, &battery, Display.cyan, 1);
    Display.text(212, 56, "MV", Display.white, 1);

    Display.text(8, 82, "PRESS EVERY CONTROL", Display.white, 1);
    for (board.buttons, 0..) |button, index| {
        const x = 8 + (index % 4) * 78;
        const y = 100 + (index / 4) * 28;
        const observed = seen & button.id.mask() != 0;
        Display.rectangle(x, y, 70, 20, if (observed) 0x0400 else 0x4000);
        Display.text(x + 5, y + 7, button.label, Display.white, 1);
    }
    Display.text(8, 163, "WHEEL", Display.white, 1);
    Display.text(62, 163, "CW", if (clockwise) Display.green else Display.yellow, 1);
    Display.text(100, 163, "CCW", if (counter_clockwise) Display.green else Display.yellow, 1);
    Display.text(8, 190, "HOLD POWER TO SHUT DOWN", Display.white, 1);
    Display.text(8, 208, "HOLD MENU+BACK FOR PANIC", Display.yellow, 1);
    Display.text(8, 226, "RAM ONLY  NO STORAGE WRITES", Display.green, 1);
    return Display.present();
}

fn showShutdown() bool {
    Display.clear(Display.black);
    Display.text(38, 92, "POWERING OFF", Display.white, 3);
    Display.text(82, 132, "AXP192", Display.cyan, 2);
    return Display.present();
}

fn powerOff(pmic: I2c) noreturn {
    Watchdog.kick();
    _ = showShutdown();
    var control: u8 = 0;
    if (!pmic.readRegister(board.pmic.address, .power_control, &control) or
        !pmic.writeRegister(board.pmic.address, .power_control, control | board.pmic.shutdown))
    {
        showPanic(panicCode("PMIC"), 0, 0);
    }
    const start = Timer.now();
    while (Timer.elapsed(start) < Timer.milliseconds(1_000)) Watchdog.kick();
    showPanic(panicCode("POWE"), 0, 0);
}

export fn gain_main() callconv(.c) noreturn {
    if (!Display.init()) rawPanicBlink();
    display_ready = true;
    Watchdog.start(.external, .by_1024, board.watchdog_timeout_ticks);
    Watchdog.kick();

    for (board.buttons) |button| button.pin.input();
    board.wheel.phase_a.input();
    board.wheel.phase_b.input();

    var pmic = I2c{ .scl = board.pmic.primary.scl, .sda = board.pmic.primary.sda };
    var status: u8 = 0;
    var pmic_ok = pmic.readRegister(board.pmic.address, .status, &status);
    if (!pmic_ok) {
        pmic = .{ .scl = board.pmic.alternate.scl, .sda = board.pmic.alternate.sda };
        pmic_ok = pmic.readRegister(board.pmic.address, .status, &status);
    }
    var battery_high: u8 = 0;
    var battery_low: u8 = 0;
    if (pmic_ok) {
        _ = pmic.readRegister(board.pmic.address, .battery_high, &battery_high);
        _ = pmic.readRegister(board.pmic.address, .battery_low, &battery_low);
    }
    const battery_mv = ((@as(u32, battery_high) << 4) | (battery_low & 0x0f)) * 11 / 10;

    var raw_buttons: u8 = 0;
    var stable_buttons: u8 = 0;
    var stable_samples: u3 = 0;
    var seen: u8 = 0;
    var old_wheel = wheelState();
    const wheel_table = [_]i8{ 0, -1, 1, 0, 1, 0, 0, -1, -1, 0, 0, 1, 0, 1, -1, 0 };
    var clockwise = false;
    var counter_clockwise = false;
    var power_started: ?u32 = null;
    var panic_started: ?u32 = null;

    if (!drawMain(pmic_ok, battery_mv, seen, clockwise, counter_clockwise)) rawPanicBlink();
    var last_draw = Timer.now();
    while (true) {
        Watchdog.kick();
        var sample: u8 = 0;
        for (board.buttons) |button| {
            if (!button.pin.get()) sample |= button.id.mask();
        }

        if (sample == raw_buttons) {
            if (stable_samples < 7) stable_samples += 1;
        } else {
            raw_buttons = sample;
            stable_samples = 0;
        }

        var changed = false;
        if (stable_samples == 3 and stable_buttons != raw_buttons) {
            stable_buttons = raw_buttons;
            const new_seen = seen | stable_buttons;
            changed = new_seen != seen;
            seen = new_seen;
        }

        const new_wheel = wheelState();
        if (new_wheel != old_wheel) {
            const direction = wheel_table[(@as(usize, old_wheel) << 2) | new_wheel];
            if (direction > 0 and !clockwise) {
                clockwise = true;
                changed = true;
            } else if (direction < 0 and !counter_clockwise) {
                counter_clockwise = true;
                changed = true;
            }
            old_wheel = new_wheel;
        }

        const power_down = stable_buttons & board.ButtonId.power.mask() != 0;
        if (power_down) {
            if (power_started == null) power_started = Timer.now();
            if (Timer.elapsed(power_started.?) > Timer.milliseconds(1_500)) powerOff(pmic);
        } else power_started = null;

        const panic_buttons = board.ButtonId.menu.mask() | board.ButtonId.back.mask();
        const panic_down = stable_buttons & panic_buttons == panic_buttons;
        if (panic_down) {
            if (panic_started == null) panic_started = Timer.now();
            if (Timer.elapsed(panic_started.?) > Timer.milliseconds(1_000)) {
                showPanic(panicCode("MANU"), 0, 0);
            }
        } else panic_started = null;

        if (changed and Timer.elapsed(last_draw) > Timer.milliseconds(20)) {
            if (!drawMain(pmic_ok, battery_mv, seen, clockwise, counter_clockwise)) rawPanicBlink();
            last_draw = Timer.now();
        }
        Timer.delayMicroseconds(1_000);
    }
}
