//! One reserved TLB entry gives USB buffers identical CPU and physical
//! addresses. Both pages are uncached, so controller handoffs need no cache
//! maintenance. Ordinary application and SD buffers keep their existing aliases.
const std = @import("std");

pub const page_bytes = 64 * 1024;
pub const window_bytes = 2 * page_bytes;
pub const entry_index = 31;
const minimum_page_bytes = 4096;
const physical_space_bytes = 1 << 29;
const page_mask = (page_bytes - minimum_page_bytes) * 2;
const uncached = 2 << 3;
const global_valid_dirty = 7;

pub const Entry = struct { low_even: u32, low_odd: u32, mask: u32, high: u32 };

pub const Scratch = struct { index: u32, entry: Entry };

fn overlaps(entry: Entry, start: u32) bool {
    const valid = 1 << 1;
    if ((entry.low_even | entry.low_odd) & valid == 0) return false;
    const mask = entry.mask | 0x1fff; // Page-pair offset and ASID bits.
    const first: u64 = entry.high & ~mask;
    const end = first + @as(u64, mask) + 1;
    return first < @as(u64, start) + window_bytes and start < end;
}

pub fn identityEntry(start: u32) !Entry {
    if (start % window_bytes != 0 or start > physical_space_bytes - window_bytes) return error.InvalidDmaWindow;
    return .{
        .low_even = (start >> 6) | uncached | global_valid_dirty,
        .low_odd = ((start + page_bytes) >> 6) | uncached | global_valid_dirty,
        .mask = page_mask,
        .high = start,
    };
}

/// Cpu supplies the small CP0 boundary, allowing save/restore ordering to be
/// checked deterministically without emulating the CPU or USB controller.
pub fn Window(comptime Cpu: type) type {
    return struct {
        const Self = @This();
        original: ?Entry = null,
        start: u32 = 0,

        pub fn install(self: *Self, start: u32) !void {
            const mapped = try identityEntry(start);
            if (self.original != null) {
                if (self.start != start) return error.DmaWindowOwned;
                return;
            }
            if (Cpu.entryCount() <= entry_index) return error.UnsupportedMmu;
            const interrupts = Cpu.disableInterrupts();
            defer Cpu.restoreInterrupts(interrupts);
            const scratch = Cpu.scratch();
            defer Cpu.restoreScratch(scratch);
            // A global identity mapping must not alias another valid pair,
            // including mappings left by a previous application.
            for (0..Cpu.entryCount()) |index| {
                if (index != entry_index and overlaps(Cpu.readEntry(@intCast(index)), start)) return error.DmaWindowConflict;
            }
            self.original = Cpu.readEntry(entry_index);
            Cpu.writeEntry(entry_index, mapped);
            self.start = start;
        }

        /// Call only once all DMA engines using this window have stopped.
        pub fn restore(self: *Self) void {
            const original = self.original orelse return;
            const interrupts = Cpu.disableInterrupts();
            defer Cpu.restoreInterrupts(interrupts);
            const scratch = Cpu.scratch();
            defer Cpu.restoreScratch(scratch);
            Cpu.writeEntry(entry_index, original);
            self.original = null;
        }
    };
}

const Register = enum(u5) { index = 0, entry_low_even = 2, entry_low_odd = 3, page_mask = 5, entry_high = 10, status = 12 };

fn readCp0(comptime register: Register) u32 {
    return asm volatile (std.fmt.comptimePrint("mfc0 %[value], ${d}", .{@backingInt(register)})
        : [value] "=r" (-> u32),
    );
}

fn writeCp0(comptime register: Register, value: u32) void {
    asm volatile (std.fmt.comptimePrint("mtc0 %[value], ${d}; ehb", .{@backingInt(register)})
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

const NativeCpu = struct {
    fn disableInterrupts() u32 {
        const status = readCp0(.status);
        asm volatile ("di; ehb" ::: .{ .memory = true });
        return status;
    }

    fn restoreInterrupts(status: u32) void {
        writeCp0(.status, status);
    }

    fn entryCount() u32 {
        const config = asm volatile ("mfc0 %[value], $16, 1"
            : [value] "=r" (-> u32),
        );
        return ((config >> 25) & 63) + 1;
    }

    fn currentEntry() Entry {
        return .{
            .low_even = readCp0(.entry_low_even),
            .low_odd = readCp0(.entry_low_odd),
            .mask = readCp0(.page_mask),
            .high = readCp0(.entry_high),
        };
    }

    fn scratch() Scratch {
        return .{ .index = readCp0(.index), .entry = currentEntry() };
    }

    fn loadEntry(entry: Entry) void {
        writeCp0(.entry_low_even, entry.low_even);
        writeCp0(.entry_low_odd, entry.low_odd);
        writeCp0(.page_mask, entry.mask);
        writeCp0(.entry_high, entry.high);
    }

    fn restoreScratch(value: Scratch) void {
        loadEntry(value.entry);
        writeCp0(.index, value.index);
    }

    fn readEntry(index: u32) Entry {
        writeCp0(.index, index);
        asm volatile ("tlbr; ehb" ::: .{ .memory = true });
        return currentEntry();
    }

    fn writeEntry(index: u32, entry: Entry) void {
        writeCp0(.index, index);
        loadEntry(entry);
        asm volatile ("tlbwi; ehb" ::: .{ .memory = true });
    }
};

pub const IdentityWindow = Window(NativeCpu);

test "identity mapping encodes two uncached global writable pages" {
    const entry = try identityEntry(0x240000);
    try std.testing.expectEqual(Entry{ .low_even = 0x9017, .low_odd = 0x9417, .mask = 0x1e000, .high = 0x240000 }, entry);
    for ([_]u32{ 1, 0x241000, 0x1fff0000, 0xffffffff }) |bad| try std.testing.expectError(error.InvalidDmaWindow, identityEntry(bad));
}

const FakeCpu = struct {
    var interrupts: u32 = 1;

    fn disableInterrupts() u32 {
        const old = interrupts;
        interrupts = 0;
        return old;
    }

    fn restoreInterrupts(status: u32) void {
        interrupts = status;
    }
    var count: u32 = 32;
    var registers: Scratch = undefined;
    var entries: [32]Entry = undefined;
    var writes: usize = 0;

    fn entryCount() u32 {
        return count;
    }

    fn scratch() Scratch {
        return registers;
    }

    fn restoreScratch(value: Scratch) void {
        registers = value;
    }

    fn readEntry(index: u32) Entry {
        registers = .{ .index = index, .entry = entries[index] };
        return entries[index];
    }

    fn writeEntry(index: u32, entry: Entry) void {
        std.debug.assert(interrupts == 0);
        registers = .{ .index = index, .entry = entry };
        entries[index] = entry;
        writes += 1;
    }
};

test "mapping preserves every other entry and current CP0 state across repeated lifecycles" {
    var random = std.Random.DefaultPrng.init(0x5553424d);
    for (0..256) |_| {
        FakeCpu.count = 32;
        for (&FakeCpu.entries) |*entry| entry.* = .{
            .low_even = random.random().int(u32),
            .low_odd = random.random().int(u32),
            .mask = 0,
            .high = random.random().int(u32) | 0xc0000000,
        };
        FakeCpu.registers = .{ .index = 5, .entry = FakeCpu.entries[5] };
        FakeCpu.writes = 0;
        const original = FakeCpu.entries;
        const scratch = FakeCpu.registers;
        var window: Window(FakeCpu) = .{};
        try window.install(0x240000);
        try window.install(0x240000);
        try std.testing.expectError(error.DmaWindowOwned, window.install(0x260000));
        try std.testing.expectEqual(1, FakeCpu.writes);
        try std.testing.expectEqual(scratch, FakeCpu.registers);
        try std.testing.expectEqual(1, FakeCpu.interrupts);
        for (0..entry_index) |i| try std.testing.expectEqual(original[i], FakeCpu.entries[i]);
        FakeCpu.registers.index = 12;
        const later = FakeCpu.registers;
        window.restore();
        window.restore();
        try std.testing.expectEqual(2, FakeCpu.writes);
        try std.testing.expectEqual(later, FakeCpu.registers);
        try std.testing.expectEqualDeep(original, FakeCpu.entries);
    }
    FakeCpu.count = 16;
    const before = FakeCpu.registers;
    var window: Window(FakeCpu) = .{};
    try std.testing.expectError(error.UnsupportedMmu, window.install(0x240000));
    try std.testing.expectEqual(before, FakeCpu.registers);
}

test "conflicting inherited mappings are refused without changing CPU state" {
    FakeCpu.count = 32;
    FakeCpu.writes = 0;
    const empty = Entry{ .low_even = 0, .low_odd = 0, .mask = 0, .high = 0 };
    FakeCpu.entries = @splat(empty);
    FakeCpu.entries[3] = try identityEntry(0x240000);
    FakeCpu.registers = .{ .index = 8, .entry = empty };
    const original = FakeCpu.entries;
    const scratch = FakeCpu.registers;
    var window: Window(FakeCpu) = .{};
    try std.testing.expectError(error.DmaWindowConflict, window.install(0x240000));
    try std.testing.expectEqual(0, FakeCpu.writes);
    try std.testing.expectEqual(scratch, FakeCpu.registers);
    try std.testing.expectEqualDeep(original, FakeCpu.entries);
    try std.testing.expect(window.original == null);
    try std.testing.expectEqual(1, FakeCpu.interrupts);
}
