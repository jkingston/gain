//! Bounded, allocation-free diagnostics. Each owning task updates its own
//! counters; records are published only by the application/UI owner.
const std = @import("std");

pub const page_bytes = 4096;
pub const header_bytes = 40;
pub const record_bytes = 64;
pub const capacity = 32 * 1024 / record_bytes;

pub const Kind = enum(u16) {
    boot = 1,
    playback = 2,
    library = 3,
    power = 4,
    usb = 5,
    fault = 6,
    health = 7,
    task_times = 8,
    library_phases = 9,
    library_io = 10,
    library_changes = 11,
};

pub const Record = struct { kind: Kind, ticks: u64, values: [12]u32 = @splat(0) };

pub const records_per_page = (page_bytes - header_bytes - 4) / record_bytes;

pub const PageTicket = struct { front: u64, sequence: u64, count: usize };

/// The caller copies under its publication lock, then encodes and writes this
/// owned snapshot after releasing it. Appended records cannot change the page.
pub const Capture = struct {
    ticket: PageTicket = .{ .front = 0, .sequence = 0, .count = 0 },
    dropped: u32 = 0,
    repeated: u16 = 0,
    records: [records_per_page]Record = undefined,

    pub fn encode(self: *const Capture, output: *[page_bytes]u8, build: u64, session: u64) void {
        @memset(output, 0);
        @memcpy(output[0..4], "GLOG");
        put(u16, output, 4, 1);
        put(u16, output, 6, header_bytes);
        put(u64, output, 8, self.ticket.sequence);
        put(u64, output, 16, build);
        put(u64, output, 24, session);
        put(u32, output, 32, self.dropped);
        put(u16, output, 36, @intCast(self.ticket.count));
        put(u16, output, 38, self.repeated);
        for (self.records[0..self.ticket.count], 0..) |value, i| {
            const at = header_bytes + i * record_bytes;
            put(u16, output, at, @backingInt(value.kind));
            put(u64, output, at + 8, value.ticks);
            for (value.values, 0..) |v, j| put(u32, output, at + 16 + j * 4, v);
        }
        put(u32, output, page_bytes - 4, std.hash.Crc32.hash(output[0 .. page_bytes - 4]));
    }
};

pub const Collector = struct {
    records: [capacity]Record = undefined,
    head: usize = 0,
    front: u64 = 0,
    count: usize = 0,
    dropped: u32 = 0,
    sequence: u64 = 0,
    first_fault: ?Record = null,
    repeated_faults: u32 = 0,
    fault_keys: [16]?[12]u32 = @splat(null),
    suppressed_faults: u32 = 0,

    pub fn record(self: *Collector, value: Record) void {
        if (value.kind == .fault) {
            if (self.first_fault == null) self.first_fault = value;
            var empty: ?usize = null;
            for (self.fault_keys, 0..) |key, i| {
                if (key) |known| {
                    if (std.mem.eql(u32, &known, &value.values)) {
                        self.repeated_faults +|= 1;
                        return;
                    }
                } else if (empty == null) {
                    empty = i;
                }
            }
            if (empty) |i| self.fault_keys[i] = value.values else {
                self.suppressed_faults +|= 1;
                return;
            }
        }
        if (self.count == capacity) {
            self.head = (self.head + 1) % capacity;
            self.front +%= 1;
            self.count -= 1;
            self.dropped +|= 1;
        }
        self.records[(self.head + self.count) % capacity] = value;
        self.count += 1;
    }

    pub fn capture(self: *const Collector, out: *Capture) void {
        const n = @min(self.count, records_per_page);
        out.ticket = .{ .front = self.front, .sequence = self.sequence, .count = n };
        out.dropped = self.dropped +| self.suppressed_faults;
        out.repeated = @intCast(@min(65535, self.repeated_faults));
        for (0..n) |i| out.records[i] = self.records[(self.head + i) % capacity];
    }

    pub fn page(self: *const Collector, output: *[page_bytes]u8, build: u64, session: u64) usize {
        var snapshot: Capture = undefined;
        self.capture(&snapshot);
        snapshot.encode(output, build, session);
        return snapshot.ticket.count;
    }

    /// Drop only records actually represented by this successfully written page.
    /// Overflow may already have retired some of its prefix while I/O yielded.
    pub fn commitTicket(self: *Collector, ticket: PageTicket) !void {
        if (ticket.sequence != self.sequence or ticket.count == 0 or ticket.count > records_per_page) return error.StaleLogPage;
        const advanced = self.front -% ticket.front;
        const remaining = ticket.count -| @as(usize, @intCast(@min(advanced, ticket.count)));
        if (remaining > self.count) return error.StaleLogPage;
        self.head = (self.head + remaining) % capacity;
        self.front +%= remaining;
        self.count -= remaining;
        self.sequence +%= 1;
    }

    pub fn committed(self: *Collector, n: usize) void {
        self.commitTicket(.{ .front = self.front, .sequence = self.sequence, .count = n }) catch unreachable;
    }
};

fn put(comptime T: type, out: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, out[at..][0..@sizeOf(T)], value, .little);
}

pub fn validPage(bytes: []const u8) bool {
    return bytes.len == page_bytes and std.mem.readInt(u16, bytes[4..6], .little) == 1 and std.mem.readInt(u16, bytes[6..8], .little) == header_bytes and std.mem.readInt(u16, bytes[36..38], .little) <= (page_bytes - header_bytes - 4) / record_bytes and std.mem.eql(u8, bytes[0..4], "GLOG") and std.mem.readInt(u32, bytes[page_bytes - 4 ..][0..4], .little) == std.hash.Crc32.hash(bytes[0 .. page_bytes - 4]);
}

test "bounded diagnostics preserve counters and detect torn pages" {
    var collector: Collector = .{};
    for (0..capacity + 3) |i| collector.record(.{ .kind = .health, .ticks = i });
    try std.testing.expectEqual(3, collector.dropped);
    var bytes: [page_bytes]u8 = undefined;
    const n = collector.page(&bytes, 1, 2);
    try std.testing.expect(validPage(&bytes));
    bytes[111] ^= 1;
    try std.testing.expect(!validPage(&bytes));
    try std.testing.expectEqual(capacity, collector.count);
    collector.committed(n);
    try std.testing.expectEqual(capacity - n, collector.count);
    collector.record(.{ .kind = .fault, .ticks = 7 });
    collector.record(.{ .kind = .fault, .ticks = 8 });
    try std.testing.expectEqual(7, collector.first_fault.?.ticks);
    try std.testing.expectEqual(1, collector.repeated_faults);
}

test "an error storm cannot evict the first fault or flood the log" {
    var collector: Collector = .{};
    const first = Record{ .kind = .fault, .ticks = 123, .values = .{ 1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    for (0..10000) |_| collector.record(first);
    try std.testing.expectEqual(1, collector.count);
    try std.testing.expectEqual(9999, collector.repeated_faults);
    for (0..100) |i| {
        var distinct = first;
        distinct.values[0] = @intCast(i + 10);
        collector.record(distinct);
    }
    try std.testing.expectEqual(16, collector.count);
    try std.testing.expectEqual(85, collector.suppressed_faults);
    try std.testing.expectEqual(123, collector.first_fault.?.ticks);
}

pub const Cursor = struct { sequence: u64, page: u32 };

pub fn cursorEncode(value: Cursor, out: *[512]u8) void {
    @memset(out, 0);
    @memcpy(out[0..4], "GLCP");
    put(u32, out, 4, 1);
    put(u64, out, 8, value.sequence);
    put(u32, out, 16, value.page);
    put(u32, out, 508, std.hash.Crc32.hash(out[0..508]));
}

pub fn cursorDecode(bytes: *const [512]u8, pages: u32) ?Cursor {
    if (!std.mem.eql(u8, bytes[0..4], "GLCP") or std.mem.readInt(u32, bytes[4..8], .little) != 1 or std.mem.readInt(u32, bytes[508..512], .little) != std.hash.Crc32.hash(bytes[0..508])) return null;
    const page = std.mem.readInt(u32, bytes[16..20], .little);
    if (page >= pages) return null;
    return .{ .page = page, .sequence = std.mem.readInt(u64, bytes[8..16], .little) };
}

test "redundant cursor rejects every torn byte and out of bounds page" {
    var bytes: [512]u8 = undefined;
    cursorEncode(.{ .sequence = 99, .page = 17 }, &bytes);
    try std.testing.expectEqual(99, cursorDecode(&bytes, 20).?.sequence);
    try std.testing.expect(cursorDecode(&bytes, 17) == null);
    for (0..bytes.len) |i| {
        bytes[i] ^= 1;
        try std.testing.expect(cursorDecode(&bytes, 20) == null);
        bytes[i] ^= 1;
    }
}

test "a log page owns its captured records and commit preserves concurrently appended events" {
    var collector = Collector{};
    for (0..capacity) |i| collector.record(.{ .kind = .health, .ticks = i });
    var snapshot: Capture = undefined;
    collector.capture(&snapshot);
    for (capacity..capacity + 11) |i| collector.record(.{ .kind = .health, .ticks = i });
    var bytes: [page_bytes]u8 = undefined;
    snapshot.encode(&bytes, 4, 7);
    try std.testing.expect(validPage(&bytes));
    try std.testing.expectEqual(0, std.mem.readInt(u64, bytes[header_bytes + 8 ..][0..8], .little));
    try collector.commitTicket(snapshot.ticket);
    try std.testing.expectEqual(capacity - (records_per_page - 11), collector.count);
    try std.testing.expectEqual(records_per_page, collector.records[collector.head].ticks);
    const count = collector.count;
    try std.testing.expectError(error.StaleLogPage, collector.commitTicket(snapshot.ticket));
    try std.testing.expectEqual(count, collector.count);
}

test "log overflow can retire a whole captured page without discarding newer unwritten events" {
    var collector = Collector{};
    for (0..capacity) |i| collector.record(.{ .kind = .health, .ticks = i });
    var snapshot: Capture = undefined;
    collector.capture(&snapshot);
    for (capacity..capacity * 3) |i| collector.record(.{ .kind = .health, .ticks = i });
    const first = collector.records[collector.head].ticks;
    try collector.commitTicket(snapshot.ticket);
    try std.testing.expectEqual(capacity, collector.count);
    try std.testing.expectEqual(first, collector.records[collector.head].ticks);
}

test "log page commit handles front-counter wrap and leaves unpublished tail events" {
    var collector = Collector{ .front = std.math.maxInt(u64) - 5 };
    for (0..capacity) |i| collector.record(.{ .kind = .health, .ticks = i });
    var snapshot: Capture = undefined;
    collector.capture(&snapshot);
    for (capacity..capacity + 10) |i| collector.record(.{ .kind = .health, .ticks = i });
    try collector.commitTicket(snapshot.ticket);
    try std.testing.expectEqual(records_per_page, collector.records[collector.head].ticks);
    collector = .{};
    for (0..5) |i| collector.record(.{ .kind = .health, .ticks = i });
    collector.capture(&snapshot);
    for (5..15) |i| collector.record(.{ .kind = .health, .ticks = i });
    try collector.commitTicket(snapshot.ticket);
    try std.testing.expectEqual(10, collector.count);
    try std.testing.expectEqual(5, collector.records[collector.head].ticks);
}
