fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

fn read32(address: usize) u32 {
    return reg(address).*;
}

fn write32(address: usize, value: u32) void {
    reg(address).* = value;
}

const Timer = struct {
    const count = 0xb2000020;

    fn now() u32 {
        return read32(count);
    }

    fn elapsed(start: u32) u32 {
        return now() -% start;
    }

    fn delayUs(microseconds: u32) void {
        const start = now();
        const ticks = microseconds * 6;
        while (elapsed(start) < ticks) asm volatile ("nop");
    }
};

const Gpio = struct {
    const base = 0xb0010000;

    fn address(port: usize, offset: usize) usize {
        return base + port * 0x100 + offset;
    }

    fn output(port: usize, pin: u5, high: bool) void {
        const mask = @as(u32, 1) << pin;
        write32(address(port, 0x18), mask);
        write32(address(port, 0x24), mask);
        write32(address(port, 0x38), mask);
        set(port, pin, high);
    }

    fn input(port: usize, pin: u5) void {
        const mask = @as(u32, 1) << pin;
        write32(address(port, 0x18), mask);
        write32(address(port, 0x24), mask);
        write32(address(port, 0x34), mask);
        write32(address(port, 0x48), mask);
        write32(address(port, 0x74), mask);
    }

    fn device1(port: usize, mask: u32) void {
        write32(address(port, 0x18), mask);
        write32(address(port, 0x28), mask);
        write32(address(port, 0x38), mask);
        write32(address(port, 0x44), mask);
    }

    fn set(port: usize, pin: u5, high: bool) void {
        write32(address(port, if (high) 0x44 else 0x48), @as(u32, 1) << pin);
    }

    fn get(port: usize, pin: u5) bool {
        return read32(address(port, 0x00)) & (@as(u32, 1) << pin) != 0;
    }
};

const Watchdog = struct {
    const data = 0xb0002000;
    const enable = 0xb0002004;
    const count = 0xb0002008;
    const control = 0xb000200c;
    const stop_clear = 0xb000203c;

    fn start() void {
        write32(stop_clear, 1 << 16);
        write32(enable, 0);
        write32(control, (5 << 3) | 4); // external 24 MHz clock divided by 1024
        write32(count, 0);
        write32(data, 65_000); // approximately 2.77 seconds
        write32(enable, 1);
    }

    fn kick() void {
        write32(count, 0);
    }
};

const I2c = struct {
    port: usize,
    scl: u5,
    sda: u5,

    fn low(self: I2c, pin: u5) void {
        Gpio.output(self.port, pin, false);
    }

    fn release(self: I2c, pin: u5) void {
        Gpio.input(self.port, pin);
    }

    fn clock(self: I2c, high: bool) void {
        if (high) self.release(self.scl) else self.low(self.scl);
        Timer.delayUs(4);
    }

    fn dataLine(self: I2c, high: bool) void {
        if (high) self.release(self.sda) else self.low(self.sda);
        Timer.delayUs(4);
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
        const acknowledged = !Gpio.get(self.port, self.sda);
        self.clock(false);
        return acknowledged;
    }

    fn readByte(self: I2c) u8 {
        var value: u8 = 0;
        self.dataLine(true);
        var bit: u4 = 0;
        while (bit < 8) : (bit += 1) {
            self.clock(true);
            value = (value << 1) | @intFromBool(Gpio.get(self.port, self.sda));
            self.clock(false);
        }
        self.dataLine(true);
        self.clock(true);
        self.clock(false); // NACK
        return value;
    }

    fn readRegister(self: I2c, device: u7, index: u8, value: *u8) bool {
        self.start();
        if (!self.writeByte(@as(u8, device) << 1) or !self.writeByte(index)) {
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

    fn writeRegister(self: I2c, device: u7, index: u8, value: u8) bool {
        self.start();
        const ok = self.writeByte(@as(u8, device) << 1) and
            self.writeByte(index) and self.writeByte(value);
        self.stop();
        return ok;
    }
};

const Display = struct {
    const lcd = 0xb3050000;
    const cpm_clkgr = 0xb0000020;
    const cpm_lpcdr = 0xb0000064;
    const pixels: [*]volatile u16 = @ptrFromInt(0xa0040000);

    const black: u16 = 0x0000;
    const white: u16 = 0xffff;
    const green: u16 = 0x07e0;
    const red: u16 = 0xf800;
    const cyan: u16 = 0x07ff;
    const yellow: u16 = 0xffe0;

    const panel_init = [_]u16{
        0x1c8, 0x0ff, 0x093, 0x042,
        0x136, 0x0d8, 0x13a, 0x005,
        0x1c0, 0x015, 0x015, 0x1c1,
        0x001, 0x1c5, 0x0da, 0x1b1,
        0x000, 0x01b, 0x1b4, 0x002,
        0x1e0, 0x00f, 0x013, 0x017,
        0x004, 0x013, 0x007, 0x040,
        0x039, 0x04f, 0x006, 0x00d,
        0x00a, 0x01f, 0x022, 0x000,
        0x1e1, 0x000, 0x021, 0x024,
        0x003, 0x00f, 0x005, 0x038,
        0x032, 0x049, 0x000, 0x009,
        0x008, 0x032, 0x035, 0x00f,
    };

    fn ready() bool {
        var timeout: u32 = 1_000_000;
        while (timeout != 0) : (timeout -= 1) {
            if (read32(lcd + 0xa8) & 1 == 0) return true;
        }
        return false;
    }

    fn send(value: u32) bool {
        if (!ready()) return false;
        write32(lcd + 0xac, value);
        return true;
    }

    fn command(value: u8) bool {
        return send(0x40000000 | @as(u32, value));
    }

    fn data(value: u8) bool {
        return send(value);
    }

    fn init() bool {
        Gpio.output(2, 25, false);
        Gpio.output(1, 13, false);
        Gpio.output(1, 14, false);
        Gpio.output(1, 16, true);
        Gpio.output(1, 18, true);
        Gpio.device1(0, 0x0000ffff);
        Gpio.device1(1, 0x001a0000);

        Gpio.set(1, 14, true);
        Timer.delayUs(20_000);
        Gpio.set(1, 13, true);
        Timer.delayUs(12_000);

        write32(cpm_lpcdr, 0x90000000 | 29);
        while (read32(cpm_lpcdr) & 0x08000000 != 0) asm volatile ("nop");
        write32(cpm_lpcdr, read32(cpm_lpcdr) & ~@as(u32, 0x10000000));
        write32(cpm_clkgr, read32(cpm_clkgr) & ~@as(u32, 1 << 23));

        write32(lcd + 0xa0, 0x00000100);
        write32(lcd + 0xb8, 0x00000000);
        write32(lcd + 0xa4, 0x00000114);
        write32(lcd + 0xb0, 0);
        write32(lcd + 0xb4, 0);
        write32(lcd + 0xbc, 0);
        write32(lcd + 0x30, 0x40000000);
        write32(lcd + 0x10, 320);
        write32(lcd + 0x14, 240);

        Gpio.set(1, 16, true);
        Gpio.set(1, 18, true);
        Timer.delayUs(5_000);
        Gpio.set(1, 18, false);

        for (panel_init) |item| {
            if (item & 0x100 != 0) {
                if (!command(@truncate(item))) return false;
            } else if (!data(@truncate(item))) return false;
        }
        if (!command(0x11)) return false;
        Timer.delayUs(120_000);
        if (!command(0x29)) return false;
        Timer.delayUs(20_000);
        return true;
    }

    fn setWindow() bool {
        if (!command(0x2a)) return false;
        if (!data(0) or !data(0) or !data(1) or !data(0x3f)) return false;
        if (!command(0x2b)) return false;
        if (!data(0) or !data(0) or !data(0) or !data(0xef)) return false;
        return command(0x2c);
    }

    fn clear(color: u16) void {
        var index: usize = 0;
        while (index < 320 * 240) : (index += 1) pixels[index] = color;
    }

    fn rectangle(x: usize, y: usize, width: usize, height: usize, color: u16) void {
        var py = y;
        while (py < y + height and py < 240) : (py += 1) {
            var px = x;
            while (px < x + width and px < 320) : (px += 1) pixels[py * 320 + px] = color;
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
        while (index < 320 * 240) : (index += 1) {
            const pixel = pixels[index];
            if (!data(@truncate(pixel >> 8)) or !data(@truncate(pixel))) return false;
        }
        Gpio.set(2, 25, true);
        return true;
    }
};

const Button = struct {
    port: usize,
    pin: u5,
    label: []const u8,
};

const buttons = [_]Button{
    .{ .port = 0, .pin = 16, .label = "PLAY" },
    .{ .port = 0, .pin = 17, .label = "VOL+" },
    .{ .port = 0, .pin = 19, .label = "VOL-" },
    .{ .port = 1, .pin = 28, .label = "MENU" },
    .{ .port = 3, .pin = 4, .label = "PREV" },
    .{ .port = 2, .pin = 24, .label = "NEXT" },
    .{ .port = 3, .pin = 5, .label = "BACK" },
    .{ .port = 1, .pin = 7, .label = "POWER" },
};

var display_ready = false;

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
    Gpio.output(2, 25, false);
    while (true) {
        Gpio.set(2, 25, true);
        Timer.delayUs(150_000);
        Gpio.set(2, 25, false);
        Timer.delayUs(150_000);
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
    Display.rectangle(0, 0, 320, 34, Display.red);
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
    Display.rectangle(0, 0, 320, 28, 0x18e3);
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
    for (buttons, 0..) |button, index| {
        const x = 8 + (index % 4) * 78;
        const y = 100 + (index / 4) * 28;
        const observed = seen & (@as(u8, 1) << @intCast(index)) != 0;
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
    if (!pmic.readRegister(0x34, 0x32, &control) or
        !pmic.writeRegister(0x34, 0x32, control | 0x80))
    {
        showPanic(0x504d4943, 0, 0); // PMIC
    }
    const start = Timer.now();
    while (Timer.elapsed(start) < 6_000_000) Watchdog.kick();
    showPanic(0x504f5745, 0, 0); // POWE: power-off returned unexpectedly
}

export fn gain_main() callconv(.c) noreturn {
    if (!Display.init()) rawPanicBlink();
    display_ready = true;
    Watchdog.start();
    Watchdog.kick();

    for (buttons) |button| Gpio.input(button.port, button.pin);
    Gpio.input(1, 23);
    Gpio.input(1, 24);

    var pmic = I2c{ .port = 3, .scl = 0, .sda = 1 };
    var status: u8 = 0;
    var pmic_ok = pmic.readRegister(0x34, 0x00, &status);
    if (!pmic_ok) {
        pmic = .{ .port = 3, .scl = 1, .sda = 0 };
        pmic_ok = pmic.readRegister(0x34, 0x00, &status);
    }
    var battery_high: u8 = 0;
    var battery_low: u8 = 0;
    if (pmic_ok) {
        _ = pmic.readRegister(0x34, 0x78, &battery_high);
        _ = pmic.readRegister(0x34, 0x79, &battery_low);
    }
    const battery_mv = ((@as(u32, battery_high) << 4) | (battery_low & 0x0f)) * 11 / 10;

    var raw_buttons: u8 = 0;
    var stable_buttons: u8 = 0;
    var stable_samples: u3 = 0;
    var seen: u8 = 0;
    var old_wheel: u2 = @truncate((@as(u2, @intFromBool(Gpio.get(1, 24))) << 1) |
        @intFromBool(Gpio.get(1, 23)));
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
        for (buttons, 0..) |button, index| {
            if (!Gpio.get(button.port, button.pin)) sample |= @as(u8, 1) << @intCast(index);
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

        const new_wheel: u2 = @truncate((@as(u2, @intFromBool(Gpio.get(1, 24))) << 1) |
            @intFromBool(Gpio.get(1, 23)));
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

        const power_down = stable_buttons & (1 << 7) != 0;
        if (power_down) {
            if (power_started == null) power_started = Timer.now();
            if (Timer.elapsed(power_started.?) > 9_000_000) powerOff(pmic);
        } else power_started = null;

        const panic_down = stable_buttons & ((1 << 3) | (1 << 6)) == ((1 << 3) | (1 << 6));
        if (panic_down) {
            if (panic_started == null) panic_started = Timer.now();
            if (Timer.elapsed(panic_started.?) > 6_000_000) showPanic(0x4d414e55, 0, 0); // MANU
        } else panic_started = null;

        if (changed and Timer.elapsed(last_draw) > 120_000) {
            if (!drawMain(pmic_ok, battery_mv, seen, clockwise, counter_clockwise)) rawPanicBlink();
            last_draw = Timer.now();
        }
        Timer.delayUs(1_000);
    }
}
