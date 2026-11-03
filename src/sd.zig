const x1000 = @import("x1000.zig");

pub const sector_bytes = 512;

pub const Error = error{
    CardAbsent,
    ControllerTimeout,
    CommandTimeout,
    CommandFailed,
    CardInitializationTimeout,
    InvalidCardCapacity,
    InvalidBuffer,
    CachedDmaBuffer,
    TransferTooLarge,
    OutOfRange,
    CardStatusError,
};

const Response = enum(u3) {
    none = 0,
    short = 1,
    long = 2,
    short_no_crc = 3,
};

const Command = struct {
    index: u8,
    argument: u32,
    response: Response,
    busy: bool = false,
    data: ?[]u8 = null,
    block_bytes: u16 = 0,
    blocks: u16 = 0,
    write: bool = false,
};

/// Pure command-completion policy, shared by polling and IRQ-backed waits.
/// A DMA completion also proves a response is ready even if its earlier flag
/// was coalesced. Error flags always take precedence over a completion.
const Completion = struct {
    done: u32,
    response_pending: bool,

    const Decision = struct {
        failed: bool = false,
        read_response: bool = false,
        acknowledge_response: bool = false,
        complete: bool = false,
    };

    fn observe(self: *Completion, flags: u32) Decision {
        if (flags & x1000.Msc0.error_flags != 0) return .{ .failed = true };
        const complete = flags & self.done != 0;
        const response = self.response_pending and (complete or flags & x1000.Msc0.response_end != 0);
        if (response) self.response_pending = false;
        return .{
            .read_response = response,
            .acknowledge_response = response and flags & x1000.Msc0.response_end != 0,
            .complete = complete,
        };
    }

    fn waitMask(self: Completion) u32 {
        return self.done | x1000.Msc0.error_flags | if (self.response_pending) x1000.Msc0.response_end else @as(u32, 0);
    }
};

/// Optional task suspension between hardware events. Initialization and callers
/// without an executive retain the polling path.
pub const Waiter = struct {
    context: *anyopaque,
    prepare: *const fn (*anyopaque, u32) void,
    wait: *const fn (*anyopaque, u32) void,
};

pub const Counters = struct {
    read_sectors: u64 = 0,
    write_sectors: u64 = 0,
    reads: u32 = 0,
    writes: u32 = 0,
    failures: u32 = 0,
    ticks: u64 = 0,
};

/// Native SD block controller. Board supplies compile-time wiring and
/// clocks; the caller supplies uncached DMA storage so no cache maintenance is
/// needed in the playback path.
pub fn Controller(comptime Board: type) type {
    return struct {
        const Self = @This();

        pub const Resources = struct {
            descriptor: *volatile x1000.Msc0.DmaDescriptor,
            switch_status: *align(4) [64]u8,
        };

        resources: Resources,
        waiter: ?Waiter = null,
        /// Optional watchdog maintenance during bounded synchronous waits.
        /// Playback uses its preemptive UI task instead.
        keep_alive: ?*const fn () void = null,
        attributes: u32 = x1000.Msc0.read_trigger_32 |
            x1000.Msc0.write_trigger_32 | x1000.Msc0.initialize,
        high_capacity: bool = false,
        rca: u32 = 0,
        capacity_sectors: u64 = 0,
        bus_hz: u32 = 0,
        last_command: u8 = 0,
        last_status: u32 = 0,
        last_flags: u32 = 0,
        counters: Counters = .{},

        pub fn initialize(resources: Resources) Error!Self {
            if (!dmaAddress(@intFromPtr(resources.descriptor)) or
                !dmaAddress(@intFromPtr(resources.switch_status)))
            {
                return error.CachedDmaBuffer;
            }

            var self = Self{ .resources = resources };
            Board.card_power.output(true);
            Board.card_detect.input();
            x1000.Timer.delayMicroseconds(5_000);
            if (Board.card_detect.get()) return error.CardAbsent;

            x1000.Gpio.selectFunction1(.a, Board.port_a_function_1);
            x1000.Cpm.ungate(.msc0);
            x1000.Cpm.msc0_clock.write(Board.controller_clock_configuration);
            try waitClear(x1000.Cpm.msc0_clock, x1000.Cpm.msc_clock_busy, 100_000);
            x1000.Cpm.msc0_clock.clear(x1000.Cpm.msc_clock_change_enable);

            x1000.Msc0.control.write(x1000.Msc0.reset);
            x1000.Timer.delayMicroseconds(100);
            x1000.Msc0.control.write(0);
            try waitClear(x1000.Msc0.status, x1000.Msc0.resetting, 100_000);

            x1000.Msc0.interrupt_mask.write(0xffff_ffff);
            x1000.Msc0.interrupt_flags.write(0xffff_ffff);
            x1000.Msc0.response_timeout.write(0xff);
            x1000.Msc0.read_timeout.write(0xffff_ffff);
            x1000.Msc0.clock_rate.write(Board.identification_clock_divider);
            x1000.Msc0.control_2.write(0);
            x1000.Msc0.low_power.write(1);

            try self.initializeCard();
            return self;
        }

        pub fn readBlocks(self: *Self, first_lba: u32, output: []u8) Error!void {
            const began = x1000.Timer.now();
            defer self.counters.ticks +|= x1000.Timer.elapsed(began);
            self.counters.reads +|= 1;
            errdefer self.counters.failures +|= 1;
            try self.transferBlocks(first_lba, output, false);
            self.counters.read_sectors +|= output.len / sector_bytes;
        }

        /// Return only after the controller's programming completion and CMD13
        /// confirm the card is ready. USB must never acknowledge DMA-only writes.
        pub fn writeBlocks(self: *Self, first_lba: u32, input: []const u8) Error!void {
            const began = x1000.Timer.now();
            defer self.counters.ticks +|= x1000.Timer.elapsed(began);
            self.counters.writes +|= 1;
            errdefer self.counters.failures +|= 1;
            try self.transferBlocks(first_lba, @constCast(input), true);
            try self.sync();
            self.counters.write_sectors +|= input.len / sector_bytes;
        }

        pub fn present(_: *const Self) bool {
            return !Board.card_detect.get();
        }

        pub fn sync(self: *Self) Error!void {
            const began = x1000.Timer.now();
            while (x1000.Timer.elapsed(began) < x1000.Timer.milliseconds(5_000)) {
                if (self.keep_alive) |keep_alive| keep_alive();
                if (!self.present()) return error.CardAbsent;
                var response: [4]u32 = @splat(0);
                try self.noData(13, self.rca, .short, false, &response);
                if (response[0] & card_status_errors != 0) return error.CardStatusError;
                if (response[0] & card_ready_for_data != 0 and (response[0] >> 9) & 15 == card_transfer_state) return;
            }
            return error.CommandTimeout;
        }

        fn transferBlocks(self: *Self, first_lba: u32, output: []u8, write: bool) Error!void {
            if (Board.card_detect.get()) return error.CardAbsent;
            if (output.len == 0 or output.len % sector_bytes != 0 or
                @intFromPtr(output.ptr) & 3 != 0)
            {
                return error.InvalidBuffer;
            }
            if (!dmaAddress(@intFromPtr(output.ptr))) return error.CachedDmaBuffer;
            const requested_blocks = output.len / sector_bytes;
            if (@as(u64, first_lba) + requested_blocks > self.capacity_sectors) {
                return error.OutOfRange;
            }

            var lba = first_lba;
            var offset: usize = 0;
            while (offset < output.len) {
                const remaining_blocks = (output.len - offset) / sector_bytes;
                const block_count: u16 = @intCast(@min(remaining_blocks, maximum_blocks_per_command));
                const byte_count = @as(usize, block_count) * sector_bytes;
                const command = transferCommand(write, block_count);
                var response: [4]u32 = @splat(0);
                try self.issue(.{
                    .index = command,
                    .argument = self.cardArgument(lba),
                    .response = .short,
                    .data = output[offset..][0..byte_count],
                    .block_bytes = sector_bytes,
                    .blocks = block_count,
                    .write = write,
                }, &response);
                if (write and response[0] & card_status_errors != 0) return error.CardStatusError;
                offset += byte_count;
                lba +%= block_count;
                if (lba == 0 and offset < output.len) return error.TransferTooLarge;
            }
        }

        fn initializeCard(self: *Self) Error!void {
            var response: [4]u32 = @splat(0);
            try self.noData(0, 0, .none, false, &response);

            const version_2 = blk: {
                self.noData(8, 0x1aa, .short, false, &response) catch break :blk false;
                break :blk response[0] & 0xfff == 0x1aa;
            };
            x1000.Msc0.interrupt_flags.write(0xffff_ffff);

            var ocr: u32 = 0;
            const start = x1000.Timer.now();
            while (x1000.Timer.elapsed(start) < x1000.Timer.milliseconds(2_000)) {
                self.noData(55, 0, .short, false, &response) catch continue;
                const argument: u32 = 0x0030_0000 |
                    (if (version_2) x1000.bit(30) else 0);
                self.noData(41, argument, .short_no_crc, false, &response) catch continue;
                ocr = response[0];
                if (ocr & x1000.bit(31) != 0) break;
            }
            if (ocr & x1000.bit(31) == 0) return error.CardInitializationTimeout;
            self.high_capacity = ocr & x1000.bit(30) != 0;

            try self.noData(2, 0, .long, false, &response);
            try self.noData(3, 0, .short, false, &response);
            self.rca = response[0] & 0xffff_0000;
            try self.noData(9, self.rca, .long, false, &response);
            self.capacity_sectors = capacityFromCsd(response);
            if (self.capacity_sectors == 0) return error.InvalidCardCapacity;
            try self.noData(7, self.rca, .short, true, &response);
            if (!self.high_capacity) try self.noData(16, sector_bytes, .short, false, &response);

            try self.noData(55, self.rca, .short, false, &response);
            try self.noData(6, 2, .short, false, &response);
            self.attributes |= x1000.Msc0.bus_width_4;
            try self.setBusClock(false);

            @memset(self.resources.switch_status, 0);
            self.issue(.{
                .index = 6,
                .argument = 0x80ff_fff1,
                .response = .short,
                .data = self.resources.switch_status,
                .block_bytes = 64,
                .blocks = 1,
            }, &response) catch return;
            if (self.resources.switch_status[16] & 0x0f == 1) try self.setBusClock(true);
        }

        fn setBusClock(self: *Self, high_speed: bool) Error!void {
            try waitClear(x1000.Msc0.status, x1000.Msc0.card_busy, 100_000);
            if (high_speed) {
                x1000.Msc0.clock_rate.write(Board.high_speed_clock_divider);
                x1000.Msc0.low_power.write(0x9000_0001);
                x1000.Msc0.control_2.write(1);
                self.bus_hz = Board.high_speed_bus_hz;
            } else {
                x1000.Msc0.clock_rate.write(Board.default_clock_divider);
                x1000.Msc0.low_power.write(1);
                x1000.Msc0.control_2.write(0);
                self.bus_hz = Board.default_bus_hz;
            }
        }

        fn noData(
            self: *Self,
            index: u8,
            argument: u32,
            response_kind: Response,
            busy: bool,
            response: *[4]u32,
        ) Error!void {
            try self.issue(.{
                .index = index,
                .argument = argument,
                .response = response_kind,
                .busy = busy,
            }, response);
        }

        fn issue(self: *Self, command: Command, response_words: *[4]u32) Error!void {
            defer if (self.waiter != null) {
                x1000.Msc0.interrupt_mask.write(0xffffffff);
                x1000.Interrupts.mask(.msc0);
            };
            self.last_command = command.index;
            var attributes = self.attributes | @backingInt(command.response);
            self.attributes &= ~x1000.Msc0.initialize;
            var done = x1000.Msc0.response_end;

            if (command.busy) {
                attributes |= x1000.Msc0.response_busy;
                done = x1000.Msc0.program_done;
            }
            if (command.data) |data| {
                if (data.len == 0 or data.len > maximum_transfer_bytes or
                    !dmaAddress(@intFromPtr(data.ptr)))
                {
                    return error.InvalidBuffer;
                }
                self.resources.descriptor.* = .{
                    .next = 0,
                    .memory = x1000.physicalAddress(@intFromPtr(data.ptr)),
                    .length = @intCast(data.len),
                    .command = x1000.Msc0.dma_descriptor_end,
                };
                attributes |= x1000.Msc0.data_enabled;
                if (command.blocks > 1) attributes |= x1000.Msc0.automatic_stop;
                if (command.write) attributes |= x1000.Msc0.data_write;
                done = if (command.write) x1000.Msc0.dma_write_done else x1000.Msc0.dma_read_done;
                x1000.Msc0.dma_control.write(0);
                x1000.Msc0.dma_descriptor.write(x1000.physicalAddress(@intFromPtr(self.resources.descriptor)));
            }

            x1000.Msc0.interrupt_mask.write(0xffff_ffff);
            x1000.Msc0.interrupt_flags.write(0xffff_ffff);
            x1000.Msc0.block_count.write(command.blocks);
            x1000.Msc0.block_length.write(command.block_bytes);
            x1000.Msc0.command.write(command.index);
            x1000.Msc0.argument.write(command.argument);
            x1000.Msc0.command_attributes.write(attributes);
            const Arm = struct {
                pub fn mask(_: *@This()) u32 {
                    return x1000.Interrupts.disableCpu();
                }
                pub fn restore(_: *@This(), status: u32) void {
                    x1000.Interrupts.restoreCpu(status);
                }
                pub fn beginCommand(_: *@This()) void {
                    x1000.Msc0.control.write(x1000.Msc0.start_operation);
                }
                pub fn dma(_: *@This()) void {
                    x1000.Msc0.dma_control.write(1);
                }
            };
            var arm: Arm = .{};
            @import("sd_arming.zig").start(&arm, command.data != null);

            var completion = Completion{ .done = done, .response_pending = command.response != .none };
            const start = x1000.Timer.now();
            while (x1000.Timer.elapsed(start) < x1000.Timer.milliseconds(5_000)) {
                if (self.keep_alive) |keep_alive| keep_alive();
                const flags = x1000.Msc0.interrupt_flags.read();
                const decision = completion.observe(flags);
                if (decision.failed) {
                    self.recordFailure(flags);
                    return error.CommandFailed;
                }
                if (decision.read_response) readResponse(command.response, response_words);
                if (decision.acknowledge_response) x1000.Msc0.interrupt_flags.write(x1000.Msc0.response_end);
                if (decision.complete) {
                    x1000.Msc0.dma_control.write(0);
                    self.last_status = x1000.Msc0.status.read();
                    self.last_flags = flags;
                    return;
                }
                if (self.waiter) |waiter| {
                    const wanted = completion.waitMask();
                    waiter.prepare(waiter.context, wanted);
                    // Preparation may race completion. Never sleep after the
                    // hardware predicate has already become true.
                    if (x1000.Msc0.interrupt_flags.read() & wanted != 0) continue;
                    const elapsed = x1000.Timer.elapsed(start);
                    const timeout = x1000.Timer.milliseconds(5_000);
                    if (elapsed < timeout) waiter.wait(waiter.context, timeout - elapsed);
                }
            }
            self.recordFailure(x1000.Msc0.interrupt_flags.read());
            return error.CommandTimeout;
        }

        fn recordFailure(self: *Self, flags: u32) void {
            x1000.Msc0.dma_control.write(0);
            self.last_status = x1000.Msc0.status.read();
            self.last_flags = flags;
        }

        fn cardArgument(self: Self, lba: u32) u32 {
            return if (self.high_capacity) lba else lba *% sector_bytes;
        }
    };
}

fn readResponse(kind: Response, words: *[4]u32) void {
    var value = x1000.Msc0.response.read();
    if (kind == .long) {
        for (0..4) |index| {
            var word = value << 24;
            value = x1000.Msc0.response.read();
            word |= value << 8;
            value = x1000.Msc0.response.read();
            word |= value >> 8;
            words[index] = word;
        }
    } else if (kind != .none) {
        var word = value << 24;
        value = x1000.Msc0.response.read();
        word |= value << 8;
        value = x1000.Msc0.response.read();
        word |= value & 0xff;
        words[0] = word;
    }
}

fn waitClear(comptime register: type, mask: u32, timeout_microseconds: u32) Error!void {
    const start = x1000.Timer.now();
    while (register.read() & mask != 0) {
        if (x1000.Timer.elapsed(start) >= x1000.Timer.microseconds(timeout_microseconds)) {
            return error.ControllerTimeout;
        }
    }
}

fn dmaAddress(address: usize) bool {
    return x1000.isUncachedAddress(address) and address & 3 == 0;
}

fn capacityFromCsd(csd: [4]u32) u64 {
    const version = extractBits(csd, 127, 2);
    if (version == 0) {
        const size = extractBits(csd, 73, 12) + 1;
        const multiplier = @as(u32, 4) << @intCast(extractBits(csd, 49, 3));
        const block_length = @as(u32, 1) << @intCast(extractBits(csd, 83, 4));
        return @as(u64, size) * multiplier * (block_length / sector_bytes);
    }
    if (version == 1) return @as(u64, extractBits(csd, 69, 22) + 1) << 10;
    if (version == 2) return @as(u64, extractBits(csd, 75, 28) + 1) << 10;
    return 0;
}

fn extractBits(words: [4]u32, initial_start: u32, size: u5) u32 {
    const start = 127 - initial_start;
    const word_index = start / 32;
    const bit_index: u5 = @truncate(start % 32);
    var value = words[word_index] << bit_index;
    if (@as(u32, bit_index) + size > 32) {
        const shift: u5 = @intCast(32 - @as(u32, bit_index));
        value |= words[word_index + 1] >> shift;
    }
    const final_shift: u5 = @intCast(32 - @as(u32, size));
    return value >> final_shift;
}

const maximum_blocks_per_command = 65_535;
const maximum_transfer_bytes = @as(usize, maximum_blocks_per_command) * sector_bytes;
const card_status_errors: u32 = 0xfdffe008;
const card_ready_for_data: u32 = 1 << 8;
const card_transfer_state: u32 = 4;

fn transferCommand(write: bool, blocks: u16) u8 {
    return if (write) (if (blocks == 1) @as(u8, 24) else 25) else (if (blocks == 1) @as(u8, 17) else 18);
}

test "SD write completion cannot succeed on response or DMA completion alone" {
    const testing = @import("std").testing;
    try testing.expectEqual(24, transferCommand(true, 1));
    try testing.expectEqual(25, transferCommand(true, 2));
    try testing.expectEqual(17, transferCommand(false, 1));
    try testing.expectEqual(18, transferCommand(false, 2));
    for ([_]u32{ x1000.Msc0.response_end, x1000.Msc0.dma_read_done, 1 << 16, 1 << 0, x1000.Msc0.program_done }) |flag| {
        var completion = Completion{ .done = x1000.Msc0.dma_write_done, .response_pending = true };
        try testing.expect(!completion.observe(flag).complete);
        try testing.expect(completion.observe(x1000.Msc0.dma_write_done).complete);
    }
}

test "CSD v2 capacity is measured in 512-byte sectors" {
    var csd: [4]u32 = @splat(0);
    csd[0] = 1 << 30;
    try @import("std").testing.expectEqual(@as(u64, 1_024), capacityFromCsd(csd));
}

test "read-only controller declarations compile as one board specialization" {
    const MockBoard = struct {
        const card_power = x1000.Gpio.Pin{ .port = .b, .index = 10 };
        const card_detect = x1000.Gpio.Pin{ .port = .b, .index = 11 };
        const port_a_function_1: u32 = @as(u32, 0x3f) << 20;
        const controller_clock_configuration = x1000.bit(31) |
            x1000.Cpm.msc_clock_change_enable | 5;
        const identification_clock_divider: u32 = 7;
        const default_clock_divider: u32 = 1;
        const high_speed_clock_divider: u32 = 0;
        const default_bus_hz: u32 = 25_000_000;
        const high_speed_bus_hz: u32 = 50_000_000;
    };
    @import("std").testing.refAllDecls(Controller(MockBoard));
}

test "SD response and DMA completion remain correct under coalesced IRQ observations" {
    const testing = @import("std").testing;
    for (0..8) |response_at| for (0..8) |dma_at| {
        var state = Completion{ .done = x1000.Msc0.dma_read_done, .response_pending = true };
        var reads: usize = 0;
        var finished = false;
        for (0..8) |step| {
            var flags: u32 = 0;
            if (step >= response_at) flags |= x1000.Msc0.response_end;
            if (step >= dma_at) flags |= x1000.Msc0.dma_read_done;
            const decision = state.observe(flags);
            reads += @intFromBool(decision.read_response);
            try testing.expect(!decision.failed);
            if (!state.response_pending) try testing.expectEqual(@as(u32, 0), state.waitMask() & x1000.Msc0.response_end);
            if (decision.complete) {
                finished = true;
                break;
            }
        }
        try testing.expect(finished);
        try testing.expectEqual(@as(usize, 1), reads);
    };
}

test "SD errors dominate completion and no-response commands never read the response FIFO" {
    const testing = @import("std").testing;

    var state = Completion{ .done = x1000.Msc0.dma_read_done, .response_pending = true };
    const failure = state.observe(x1000.Msc0.dma_read_done | x1000.Msc0.response_end | (1 << 8));
    try testing.expect(failure.failed and !failure.read_response and !failure.complete);
    state = .{ .done = x1000.Msc0.response_end, .response_pending = false };
    const complete = state.observe(x1000.Msc0.response_end);
    try testing.expect(complete.complete and !complete.read_response and !complete.acknowledge_response);
}

test "SD wait mask changes only after consuming a response and always includes errors" {
    const testing = @import("std").testing;

    var state = Completion{ .done = x1000.Msc0.dma_read_done, .response_pending = true };
    const before = state.waitMask();
    try testing.expect(!state.observe(0).complete);
    try testing.expectEqual(before, state.waitMask());
    const response = state.observe(x1000.Msc0.response_end);
    try testing.expect(response.read_response and response.acknowledge_response and !response.complete);
    try testing.expectEqual(x1000.Msc0.dma_read_done | x1000.Msc0.error_flags, state.waitMask());
    try testing.expect(!state.observe(x1000.Msc0.response_end).read_response);
    try testing.expect(state.observe(x1000.Msc0.dma_read_done).complete);
}
