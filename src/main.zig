const x1000 = @import("x1000.zig");
const board = @import("f20_v27.zig");
const i2c = @import("i2c.zig");
const storage = @import("f20_storage.zig");
const media = @import("f20_media.zig");
const audio = @import("f20_audio.zig");
const fat32 = @import("fat32.zig");
const playback_controls = @import("playback_controls.zig");
const display_transfer = @import("display_transfer.zig");
const lcd_dma = @import("lcd_dma.zig");

const Timer = x1000.Timer;
const Watchdog = x1000.Watchdog;

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

    fn setAddressWindow(x: usize, y: usize, window_width: usize, window_height: usize) bool {
        const x_end = x + window_width - 1;
        const y_end = y + window_height - 1;
        if (!command(.column_address)) return false;
        if (!data(@truncate(x >> 8)) or !data(@truncate(x)) or
            !data(@truncate(x_end >> 8)) or !data(@truncate(x_end))) return false;
        if (!command(.page_address)) return false;
        if (!data(@truncate(y >> 8)) or !data(@truncate(y)) or
            !data(@truncate(y_end >> 8)) or !data(@truncate(y_end))) return false;
        return true;
    }

    fn setWindow(x: usize, y: usize, window_width: usize, window_height: usize) bool {
        return setAddressWindow(x, y, window_width, window_height) and command(.memory_write);
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
        const normalized = if (character >= 'a' and character <= 'z') character - ('a' - 'A') else character;
        return switch (normalized) {
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
            '>' => .{ 16, 8, 4, 2, 4, 8, 16 },
            '<' => .{ 1, 2, 4, 8, 4, 2, 1 },
            '?' => .{ 14, 17, 1, 2, 4, 0, 4 },
            '_' => .{ 0, 0, 0, 0, 0, 0, 31 },
            '\'' => .{ 4, 4, 2, 0, 0, 0, 0 },
            '%' => .{ 17, 2, 4, 8, 17, 0, 0 },
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
        return presentRegion(0, 0, width, height);
    }

    fn presentRegion(x: usize, y: usize, region_width: usize, region_height: usize) bool {
        if (LcdDma.transfer(x, y, region_width, region_height)) return true;
        LcdDma.resetForDirect();
        return presentRegionCpu(x, y, region_width, region_height);
    }

    fn presentRegionCpu(x: usize, y: usize, region_width: usize, region_height: usize) bool {
        if (region_width == 0 or region_height == 0 or x + region_width > width or
            y + region_height > height or !setWindow(x, y, region_width, region_height)) return false;
        var py = y;
        while (py < y + region_height) : (py += 1) {
            var px = x;
            while (px < x + region_width) : (px += 1) {
                const pixel = pixels[py * width + px];
                if (!data(@truncate(pixel >> 8)) or !data(@truncate(pixel))) return false;
            }
        }
        board.display.backlight.set(true);
        return true;
    }
};

const LcdDma = struct {
    const descriptors: *align(32) volatile lcd_dma.Chain = @ptrFromInt(board.display.dma_descriptor_address);
    const write_command: *align(64) volatile [4]u8 = @ptrFromInt(board.display.dma_command_address);
    const packed_pixels: *volatile [board.display.dma_staging_pixel_capacity]u16 =
        @ptrFromInt(board.display.dma_staging_address);
    const timeout_ticks = Timer.milliseconds(100);

    const Phase = enum { idle, transferring, draining, failed };
    const Poll = enum { idle, busy, failed };
    var phase: Phase = .idle;
    var started_at: u32 = 0;
    var output = lcd_dma.OutputState{};

    fn resetForDirect() void {
        x1000.Lcd.control.write(x1000.Lcd.burst_64_words);
        x1000.Lcd.mcu_control.write(board.display.mcu_control);
        x1000.Lcd.state.write(0);
        x1000.Lcd.mcu_config_new.write(0);
        x1000.Lcd.horizontal_area.write(Display.width);
        x1000.Lcd.vertical_area.write(Display.height);
        phase = .idle;
    }

    fn fail() void {
        resetForDirect();
        phase = .failed;
    }

    fn poll() Poll {
        switch (phase) {
            .idle => return .idle,
            .failed => return .failed,
            .transferring => {
                if (Timer.elapsed(started_at) >= timeout_ticks) {
                    fail();
                    return .failed;
                }
                if (x1000.Lcd.state.read() & x1000.Lcd.state_end_of_frame == 0) return .busy;
                x1000.Lcd.control.write(x1000.Lcd.burst_64_words);
                phase = .draining;
                return .busy;
            },
            .draining => {
                if (Timer.elapsed(started_at) >= timeout_ticks) {
                    fail();
                    return .failed;
                }
                if (x1000.Lcd.mcu_state.read() & x1000.Lcd.mcu_busy != 0) return .busy;
                resetForDirect();
                if (output.completedTransfer()) board.display.backlight.set(true);
                return .idle;
            },
        }
    }

    fn start(x: usize, y: usize, region_width: usize, region_height: usize) bool {
        if (region_width == 0 or region_height == 0 or x + region_width > Display.width or
            y + region_height > Display.height or phase != .idle or
            x1000.Lcd.mcu_state.read() & x1000.Lcd.mcu_busy != 0) return false;

        const full_frame = x == 0 and y == 0 and
            region_width == Display.width and region_height == Display.height;
        const pixel_count = region_width * region_height;
        if (!full_frame and pixel_count > board.display.dma_staging_pixel_capacity) return false;

        var source_address: usize = board.display.framebuffer_address;
        if (!full_frame) {
            var destination: usize = 0;
            var py = y;
            while (py < y + region_height) : (py += 1) {
                var px = x;
                while (px < x + region_width) : (px += 1) {
                    packed_pixels[destination] = Display.pixels[py * Display.width + px];
                    destination += 1;
                }
            }
            source_address = board.display.dma_staging_address;
        }

        if (!Display.setAddressWindow(x, y, region_width, region_height)) return false;
        write_command.* = .{ 0x2c, 0x2c, 0x2c, 0x2c };
        const plan = lcd_dma.buildTransferPlan(
            board.display.dma_descriptor_address,
            board.display.dma_command_address,
            source_address,
            @intCast(region_width),
            @intCast(region_height),
        );
        descriptors.* = plan.descriptors;
        x1000.memoryBarrier();

        x1000.Lcd.horizontal_area.write(plan.horizontal_area);
        x1000.Lcd.vertical_area.write(plan.vertical_area);
        x1000.Lcd.mcu_config_new.write(x1000.Lcd.dma_rgb565_over_8_bit_bus);
        x1000.Lcd.mcu_control.write(board.display.mcu_control | x1000.Lcd.mcu_dma_start);
        x1000.Lcd.mcu_control.write(board.display.mcu_control |
            x1000.Lcd.mcu_dma_start | x1000.Lcd.mcu_dma_transmit_enable);
        x1000.Lcd.state.write(0);
        x1000.Lcd.descriptor_address.write(lcd_dma.physicalAddress(board.display.dma_descriptor_address));
        x1000.Lcd.control.write(x1000.Lcd.burst_64_words | x1000.Lcd.control_enable);
        started_at = Timer.now();
        phase = .transferring;
        return true;
    }

    fn transfer(x: usize, y: usize, region_width: usize, region_height: usize) bool {
        while (true) switch (poll()) {
            .idle => break,
            .failed => return false,
            .busy => Watchdog.kick(),
        };
        if (!start(x, y, region_width, region_height)) return false;
        while (true) {
            Watchdog.kick();
            switch (poll()) {
                .idle => return true,
                .failed => return false,
                .busy => {},
            }
        }
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
    LcdDma.resetForDirect();
    if (!Display.presentRegionCpu(0, 0, Display.width, Display.height)) rawPanicBlink();
    while (true) asm volatile ("nop");
}

export fn exception_panic(cause: u32, epc: u32, status: u32) callconv(.c) noreturn {
    showPanic(cause, epc, status);
}

const Volume = fat32.Volume(storage.Controller);
const maximum_depth = 8;
const visible_rows = 6;
const read_ahead_bytes = 64 * 1024 - 4;
const maximum_block_frames = 65_535;
const compressed_bytes = 256 * 1024;

const sd_descriptor: *volatile storage.DmaDescriptor = @ptrFromInt(0xa007_f000);
const sd_switch_status: *align(4) [64]u8 = @ptrFromInt(0xa007_f100);
const sd_scratch: *[fat32.sector_bytes]u8 = @ptrFromInt(0xa008_0000);
const read_ahead_first: *align(4) [read_ahead_bytes]u8 = @ptrFromInt(0xa00a_0000);
const read_ahead_second: *align(4) [read_ahead_bytes]u8 = @ptrFromInt(0xa00b_0000);
const audio_descriptors: *align(4096) volatile [audio.maximum_descriptors]audio.Descriptor = @ptrFromInt(0xa028_0000);
const decoded_left: *[maximum_block_frames]i32 = @ptrFromInt(0x8040_0000);
const decoded_right: *[maximum_block_frames]i32 = @ptrFromInt(0x8044_0000);
const compressed_frame: *[compressed_bytes]u8 = @ptrFromInt(0x8048_0000);

const audio_resources = audio.Engine.Resources{
    .descriptors = audio_descriptors,
    .buffers = .{
        .{ .address = 0xa010_0000 },
        .{ .address = 0xa018_0000 },
        .{ .address = 0xa020_0000 },
        .{ .address = 0xa020_0000 },
    },
};

const Browser = struct {
    directories: [maximum_depth]fat32.Directory = undefined,
    selections: [maximum_depth]usize = @splat(0),
    counts: [maximum_depth]usize = @splat(0),
    titles: [maximum_depth][fat32.maximum_name_bytes]u8 = @splat(@splat(0)),
    title_lengths: [maximum_depth]u8 = @splat(0),
    depth: usize = 0,

    fn init(volume: *Volume) !Browser {
        var self = Browser{};
        self.directories[0] = volume.rootDirectory();
        @memcpy(self.titles[0][0..7], "SD CARD");
        self.title_lengths[0] = 7;
        self.counts[0] = try countEntries(volume, self.directories[0]);
        return self;
    }

    fn directory(self: *const Browser) fat32.Directory {
        return self.directories[self.depth];
    }

    fn selection(self: *const Browser) usize {
        return self.selections[self.depth];
    }

    fn title(self: *const Browser) []const u8 {
        return self.titles[self.depth][0..self.title_lengths[self.depth]];
    }

    fn move(self: *Browser, direction: i2) void {
        const count = self.counts[self.depth];
        if (count == 0) return;
        var selected = self.selections[self.depth];
        if (direction > 0) {
            selected = (selected + 1) % count;
        } else if (selected == 0) {
            selected = count - 1;
        } else {
            selected -= 1;
        }
        self.selections[self.depth] = selected;
    }

    fn selectedEntry(self: *const Browser, volume: *Volume) !?fat32.DirectoryEntry {
        var iterator = try volume.iterate(self.directory());
        var index: usize = 0;
        while (try iterator.next()) |entry| {
            if (!isVisibleEntry(&entry)) continue;
            if (index == self.selection()) return entry;
            index += 1;
        }
        return null;
    }

    fn enter(self: *Browser, volume: *Volume, entry: fat32.DirectoryEntry) !void {
        if (self.depth + 1 == maximum_depth) return;
        const next = try entry.directory();
        self.depth += 1;
        self.directories[self.depth] = next;
        self.selections[self.depth] = 0;
        self.counts[self.depth] = try countEntries(volume, next);
        const length = @min(entry.name().len, fat32.maximum_name_bytes);
        @memcpy(self.titles[self.depth][0..length], entry.name()[0..length]);
        self.title_lengths[self.depth] = @intCast(length);
    }

    fn back(self: *Browser) void {
        if (self.depth != 0) self.depth -= 1;
    }

    fn home(self: *Browser) void {
        self.depth = 0;
    }
};

const UiEvent = enum {
    select,
    back,
    home,
    up,
    down,
    volume_up,
    volume_down,
};

const Input = struct {
    raw_buttons: u8 = 0,
    stable_buttons: u8 = 0,
    stable_samples: u3 = 0,
    old_wheel: u2,
    wheel_accumulator: i8 = 0,

    fn init() Input {
        for (board.buttons) |button| button.pin.input();
        board.wheel.phase_a.input();
        board.wheel.phase_b.input();
        return .{ .old_wheel = wheelState() };
    }

    fn poll(self: *Input) ?UiEvent {
        const sample = buttonState();
        var pressed: u8 = 0;
        if (sample == self.raw_buttons) {
            if (self.stable_samples < 7) self.stable_samples += 1;
        } else {
            self.raw_buttons = sample;
            self.stable_samples = 0;
        }
        if (self.stable_samples == 3 and self.stable_buttons != self.raw_buttons) {
            pressed = self.raw_buttons & ~self.stable_buttons;
            self.stable_buttons = self.raw_buttons;
        }

        if (pressed != 0) {
            if (pressed & board.ButtonId.play.mask() != 0) return .select;
            if (pressed & board.ButtonId.back.mask() != 0) return .back;
            if (pressed & board.ButtonId.menu.mask() != 0) return .home;
            if (pressed & board.ButtonId.previous.mask() != 0) return .up;
            if (pressed & board.ButtonId.next.mask() != 0) return .down;
            if (pressed & board.ButtonId.volume_up.mask() != 0) return .volume_up;
            if (pressed & board.ButtonId.volume_down.mask() != 0) return .volume_down;
        }

        const current_wheel = wheelState();
        if (current_wheel != self.old_wheel) {
            const transitions = [_]i8{ 0, -1, 1, 0, 1, 0, 0, -1, -1, 0, 0, 1, 0, 1, -1, 0 };
            self.wheel_accumulator += transitions[(@as(usize, self.old_wheel) << 2) | current_wheel];
            self.old_wheel = current_wheel;
            if (self.wheel_accumulator >= 4) {
                self.wheel_accumulator = 0;
                return .down;
            }
            if (self.wheel_accumulator <= -4) {
                self.wheel_accumulator = 0;
                return .up;
            }
        }
        return null;
    }

    fn resync(self: *Input) void {
        const buttons = buttonState();
        self.raw_buttons = buttons;
        self.stable_buttons = buttons;
        self.stable_samples = 0;
        self.old_wheel = wheelState();
        self.wheel_accumulator = 0;
    }
};

const PlaybackUi = struct {
    browser: *const Browser,
    entry: *const fat32.DirectoryEntry,
    battery_mv: u32,
    controls: playback_controls.State,
    presented: bool = false,
    initial_present_pending: bool = false,
    displayed_second: u32 = 0,
    display_failed: bool = false,
    display: display_transfer.Scheduler = .{},
};

const volume_region = display_transfer.Region{ .x = 275, .y = 7, .width = 18, .height = 7 };
const progress_region = display_transfer.Region{ .x = 0, .y = 180, .width = 320, .height = 42 };
fn pumpPlaybackDisplay(state: *PlaybackUi) bool {
    switch (LcdDma.poll()) {
        .failed => return false,
        .busy => return true,
        .idle => {},
    }
    const region = state.display.take() orelse return true;
    return LcdDma.start(region.x, region.y, region.width, region.height);
}

fn buttonState() u8 {
    var sample: u8 = 0;
    for (board.buttons) |button| {
        if (!button.pin.get()) sample |= button.id.mask();
    }
    return sample;
}

fn playbackPoll(context: *anyopaque, status: media.PlaybackStatus) media.PlaybackCommand {
    Watchdog.kick();
    const state: *PlaybackUi = @ptrCast(@alignCast(context));
    const second: u32 = @intCast(@min(status.played_frames / status.sample_rate, 0xffff_ffff));
    if (!state.presented) {
        state.presented = true;
        state.displayed_second = second;
        drawNowPlaying(state, status);
        state.initial_present_pending = true;
    } else if (state.initial_present_pending and status.phase == .playing) {
        if (!LcdDma.start(0, 0, Display.width, Display.height)) {
            state.display_failed = true;
            return .stop;
        }
        state.initial_present_pending = false;
    } else if (second != state.displayed_second) {
        state.displayed_second = second;
        drawPlaybackProgress(status);
        state.display.request(progress_region, .normal);
    }

    const action = state.controls.update(buttonState());
    var command: media.PlaybackCommand = .none;
    switch (action) {
        .none => {},
        .stop => command = .stop,
        .next => command = .next,
        .previous => command = .previous,
        .set_attenuation => |attenuation| {
            drawVolume(attenuation);
            state.display.request(volume_region, .urgent);
            command = .{ .set_attenuation = attenuation };
        },
    }
    if (!state.initial_present_pending and !pumpPlaybackDisplay(state)) {
        state.display_failed = true;
        return .stop;
    }
    return command;
}

fn isVisibleEntry(entry: *const fat32.DirectoryEntry) bool {
    if (entry.attributes & 0x06 != 0) return false;
    const name = entry.name();
    if (name.len == 0 or (name.len == 1 and name[0] == '.') or
        (name.len == 2 and name[0] == '.' and name[1] == '.')) return false;
    return entry.kind == .directory or endsWithIgnoreCase(name, ".flac");
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    const start = value.len - suffix.len;
    for (value[start..], suffix) |left, right| {
        const normalized = if (left >= 'A' and left <= 'Z') left + ('a' - 'A') else left;
        if (normalized != right) return false;
    }
    return true;
}

fn countEntries(volume: *Volume, directory: fat32.Directory) !usize {
    var iterator = try volume.iterate(directory);
    var count: usize = 0;
    while (try iterator.next()) |entry| {
        if (isVisibleEntry(&entry)) count += 1;
    }
    return count;
}

fn batteryPercent(millivolts: u32) u8 {
    if (millivolts <= 3_300) return 0;
    if (millivolts >= 4_200) return 100;
    return @intCast((millivolts - 3_300) * 100 / 900);
}

fn decimal3(value_initial: u8, output: *[3]u8) void {
    var value = value_initial;
    output[2] = '0' + value % 10;
    value /= 10;
    output[1] = if (value != 0 or value_initial == 100) '0' + value % 10 else ' ';
    value /= 10;
    output[0] = if (value != 0) '0' + value else ' ';
}

fn drawHeader(battery_mv: u32, attenuation: u8) void {
    Display.rectangle(0, 0, Display.width, 30, 0x18e3);
    Display.text(10, 7, "GAIN", Display.white, 2);
    var percent: [3]u8 = undefined;
    decimal3(batteryPercent(battery_mv), &percent);
    Display.text(242, 7, &percent, Display.white, 1);
    Display.text(261, 7, "%", Display.white, 1);
    drawVolume(attenuation);
}

fn drawVolume(attenuation: u8) void {
    Display.rectangle(volume_region.x, volume_region.y, volume_region.width, volume_region.height, 0x18e3);
    var volume: [3]u8 = undefined;
    const volume_percent: u8 = @intCast((@as(u16, 128 - attenuation) * 100) / 112);
    decimal3(volume_percent, &volume);
    Display.text(275, 7, &volume, Display.cyan, 1);
}

fn clippedName(name: []const u8, maximum: usize) []const u8 {
    return name[0..@min(name.len, maximum)];
}

fn drawBrowser(volume: *Volume, browser: *const Browser, battery_mv: u32, attenuation: u8) !bool {
    Display.clear(Display.black);
    drawHeader(battery_mv, attenuation);
    Display.text(10, 40, clippedName(browser.title(), 48), Display.cyan, 1);

    const count = browser.counts[browser.depth];
    if (count == 0) {
        Display.text(82, 112, "NO FLAC FILES", Display.white, 2);
    } else {
        const selected = browser.selection();
        const first = if (selected >= visible_rows) selected - (visible_rows - 1) else 0;
        var iterator = try volume.iterate(browser.directory());
        var index: usize = 0;
        var row: usize = 0;
        while (try iterator.next()) |entry| {
            if (!isVisibleEntry(&entry)) continue;
            if (index >= first and row < visible_rows) {
                const y = 59 + row * 27;
                const active = index == selected;
                if (active) Display.rectangle(7, y, 306, 23, Display.white);
                Display.text(14, y + 8, clippedName(entry.name(), 45), if (active) Display.black else Display.white, 1);
                if (entry.kind == .directory) Display.text(298, y + 8, ">", if (active) Display.black else Display.cyan, 1);
                row += 1;
            }
            index += 1;
            if (row == visible_rows) break;
        }
    }
    Display.text(10, 225, "PLAY SELECT", 0x8410, 1);
    Display.text(226, 225, "BACK", 0x8410, 1);
    return Display.present();
}

fn cleanTrackName(raw: []const u8) []const u8 {
    var end = raw.len;
    if (endsWithIgnoreCase(raw, ".flac")) end -= 5;
    var start: usize = 0;
    while (start < end and raw[start] >= '0' and raw[start] <= '9') start += 1;
    if (start != 0) {
        while (start < end and raw[start] == ' ') start += 1;
        if (start < end and raw[start] == '-') start += 1;
        while (start < end and raw[start] == ' ') start += 1;
    }
    return raw[start..end];
}

fn firstLineLength(value: []const u8, maximum: usize) usize {
    if (value.len <= maximum) return value.len;
    var split = maximum;
    while (split != 0 and value[split] != ' ') split -= 1;
    return if (split == 0) maximum else split;
}

fn timeText(seconds_initial: u64, output: *[5]u8) void {
    const seconds = @min(seconds_initial, 99 * 60 + 59);
    const minutes = seconds / 60;
    const remainder = seconds % 60;
    output[0] = '0' + @as(u8, @intCast(minutes / 10));
    output[1] = '0' + @as(u8, @intCast(minutes % 10));
    output[2] = ':';
    output[3] = '0' + @as(u8, @intCast(remainder / 10));
    output[4] = '0' + @as(u8, @intCast(remainder % 10));
}

fn sampleRateText(rate: u32) []const u8 {
    return switch (rate) {
        44_100 => "44.1 KHZ",
        48_000 => "48 KHZ",
        88_200 => "88.2 KHZ",
        96_000 => "96 KHZ",
        176_400 => "176.4 KHZ",
        192_000 => "192 KHZ",
        else => "FLAC",
    };
}

fn drawPlaybackProgress(status: media.PlaybackStatus) void {
    Display.rectangle(0, 180, Display.width, 42, Display.black);
    Display.rectangle(10, 186, 300, 5, 0x2104);
    const progress: usize = if (status.total_frames == 0)
        0
    else
        @intCast(@min(status.played_frames * 300 / status.total_frames, 300));
    if (progress != 0) Display.rectangle(10, 186, progress, 5, Display.green);

    var elapsed: [5]u8 = undefined;
    var total: [5]u8 = undefined;
    timeText(status.played_frames / status.sample_rate, &elapsed);
    timeText(status.total_frames / status.sample_rate, &total);
    Display.text(10, 201, &elapsed, Display.white, 1);
    Display.text(280, 201, &total, Display.white, 1);
}

fn drawNowPlaying(state: *const PlaybackUi, status: media.PlaybackStatus) void {
    Display.clear(Display.black);
    drawHeader(state.battery_mv, state.controls.attenuation);

    if (state.browser.depth > 0) {
        const artist_depth = if (state.browser.depth > 1) state.browser.depth - 1 else state.browser.depth;
        const artist = state.browser.titles[artist_depth][0..state.browser.title_lengths[artist_depth]];
        Display.text(10, 42, clippedName(artist, 48), Display.cyan, 1);
    }

    const name = cleanTrackName(state.entry.name());
    const first_length = firstLineLength(name, 24);
    Display.text(10, 66, name[0..first_length], Display.white, 2);
    if (first_length < name.len) {
        const second_start = first_length + @as(usize, @intFromBool(name[first_length] == ' '));
        Display.text(10, 88, clippedName(name[second_start..], 24), Display.white, 2);
    }

    if (state.browser.depth != 0) {
        Display.text(10, 124, clippedName(state.browser.title(), 48), 0x8410, 1);
    }
    Display.text(10, 151, if (status.output_format == .signed_24_in_u32) "24 BIT" else "16 BIT", Display.green, 1);
    Display.text(64, 151, sampleRateText(status.sample_rate), Display.green, 1);
    drawPlaybackProgress(status);
    Display.text(10, 228, "PLAY / BACK", 0x8410, 1);
}

fn showError(title: []const u8, failure: anyerror) bool {
    var code: [8]u8 = undefined;
    hex32(@intFromError(failure), &code);
    Display.clear(Display.black);
    Display.rectangle(0, 0, Display.width, 32, Display.red);
    Display.text(10, 8, "GAIN", Display.white, 2);
    Display.text(10, 68, clippedName(title, 24), Display.white, 2);
    Display.text(10, 112, "ERROR", Display.red, 2);
    Display.text(92, 112, &code, Display.yellow, 2);
    Display.text(10, 148, clippedName(@errorName(failure), 48), Display.cyan, 1);
    Display.text(10, 212, "BACK TO RETURN", 0x8410, 1);
    return Display.present();
}

fn showShutdown() bool {
    Display.clear(Display.black);
    Display.text(38, 92, "POWERING OFF", Display.white, 3);
    return Display.present();
}

fn readPmic(pmic: i2c.Bus, register: board.pmic.Register, value: *u8) bool {
    value.* = pmic.readRegister(board.pmic.address, @backingInt(register)) catch return false;
    return true;
}

fn writePmic(pmic: i2c.Bus, register: board.pmic.Register, value: u8) bool {
    pmic.writeRegister(board.pmic.address, @backingInt(register), value) catch return false;
    return true;
}

fn powerOff(pmic: i2c.Bus) noreturn {
    Watchdog.kick();
    _ = showShutdown();
    var control: u8 = 0;
    if (!readPmic(pmic, .power_control, &control)) showPanic(panicCode("PMIC"), 0, 0);
    if (!writePmic(pmic, .power_control, control | board.pmic.shutdown)) showPanic(panicCode("PMIC"), 0, 0);
    while (true) Watchdog.kick();
}

fn fatalError(title: []const u8, failure: anyerror) noreturn {
    _ = showError(title, failure);
    while (true) Watchdog.kick();
}

fn waitForErrorDismiss(input: *Input) void {
    while (true) {
        Watchdog.kick();
        if (input.poll()) |event| {
            if (event == .back or event == .select or event == .home) return;
        }
        Timer.delayMicroseconds(1_000);
    }
}

fn playEntry(
    volume: *Volume,
    browser: *const Browser,
    entry: fat32.DirectoryEntry,
    battery_mv: u32,
    attenuation: u8,
) !media.Result {
    var file_reader = try volume.reader(try entry.file());
    const Reader = storage.ReadAheadReader(@TypeOf(file_reader));
    var reader = try Reader.init(&file_reader, .{ read_ahead_first, read_ahead_second });
    var playback_ui = PlaybackUi{
        .browser = browser,
        .entry = &entry,
        .battery_mv = battery_mv,
        .controls = playback_controls.State.init(attenuation),
    };
    const result = try media.playFlacControlled(
        &reader,
        audio_resources,
        .{ .compressed = compressed_frame, .left = decoded_left, .right = decoded_right },
        .{ .descriptor_count = 120, .buffer_count = 3, .attenuation = attenuation },
        .{ .context = &playback_ui, .poll = playbackPoll },
    );
    if (playback_ui.display_failed) return error.DisplayFailure;
    return result;
}

fn adjacentTrack(
    volume: *Volume,
    browser: *Browser,
    direction: i2,
) !?fat32.DirectoryEntry {
    const count = browser.counts[browser.depth];
    var attempts: usize = 0;
    while (attempts < count) : (attempts += 1) {
        browser.move(direction);
        const candidate = try browser.selectedEntry(volume) orelse return null;
        if (candidate.kind == .file) return candidate;
    }
    return null;
}

fn playSelection(
    volume: *Volume,
    browser: *Browser,
    first_entry: fat32.DirectoryEntry,
    battery_mv: u32,
    attenuation: *u8,
) !void {
    var entry = first_entry;
    while (true) {
        const result = try playEntry(volume, browser, entry, battery_mv, attenuation.*);
        attenuation.* = result.attenuation;
        const direction: i2 = switch (result.exit) {
            .next => 1,
            .previous => -1,
            .completed, .stopped => return,
        };
        entry = (try adjacentTrack(volume, browser, direction)) orelse return;
    }
}

export fn gain_main() callconv(.c) noreturn {
    if (!Display.init()) rawPanicBlink();
    display_ready = true;
    Watchdog.start(.external, .by_1024, board.watchdog_timeout_ticks);
    Watchdog.kick();

    var input = Input.init();
    var pmic = i2c.Bus.init(board.pmic.primary.scl, board.pmic.primary.sda);
    var pmic_status: u8 = 0;
    if (!readPmic(pmic, .status, &pmic_status)) {
        pmic = i2c.Bus.init(board.pmic.alternate.scl, board.pmic.alternate.sda);
        _ = readPmic(pmic, .status, &pmic_status);
    }
    var battery_high: u8 = 0;
    var battery_low: u8 = 0;
    _ = readPmic(pmic, .battery_high, &battery_high);
    _ = readPmic(pmic, .battery_low, &battery_low);
    const battery_mv = ((@as(u32, battery_high) << 4) | (battery_low & 0x0f)) * 11 / 10;

    Display.clear(Display.black);
    Display.text(102, 92, "GAIN", Display.white, 3);
    Display.text(112, 132, "LOADING", Display.cyan, 1);
    if (!Display.present()) rawPanicBlink();

    var card = storage.Controller.initialize(.{
        .descriptor = sd_descriptor,
        .switch_status = sd_switch_status,
    }) catch |failure| fatalError("SD CARD", failure);
    Watchdog.kick();
    var volume = Volume.mount(&card, sd_scratch) catch |failure| fatalError("FILESYSTEM", failure);
    var browser = Browser.init(&volume) catch |failure| fatalError("DIRECTORY", failure);
    var attenuation: u8 = 64;
    var power_started: ?u32 = null;

    if (!(drawBrowser(&volume, &browser, battery_mv, attenuation) catch |failure| fatalError("DIRECTORY", failure))) rawPanicBlink();
    while (true) {
        Watchdog.kick();
        if (input.poll()) |event| {
            switch (event) {
                .up => browser.move(-1),
                .down => browser.move(1),
                .back => browser.back(),
                .home => browser.home(),
                .volume_up => attenuation = if (attenuation > 16) attenuation - 4 else 16,
                .volume_down => attenuation = if (attenuation < 124) attenuation + 4 else 128,
                .select => {
                    const selected = browser.selectedEntry(&volume) catch |failure| {
                        _ = showError("DIRECTORY", failure);
                        waitForErrorDismiss(&input);
                        continue;
                    };
                    if (selected) |entry| {
                        if (entry.kind == .directory) {
                            browser.enter(&volume, entry) catch |failure| {
                                _ = showError("DIRECTORY", failure);
                                waitForErrorDismiss(&input);
                            };
                        } else {
                            playSelection(&volume, &browser, entry, battery_mv, &attenuation) catch |failure| {
                                _ = showError("PLAYBACK", failure);
                                waitForErrorDismiss(&input);
                            };
                            input.resync();
                        }
                    }
                },
            }
            if (!(drawBrowser(&volume, &browser, battery_mv, attenuation) catch |failure|
                fatalError("DIRECTORY", failure))) rawPanicBlink();
        }

        const power_down = input.stable_buttons & board.ButtonId.power.mask() != 0;
        if (power_down) {
            if (power_started == null) power_started = Timer.now();
            if (Timer.elapsed(power_started.?) > Timer.milliseconds(1_500)) powerOff(pmic);
        } else power_started = null;
        Timer.delayMicroseconds(1_000);
    }
}
