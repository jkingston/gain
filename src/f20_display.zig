//! F20 V2.7 backend. Canvas writes never touch the DMA-owned source.
const x = @import("x1000.zig");
const trace = @import("display_trace.zig");
const board = @import("f20_v27.zig").display;
const lcd_dma = @import("lcd_dma.zig");
const phase = @import("display_phase.zig");
const presentation = @import("presentation.zig");

pub const Region = presentation.Region;
pub var text_cache: ?*@import("text/cache.zig").Cache = null;

pub const Poll = enum { idle, busy, failed };
const descriptors: *align(32) volatile lcd_dma.Chain = @ptrFromInt(board.dma_descriptor_address);
const write_command: *align(64) volatile [4]u8 = @ptrFromInt(board.dma_command_address);
pub const framebuffer: *[board.width * board.height]u16 = @ptrFromInt(board.framebuffer_address);
const snapshot: *[board.width * board.height]u16 = @ptrFromInt(board.dma_snapshot_address);
const next_snapshot: *[board.width * board.height]u16 = @ptrFromInt(@import("f20_memory.zig").display_next.uncached());
var state = presentation.State{};
var awake = true;

const timeout_ticks = x.Timer.milliseconds(100);
const quick_disable_done = @as(u32, 1) << 7;
var panel_config: phase.Config = undefined;
var launch_deadline: ?u32 = null;
var cadence_launch = false;
var full_frame_pacer: @import("frame_pacer.zig").Pacer = .{};
var missed_deadline: ?u32 = null;
var launch_owner: @import("deadline_timer.zig").LaunchOwner = .poll;
pub var last_failure: ?anyerror = null;
var prepared_region: Region = undefined;
var prepared_source: usize = 0;
const fifo_underrun = @as(u32, 1) << 2;

/// Backlight permission is independent of DMA ownership. A late completion
/// must not relight a locked player; waking waits for the next fresh transfer.
pub fn setAwake(enabled: bool) void {
    if (awake and !enabled) board.backlight.set(false);
    awake = enabled;
}

pub fn waitReady() !void {
    const began = x.Timer.now();
    while (x.Lcd.mcu_state.read() & x.Lcd.mcu_busy != 0) {
        if (x.Timer.elapsed(began) >= x.Timer.milliseconds(20)) return error.DisplayBusy;
    }
}

fn send(value: u32) !void {
    try waitReady();
    x.Lcd.mcu_data.write(value);
}

fn command(value: board.Command) !void {
    try send(x.Lcd.command_flag | @as(u32, @backingInt(value)));
}

fn data(value: u8) !void {
    try send(value);
}

pub fn initialize() !void {
    if (state.owned()) return error.DisplayOwned;
    board.backlight.output(false);
    board.reset.output(false);
    board.power.output(false);
    board.read_strobe.output(true);
    board.chip_enable.output(true);
    x.Gpio.selectFunction1(.a, board.port_a_function_1);
    x.Gpio.selectFunction1(.b, board.port_b_function_1);
    board.power.set(true);
    x.Timer.delayMicroseconds(20_000);
    board.reset.set(true);
    x.Timer.delayMicroseconds(12_000);
    x.Cpm.lcd_clock.write(board.clock_configuration);
    const began = x.Timer.now();
    while (x.Cpm.lcd_clock.read() & x.Cpm.lcd_clock_busy != 0) {
        if (x.Timer.elapsed(began) > x.Timer.milliseconds(20)) return error.DisplayClock;
    }
    x.Cpm.lcd_clock.clear(x.Cpm.lcd_clock_change_enable);
    x.Cpm.ungate(.lcd);
    x.Lcd.mcu_config.write(board.mcu_configuration);
    x.Lcd.mcu_config_new.write(0);
    x.Lcd.mcu_control.write(board.mcu_control);
    x.Lcd.write_time.write(0);
    x.Lcd.task_hold.write(0);
    x.Lcd.slow_write_time.write(0);
    x.Lcd.control.write(x.Lcd.direct_command_mode);
    x.Lcd.horizontal_area.write(320);
    x.Lcd.vertical_area.write(240);
    board.read_strobe.set(true);
    board.chip_enable.set(true);
    x.Timer.delayMicroseconds(5_000);
    board.chip_enable.set(false);
    for (board.initialization) |item| {
        if (board.isCommand(item)) {
            try command(@fromBackingInt(@as(u8, @truncate(item))));
        } else try data(@truncate(item));
    }
    try command(.sleep_out);
    x.Timer.delayMicroseconds(120_000);
    try command(.display_on);
    x.Timer.delayMicroseconds(20_000);
    // PB19 does not provide a usable TE pulse on this board.
    try send(x.Lcd.command_flag | 0x34);
    try waitReady();
    panel_config = try calibrate();
    full_frame_pacer = .{};
}

fn prepareRect(left: u16, top: u16, width: u16, height: u16, source: usize) !void {
    if (state.owned()) return error.DisplayOwned;
    if (width == 0 or height == 0 or @as(u32, left) + width > 320 or
        @as(u32, top) + height > 240) return error.DisplayGeometry;
    // This adapter accepts tightly packed word-aligned RGB565 rows. Odd
    // logical damage needs a caller-side expanded window or padded layout.
    if (!board.validDmaSource(source, width, height)) return error.DisplaySource;
    try command(.column_address);
    try data(@truncate(left >> 8));
    try data(@truncate(left));
    const right = left + width - 1;
    try data(@truncate(right >> 8));
    try data(@truncate(right));
    try command(.page_address);
    try data(@truncate(top >> 8));
    try data(@truncate(top));
    const last = top + height - 1;
    try data(@truncate(last >> 8));
    try data(@truncate(last));
    // Finish the final direct parameter before changing its transfer format.
    const parameter_started = x.Timer.now();
    while (x.Lcd.mcu_state.read() & x.Lcd.mcu_busy != 0) {
        if (x.Timer.elapsed(parameter_started) >= x.Timer.milliseconds(20)) return error.DisplayBusy;
    }
    write_command.* = .{ 0x2c, 0x2c, 0x2c, 0x2c };
    const plan = lcd_dma.buildTransferPlan(
        board.dma_descriptor_address,
        board.dma_command_address,
        source,
        width,
        height,
    );
    descriptors.* = plan.descriptors;
    asm volatile ("sync" ::: .{ .memory = true });
    x.Lcd.horizontal_area.write(plan.horizontal_area);
    x.Lcd.vertical_area.write(plan.vertical_area);
    x.Lcd.mcu_config_new.write(x.Lcd.dma_rgb565_over_8_bit_bus);
    x.Lcd.mcu_control.write(board.mcu_control | x.Lcd.mcu_dma_start);
    // X1000 PM 4.9.1: direct commands must have drained before DMATXEN.
    const began = x.Timer.now();
    while (x.Lcd.mcu_state.read() & x.Lcd.mcu_busy != 0) {
        if (x.Timer.elapsed(began) >= x.Timer.milliseconds(20)) return error.DisplayBusy;
    }
    x.Lcd.mcu_control.write(board.mcu_control | x.Lcd.mcu_dma_start | x.Lcd.mcu_dma_transmit_enable);
    x.Lcd.state.write(0);
    x.Lcd.descriptor_address.write(lcd_dma.physicalAddress(board.dma_descriptor_address));
    try state.prepare();
    prepared_region = .{ .x = left, .y = top, .width = width, .height = height };
    prepared_source = source;
    launch_deadline = null;
    missed_deadline = null;
}

pub const Frozen = struct { region: Region, source: usize };

/// CPU rendering and packing may overlap the previous transfer. Never choose
/// the bank retained by the controller, including its FIFO/disable ACK phase.
/// The caller retains at most one pending canvas until presentFrozen consumes it.
pub fn freeze(region: Region) !Frozen {
    const aligned = try presentation.alignedRegion(region, board.width, board.height);
    const address = @import("display_banks.zig").inactive(prepared_source, @intFromPtr(snapshot), @intFromPtr(next_snapshot));
    const destination: *[board.width * board.height]u16 = @ptrFromInt(address & ~@as(usize, 0x20000000));
    try presentation.pack(framebuffer, board.width, board.height, aligned, destination);
    publishSnapshot(@intFromPtr(destination), aligned.pixels() * 2);
    return .{ .region = aligned, .source = address };
}

fn prepareFrozen(frozen: Frozen) !void {
    if (state.owned()) return error.DisplayOwned;
    if (frozen.source != @intFromPtr(snapshot) and frozen.source != @intFromPtr(next_snapshot)) return error.DisplaySource;
    const r = frozen.region;
    try prepareRect(r.x, r.y, r.width, r.height, frozen.source);
}

pub fn presentFrozen(frozen: Frozen, synchronized: bool) !void {
    const deadline = if (synchronized) try targetFor(frozen.region) else null;
    try prepareFrozen(frozen);
    cadence_launch = false;
    if (deadline) |at| {
        launch_deadline = at;
    } else if (full_frame_pacer.deadline(x.Timer.now(), @intCast(panel_config.period))) |at| {
        cadence_launch = true;
        launch_deadline = at;
    } else try commit();
}

pub fn prepare(region: Region) !void {
    if (state.owned()) return error.DisplayOwned;
    try prepareFrozen(try freeze(region));
}

/// Only a bounded launch belongs in a deadline handler. Packing, GPIO reads
/// and direct panel commands must already have completed during preparation.
pub fn commit() !void {
    if (state.phase != .prepared) return error.DisplayNotPrepared;
    if (x.Lcd.mcu_state.read() & x.Lcd.mcu_busy != 0) return error.DisplayBusy;
    launch_deadline = null;
    missed_deadline = null;
    try state.commit(x.Timer.now());
    if (prepared_region.width == board.width and prepared_region.height == board.height) full_frame_pacer.committed(x.Timer.now());
    cadence_launch = false;
    x.Lcd.control.write(x.Lcd.burst_64_words | x.Lcd.control_enable);
    trace.record(.commit, x.Timer.now(), @as(u32, prepared_region.width) * prepared_region.height);
}

pub fn cancel() !void {
    try state.cancel();
    launch_deadline = null;
    missed_deadline = null;
    restoreDirect();
}

/// Prepare ahead of the measured refresh instead of beating a fixed16ms
/// timer against this panel's approximately14.6ms scan. Three milliseconds
/// reserve the measured partial redraw/packing work plus one UI polling tick.
pub fn renderIntervalMs() u64 {
    return @max(1, panel_config.period / x.Timer.milliseconds(1) -| 3);
}

pub fn useInterruptLaunch(enabled: bool) void {
    launch_owner = if (enabled) .interrupt else .poll;
}

/// A prepared source is immutable, but painting another canvas before its
/// launch can delay the idle launch owner or prevent the executive rearming.
pub fn waitingForLaunch() bool {
    return state.phase == .prepared and launch_deadline != null;
}

pub fn pendingDeadline() ?u32 {
    return launch_deadline;
}

pub fn launchFromInterrupt() void {
    if (state.phase != .prepared) return;
    const deadline = launch_deadline orelse return;
    if (cadence_launch) {
        if (@as(i32, @bitCast(x.Timer.now() -% deadline)) < 0) return;
        commit() catch |failure| {
            last_failure = last_failure orelse failure;
            state.phase = .failed;
        };
        return;
    }
    switch (phase.launchAt(x.Timer.now(), deadline)) {
        .wait => {},
        .commit => commit() catch |failure| {
            last_failure = last_failure orelse failure;
            state.phase = .failed;
        },
        .retarget => {
            launch_deadline = null;
            missed_deadline = deadline;
        },
    }
}

/// Idle has no task timer. Wait only for the final sub-millisecond launch
/// interval; playback uses the bounded interrupt callback above instead.
pub fn idleLaunch() void {
    const deadline = launch_deadline orelse return;
    const remaining = @as(i32, @bitCast(deadline -% x.Timer.now()));
    if (remaining < 0 or remaining > x.Timer.milliseconds(1)) return;
    while (@as(i32, @bitCast(deadline -% x.Timer.now())) > 0) {}
    launchFromInterrupt();
}

pub fn poll() Poll {
    if (state.phase == .idle) return .idle;
    if (state.phase == .prepared) {
        if (!@import("deadline_timer.zig").pollMayHandle(launch_owner, missed_deadline != null)) return .busy;
        if (cadence_launch) {
            launchFromInterrupt();
            return if (state.phase == .failed) .failed else .busy;
        }
        if (launch_deadline orelse missed_deadline) |deadline| switch (phase.launchAt(x.Timer.now(), deadline)) {
            .wait => return .busy,
            .commit => commit() catch |failure| {
                last_failure = last_failure orelse failure;
                state.phase = .failed;
                return .failed;
            },
            .retarget => {
                trace.record(.retarget, x.Timer.now(), x.Timer.now() -% deadline);
                const region = prepared_region;
                const source = prepared_source;
                cancel() catch |failure| {
                    last_failure = last_failure orelse failure;
                    return .failed;
                };
                const next = targetFor(region) catch |failure| {
                    last_failure = last_failure orelse failure;
                    state.phase = .failed;
                    return .failed;
                };
                prepareRect(region.x, region.y, region.width, region.height, source) catch |failure| {
                    last_failure = last_failure orelse failure;
                    state.phase = .failed;
                    return .failed;
                };
                launch_deadline = next;
                return .busy;
            },
        } else return .busy;
    }
    const flags = x.Lcd.state.read();
    const action = state.observe(x.Timer.now(), timeout_ticks, .{
        .eof = flags & x.Lcd.state_end_of_frame != 0,
        .bus_busy = x.Lcd.mcu_state.read() & x.Lcd.mcu_busy != 0,
        .disable_done = flags & quick_disable_done != 0,
        .fault = flags & fifo_underrun != 0,
    }) catch |failure| {
        last_failure = last_failure orelse failure;
        return .failed; // Keep ownership on fault; never silently reuse.
    };
    switch (action) {
        .none => {},
        .disable => x.Lcd.control.write(x.Lcd.burst_64_words),
        .release => {
            trace.record(.release, x.Timer.now(), 0);
            restoreDirect();
            board.backlight.set(awake);
            return .idle;
        },
    }
    return .busy;
}

fn restoreDirect() void {
    x.Lcd.control.write(x.Lcd.burst_64_words);
    x.Lcd.mcu_control.write(board.mcu_control);
    x.Lcd.state.write(0);
    x.Lcd.mcu_config_new.write(0);
    x.Lcd.horizontal_area.write(board.width);
    x.Lcd.vertical_area.write(board.height);
}

pub fn start(left: usize, top: usize, width: usize, height: usize) bool {
    if (left > board.width or top > board.height or width > board.width or height > board.height) return false;
    const region = presentation.alignedRegion(.{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(width),
        .height = @intCast(height),
    }, board.width, board.height) catch return false;
    const deadline = targetFor(region) catch return false;
    prepare(region) catch return false;
    launch_deadline = deadline;
    return true;
}

pub fn wait() bool {
    while (true) {
        switch (poll()) {
            .idle => return true,
            .failed => return false,
            .busy => x.Watchdog.kick(),
        }
    }
}

pub fn transfer(left: usize, top: usize, width: usize, height: usize) bool {
    if (!resetForDirect()) return false;
    if (left > board.width or top > board.height or width > board.width or height > board.height) return false;
    prepare(.{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(width), .height = @intCast(height) }) catch return false;
    commit() catch return false;
    return wait();
}

/// Panic rendering can take over only after an acknowledged normal shutdown.
/// If the device is wedged we blink the backlight instead of reusing its RAM.
pub fn resetForDirect() bool {
    if (state.phase == .prepared) cancel() catch return false;
    if (!wait()) return false;
    restoreDirect();
    return true;
}

pub fn presentRegionCpu(left: usize, top: usize, width: usize, height: usize) bool {
    if (!resetForDirect()) return false;
    if (left > board.width or top > board.height or width > board.width or height > board.height) return false;
    const region = presentation.alignedRegion(.{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(width),
        .height = @intCast(height),
    }, board.width, board.height) catch return false;
    const right = region.x + region.width - 1;
    const bottom = region.y + region.height - 1;
    command(.column_address) catch return false;
    for ([_]u8{ @truncate(region.x >> 8), @truncate(region.x), @truncate(right >> 8), @truncate(right) }) |v| data(v) catch return false;
    command(.page_address) catch return false;
    for ([_]u8{ @truncate(region.y >> 8), @truncate(region.y), @truncate(bottom >> 8), @truncate(bottom) }) |v| data(v) catch return false;
    command(.memory_write) catch return false;
    for (region.y..region.y + region.height) |y| for (region.x..region.x + region.width) |xx| {
        const pixel = framebuffer[y * board.width + xx];
        data(@truncate(pixel >> 8)) catch return false;
        data(@truncate(pixel)) catch return false;
    };
    waitReady() catch return false;
    board.backlight.set(true);
    return true;
}

const wr = x.Gpio.Pin{ .port = .b, .index = 17 };
const dc = x.Gpio.Pin{ .port = .b, .index = 20 };

fn readRegister(value: u8, output: []u16) !void {
    if (state.owned()) return error.DisplayOwned;
    try send(x.Lcd.command_flag | @as(u32, value));
    try waitReady();
    wr.output(true);
    dc.output(true);
    inline for (0..8) |pin| (x.Gpio.Pin{ .port = .a, .index = pin }).input();
    defer {
        board.read_strobe.set(true);
        x.Gpio.selectFunction1(.a, 0xff);
        x.Gpio.selectFunction1(.b, wr.mask() | dc.mask());
    }
    x.Timer.delayMicroseconds(2);
    for (output) |*sample| {
        board.read_strobe.set(false);
        x.Timer.delayMicroseconds(1);
        sample.* = @truncate(x.Register32(0xb0010000).read());
        board.read_strobe.set(true);
        x.Timer.delayMicroseconds(1);
    }
}

fn sampleScan() !phase.Sample {
    for (0..3) |_| {
        var bytes: [3]u16 = undefined;
        const began = x.Timer.now();
        try readRegister(0x45, &bytes);
        const ended = x.Timer.now();
        if (ended -% began <= phase.maximum_read_ticks) return .{
            .began = began,
            .ended = ended,
            .line = ((@as(u32, bytes[1]) & 0xff) << 8) | (bytes[2] & 0xff),
        };
    }
    return error.PanelReadPreempted;
}

fn targetFor(region: Region) !u32 {
    const target = try phase.regionTarget(region, panel_config.period, phase.target_line);
    const scan = try sampleScan();
    return panel_config.nextTargetLine(scan, x.Timer.now(), x.Timer.microseconds(500), target);
}

fn calibrate() !phase.Config {
    var previous: ?u32 = null;
    var first: u32 = 0;
    var last: u32 = 0;
    var wraps: u32 = 0;
    var maximum: u32 = 0;
    var minimum: u32 = 0xffffffff;
    const began = x.Timer.now();
    while (wraps < 10) {
        if (x.Timer.elapsed(began) > x.Timer.milliseconds(250)) return error.PanelCalibrationTimeout;
        const current = try sampleScan();
        maximum = @max(maximum, current.line);
        minimum = @min(minimum, current.line);
        if (previous) |line| {
            if (line > current.line and line - current.line > 120) {
                const at = current.began +% ((current.ended -% current.began) / 2);
                if (wraps == 0) first = at;
                last = at;
                wraps += 1;
            }
        }
        previous = current.line;
        x.Timer.delayMicroseconds(10);
    }
    if (minimum != 0 or maximum != 243) return error.PanelCalibrationRange;
    const config = phase.Config{ .period = (last -% first) / 9, .lines = maximum + 1 };
    try config.validate();
    return config;
}

/// The inactive snapshot is CPU-owned until every dirty cache line has reached
/// physical RAM. DMA still receives the uncached alias and an immutable bank.
fn publishSnapshot(address: usize, length: usize) void {
    if (comptime @import("builtin").cpu.arch != .mipsel) return;
    const end = (address + length + 31) & ~@as(usize, 31);
    var line = address & ~@as(usize, 31);
    while (line < end) : (line += 32) asm volatile ("cache 0x15, 0(%[at])"
        :
        : [at] "r" (line),
        : .{ .memory = true });
    x.memoryBarrier();
}
