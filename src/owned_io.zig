//! Cooperate only at complete sector boundaries. Reads poll before filling the
//! shared DMA bounce; writes poll after consuming it. Seek/sync must not poll:
//! a freshly encoded commit header may already be waiting in that same bounce.
const std = @import("std");

pub fn wrap(raw: anytype, service: anytype, cancelled: *bool) Cursor(@typeInfo(@TypeOf(raw)).pointer.child, @TypeOf(service)) {
    return .{ .raw = raw, .service = service, .cancelled = cancelled };
}

pub fn Cursor(comptime Raw: type, comptime ServiceType: type) type {
    return struct {
        raw: *Raw,
        service: ServiceType,
        cancelled: *bool,

        fn poll(self: *@This()) !void {
            if (self.service) |service| if (service.poll(service.context)) {
                self.cancelled.* = true;
                return error.Cancelled;
            };
        }

        pub fn seekTo(self: *@This(), offset: u32) !void {
            try self.raw.seekTo(offset);
        }

        pub fn read(self: *@This(), output: []u8) !usize {
            try self.poll();
            return self.raw.read(output);
        }

        pub fn write(self: *@This(), bytes: []const u8) !void {
            try self.raw.write(bytes);
            try self.poll();
        }

        pub fn sync(self: *@This()) !void {
            try self.raw.sync();
        }
    };
}

const TestJournal = @import("owned_journal.zig").Journal("GCOO".*, 4096);
const Memory = struct {
    bytes: []u8,
    bounce: *[512]u8,
    at: usize = 0,

    pub fn seekTo(self: *Memory, offset: u32) !void {
        self.at = offset;
    }

    pub fn read(self: *Memory, output: []u8) !usize {
        if (output.ptr != @as([*]u8, @ptrCast(self.bounce))) return error.CachedDmaBuffer;
        @memcpy(output, self.bytes[self.at..][0..output.len]);
        self.at += output.len;
        return output.len;
    }

    pub fn write(self: *Memory, bytes: []const u8) !void {
        if (bytes.ptr != @as([*]const u8, @ptrCast(self.bounce))) return error.CachedDmaBuffer;
        @memcpy(self.bytes[self.at..][0..bytes.len], bytes);
        self.at += bytes.len;
    }

    pub fn sync(_: *Memory) !void {}
};
const Work = struct {
    bounce: *[512]u8,
    polls: usize = 0,
    cancel_after: usize = std.math.maxInt(usize),

    fn poll(context: *anyopaque) bool {
        const self: *Work = @ptrCast(@alignCast(context));
        @memset(self.bounce, 0xdd);
        self.polls += 1;
        return self.polls >= self.cancel_after;
    }
};
const Service = struct { context: *anyopaque, poll: *const fn (*anyopaque) bool };
const Validator = struct {
    pub fn valid(_: @This(), payload: []const u8, _: u64) bool {
        return payload.len == 2048 and (payload[0] == 17 or payload[0] == 21);
    }
};

test "cooperative sector I/O tolerates bounce clobber and cancellation retains the committed journal" {
    const allocator = std.testing.allocator;
    const card = try allocator.alloc(u8, TestJournal.allocation_bytes);
    defer allocator.free(card);
    @memset(card, 0);
    var block: [512]u8 = undefined;
    var old: [2048]u8 = @splat(17);
    var replacement: [2048]u8 = @splat(21);
    var scratch: [2048]u8 = undefined;
    var raw = Memory{ .bytes = card, .bounce = &block };
    var work = Work{ .bounce = &block };
    const service: ?Service = .{ .context = &work, .poll = Work.poll };
    var cancelled = false;
    var cursor = wrap(&raw, service, &cancelled);
    var journal = TestJournal{};
    try journal.save(&cursor, 7, &old, &block);
    try std.testing.expectEqual(5, work.polls); // Four data sectors and one header.
    var reader = TestJournal{};
    const loaded = (try reader.load(&cursor, 7, &scratch, &block, Validator{})).?;
    try std.testing.expectEqualSlices(u8, &old, loaded);
    const baseline = try allocator.dupe(u8, card);
    defer allocator.free(baseline);
    for (1..5) |stop| {
        @memcpy(card, baseline);
        work = .{ .bounce = &block, .cancel_after = stop };
        cancelled = false;
        var interrupted = journal;
        try std.testing.expectError(error.Cancelled, interrupted.save(&cursor, 7, &replacement, &block));
        try std.testing.expect(cancelled);
        try std.testing.expectEqualDeep(journal, interrupted);
        work = .{ .bounce = &block };
        cancelled = false;
        reader = .{};
        try std.testing.expectEqualSlices(u8, &old, (try reader.load(&cursor, 7, &scratch, &block, Validator{})).?);
    }
    work = .{ .bounce = &block, .cancel_after = 1 };
    cancelled = false;
    reader = .{};
    try std.testing.expectError(error.Cancelled, reader.load(&cursor, 7, &scratch, &block, Validator{}));
    try std.testing.expect(cancelled);
}
