//! Portable ownership contract. EOF alone never releases a transfer surface.
const std = @import("std");
pub const Region = @import("display_transfer.zig").Region;

pub const Phase = enum { idle, prepared, transferring, fetched, draining, failed };

pub const Action = enum { none, disable, release };

pub const Observation = struct { eof: bool = false, bus_busy: bool = false, disable_done: bool = false, fault: bool = false };
pub const Error = error{ Owned, NotPrepared, InvalidRegion, InvalidSource, TimedOut, DeviceFault };

pub const State = struct {
    phase: Phase = .idle,
    generation: u32 = 0,
    started: u32 = 0,

    pub fn prepare(self: *State) Error!void {
        if (self.phase != .idle) return error.Owned;
        self.phase = .prepared;
        self.generation +%= 1;
    }

    pub fn commit(self: *State, now: u32) Error!void {
        if (self.phase != .prepared) return error.NotPrepared;
        self.started = now;
        self.phase = .transferring;
    }

    /// Only an uncommitted transfer may be cancelled without a hardware ACK.
    pub fn cancel(self: *State) Error!void {
        if (self.phase != .prepared) return error.NotPrepared;
        self.phase = .idle;
    }

    pub fn observe(self: *State, now: u32, timeout: u32, event: Observation) Error!Action {
        if (self.phase == .idle or self.phase == .prepared) return .none;
        if (self.phase == .failed) return error.DeviceFault;
        if (event.fault) {
            self.phase = .failed;
            return error.DeviceFault;
        }
        if (self.phase == .transferring and event.eof) self.phase = .fetched;
        if (self.phase == .fetched and !event.bus_busy) {
            self.phase = .draining;
            // Completion may have happened while the caller was decoding.
            // Start a fresh ACK timeout only when disable is actually issued.
            self.started = now;
            return .disable;
        }
        if (self.phase == .draining and event.disable_done and !event.bus_busy) {
            self.phase = .idle;
            return .release;
        }
        if (now -% self.started >= timeout) {
            self.phase = .failed; // Retain the source until explicit device reset.
            return error.TimedOut;
        }
        return .none;
    }

    pub fn owned(self: State) bool {
        return self.phase != .idle;
    }

    /// Caller must have reset/quiesced the device before reclaiming its source.
    pub fn afterDeviceReset(self: *State) void {
        self.phase = .idle;
    }
};

pub fn alignedRegion(region: Region, width: u16, height: u16) Error!Region {
    if (region.width == 0 or region.height == 0 or @as(u32, region.x) + region.width > width or @as(u32, region.y) + region.height > height) return error.InvalidRegion;
    var result = region;
    if (result.width & 1 != 0) {
        if (result.x + result.width < width) result.width += 1 else if (result.x > 0) {
            result.x -= 1;
            result.width += 1;
        } else return error.InvalidRegion;
    }
    return result;
}

/// Freeze a strided canvas into a caller-owned packed DMA surface. Validation
/// precedes every write, so bad geometry cannot partly overwrite a live buffer.
pub fn pack(canvas: []const u16, width: u16, height: u16, region: Region, destination: []u16) Error!void {
    if (canvas.len != @as(usize, width) * height or destination.len < region.pixels()) return error.InvalidSource;
    _ = try alignedRegion(region, width, height);
    if (region.x == 0 and region.width == width) {
        copyPixels(destination[0..region.pixels()], canvas[@as(usize, region.y) * width ..][0..region.pixels()]);
        return;
    }
    for (0..region.height) |row| {
        const start = (@as(usize, region.y) + row) * width + region.x;
        const output = destination[row * region.width ..][0..region.width];
        copyPixels(output, canvas[start..][0..region.width]);
    }
}

fn copyPixels(destination: []u16, source: []const u16) void {
    if (@intFromPtr(destination.ptr) & 3 == 0 and destination.len & 1 == 0) {
        // Explicit volatile word stores prevent LLVM turning an uncached copy
        // back into the much slower byte-store memcpy implementation on MIPS.
        const to: [*]volatile u32 = @ptrCast(@alignCast(destination.ptr));
        const count = destination.len / 2;
        if (@intFromPtr(source.ptr) & 3 == 0) {
            const from: [*]const u32 = @ptrCast(@alignCast(source.ptr));
            var at: usize = 0;
            while (at + 8 <= count) : (at += 8) inline for (0..8) |offset| {
                to[at + offset] = from[at + offset];
            };
            while (at < count) : (at += 1) to[at] = from[at];
        } else for (0..count) |i| to[i] = @bitCast([2]u16{ source[i * 2], source[i * 2 + 1] });
    } else @memcpy(destination, source);
}

test "all EOF FIFO drain and ACK schedules preserve ownership" {
    for (0..8) |eof| for (0..8) |drain| for (0..4) |ack_delay| {
        var state = State{};
        try state.prepare();
        try state.commit(0xfffffff0);
        var disabled: ?usize = null;
        var released = false;
        for (0..24) |tick| {
            const event = Observation{ .eof = tick >= eof, .bus_busy = tick < drain, .disable_done = if (disabled) |at| tick > at + ack_delay else false };
            switch (try state.observe(0xfffffff0 +% @as(u32, @intCast(tick)), 100, event)) {
                .none => {},
                .disable => {
                    try std.testing.expect(!event.bus_busy);
                    try std.testing.expect(disabled == null);
                    disabled = tick;
                },
                .release => {
                    try std.testing.expect(disabled != null and event.disable_done and !event.bus_busy);
                    released = true;
                },
            }
        }
        try std.testing.expect(released and !state.owned());
    };
}

test "prepared stale flags fault timeout and cancellation never expose a live source" {
    var state = State{};
    try state.prepare();
    try std.testing.expectEqual(Action.none, try state.observe(10, 100, .{ .eof = true, .disable_done = true }));
    try std.testing.expectError(error.Owned, state.prepare());
    try state.cancel();
    try state.prepare();
    try state.commit(100);
    try std.testing.expectError(error.NotPrepared, state.cancel());
    try std.testing.expectError(error.TimedOut, state.observe(200, 100, .{}));
    try std.testing.expect(state.owned());
    try std.testing.expectError(error.Owned, state.prepare());
    state.afterDeviceReset();
    try state.prepare();
    try state.commit(0);
    try std.testing.expectError(error.DeviceFault, state.observe(1, 100, .{ .fault = true }));
    try std.testing.expect(state.owned());
}

test "alignment expansion and immutable packed snapshots include edge damage" {
    var canvas: [320 * 4]u16 = undefined;
    for (&canvas, 0..) |*p, i| p.* = @intCast(i);
    var snapshot: [320 * 4 + 2]u16 = @splat(0xa55a);
    const region = try alignedRegion(.{ .x = 319, .y = 1, .width = 1, .height = 2 }, 320, 4);
    try std.testing.expectEqual(Region{ .x = 318, .y = 1, .width = 2, .height = 2 }, region);
    try pack(&canvas, 320, 4, region, snapshot[1..5]);
    @memset(&canvas, 0);
    try std.testing.expectEqualSlices(u16, &.{ 638, 639, 958, 959 }, snapshot[1..5]);
    try std.testing.expect(snapshot[0] == 0xa55a and snapshot[5] == 0xa55a);
    try std.testing.expectError(error.InvalidRegion, alignedRegion(.{ .x = 65535, .y = 0, .width = 2, .height = 1 }, 320, 240));
}

test "deterministic truncation matches four captured F20 panel images; corrected policy drains every pixel" {
    const Sample = struct { left: usize, width: usize, sent_at_eof: usize, sha256: []const u8 };
    const samples = [_]Sample{
        .{ .left = 0, .width = 320, .sent_at_eof = 6836, .sha256 = "1fb5476aa5e5ab34598cb190b9d62485bb134c54598f0356883cb39d24b9c2a9" },
        .{ .left = 20, .width = 44, .sent_at_eof = 410, .sha256 = "0bf905f0aa6435f07c3c22879db50c9850db98d5c7434fca82688ceb5112753f" },
        .{ .left = 0, .width = 316, .sent_at_eof = 6836, .sha256 = "3dd38ae12b75ae8895f8a5a0141fc03d3c7dc4fe574211864016960144583973" },
        .{ .left = 276, .width = 44, .sent_at_eof = 410, .sha256 = "e33c601f7f12578abed043b7a318e992e4b988baa145179b0db5601caee9be40" },
    };
    for (samples) |sample| {
        var panel: [320 * 240]u16 = undefined;
        for (&panel, 0..) |*pixel, index| pixel.* = base(index % 320, index / 320);
        for (0..sample.sent_at_eof) |offset| put(&panel, sample.left, sample.width, offset);
        // Old policy disables at EOF and loses the remaining queued suffix.
        var bytes: [320 * 240 * 2]u8 = undefined;
        for (panel, 0..) |pixel, index| std.mem.writeInt(u16, bytes[index * 2 ..][0..2], pixel, .little);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(&digest, .lower);
        try std.testing.expectEqualStrings(sample.sha256, &hex);

        var state = State{};
        try state.prepare();
        try state.commit(0);
        const count = sample.width * 24;
        var sent = sample.sent_at_eof;
        while (sent < count) : (sent += 1) {
            try std.testing.expectEqual(Action.none, try state.observe(1, 100, .{ .eof = true, .bus_busy = true, .disable_done = false }));
            put(&panel, sample.left, sample.width, sent);
        }
        try std.testing.expectEqual(Action.disable, try state.observe(1, 100, .{ .eof = true, .bus_busy = false, .disable_done = false }));
        try std.testing.expectEqual(Action.release, try state.observe(1, 100, .{ .eof = true, .bus_busy = false, .disable_done = true }));
        for (panel, 0..) |pixel, index| {
            const column = index % 320;
            const row = index / 320;
            const in_patch = column >= sample.left and column < sample.left + sample.width and row >= 108 and row < 132;
            const want = if (in_patch) patch(column, row, sample.left, sample.width) else base(column, row);
            try std.testing.expectEqual(want, pixel);
        }
    }
}

fn base(column: usize, row: usize) u16 {
    if (column == 0 or column == 319 or row == 0 or row == 239) return 0xffff;
    return if (column % 32 == 0 or row % 24 == 0) 0x001f else 0;
}

fn patch(column: usize, row: usize, left: usize, width: usize) u16 {
    if (row == 108) return 0xf800;
    if (row == 131) return 0x001f;
    if (column == left) return 0xffff;
    if (column == left + width - 1) return 0xffe0;
    return 0x07e0;
}

fn put(panel: *[320 * 240]u16, left: usize, width: usize, offset: usize) void {
    const column = left + offset % width;
    const row = 108 + offset / width;
    panel[row * 320 + column] = patch(column, row, left, width);
}

test "deterministic delayed FIFO reads keep the frozen generation through repeated volume changes" {
    const ui = @import("ui.zig");
    const view = @import("player_view.zig");
    const Scheduler = @import("display_transfer.zig").Scheduler;

    var canvas: [ui.pixel_count]u16 = undefined;
    var initial = ui.Ui.init(.{ .pixels = &canvas });
    try view.player(&initial, .{
        .name = "Track",
        .artist = "Artist",
    }, .{ .sample_rate = 192000, .total_frames = 192000 * 60, .played_frames = 0, .bits = 24 }, 4100, 64, ui.dark_theme);
    initial.finish();
    var fifo_source: [320 * 42]u16 = undefined;
    var expected: [320 * 42]u16 = undefined;
    var panel: [ui.pixel_count]u16 = canvas;
    var pending = Scheduler{};
    var state = State{};
    var region: ?Region = null;
    var fetched: usize = 0;
    var consumed: usize = 0;
    var disabled: ?u32 = null;
    var completed: u32 = 0;
    // Source fetch and physical panel writes run at different speeds. UI
    // events continue after EOF, including before the disable ACK arrives.
    for (0..60000) |step| {
        const now: u32 = 0xffff0000 +% @as(u32, @intCast(step));
        if (step < 10000 and step % 11 == 0) {
            var scene = ui.Ui.init(.{ .pixels = &canvas });
            try view.volume(&scene, @intCast(16 + (step / 11 % 29) * 4), ui.dark_theme);
            scene.finish();
            pending.request(view.volume_region, .urgent);
        }
        if (step < 10000 and step % 83 == 0) {
            var scene = ui.Ui.init(.{ .pixels = &canvas });
            try view.progress(&scene, .{
                .sample_rate = 192000,
                .total_frames = 192000 * 60,
                .played_frames = step * 1920,
                .bits = 24,
            }, ui.dark_theme);
            scene.finish();
            pending.request(view.progress_region, .normal);
        }
        if (!state.owned()) {
            if (pending.take()) |request| {
                region = try alignedRegion(request, 320, 240);
                try pack(&canvas, 320, 240, region.?, &fifo_source);
                @memcpy(expected[0..region.?.pixels()], fifo_source[0..region.?.pixels()]);
                try state.prepare();
                try state.commit(now);
                fetched = 0;
                consumed = 0;
                disabled = null;
            }
        }
        if (state.owned()) {
            const r = region.?;
            fetched = @min(r.pixels(), fetched + 19);
            if (consumed < fetched) {
                const end = @min(fetched, consumed + 7);
                for (consumed..end) |i| panel[(@as(usize, r.y) + i / r.width) * 320 + r.x + i % r.width] = fifo_source[i];
                consumed = end;
            }
            try std.testing.expectEqualSlices(u16, expected[0..r.pixels()], fifo_source[0..r.pixels()]);
            const action = try state.observe(now, 10000, .{
                .eof = fetched == r.pixels(),
                .bus_busy = consumed < r.pixels(),
                .disable_done = if (disabled) |at| now -% at >= 5 else false,
            });
            switch (action) {
                .none => {},
                .disable => {
                    try std.testing.expect(consumed == r.pixels());
                    disabled = now;
                },
                .release => {
                    for (0..r.pixels()) |i| try std.testing.expectEqual(expected[i], panel[(@as(usize, r.y) + i / r.width) * 320 + r.x + i % r.width]);
                    completed += 1;
                },
            }
        }
    }
    try std.testing.expect(completed > 10);
    try std.testing.expect(!state.owned());
    try std.testing.expect(pending.take() == null);
    try std.testing.expectEqualSlices(u16, &canvas, &panel);
}

test "invalid geometry and insufficient staging never change a destination" {
    const canvas: [320 * 240]u16 = @splat(0x1234);
    var buffer: [8]u16 = @splat(0xa55a);
    try std.testing.expectError(error.InvalidSource, pack(&canvas, 320, 240, .{ .x = 0, .y = 0, .width = 320, .height = 240 }, &buffer));
    try std.testing.expectError(error.InvalidRegion, pack(&canvas, 320, 240, .{ .x = 319, .y = 239, .width = 2, .height = 1 }, &buffer));
    for (buffer) |pixel| try std.testing.expectEqual(@as(u16, 0xa55a), pixel);
}

test "late cooperative observation accepts physical drain but gives disable its own ACK deadline" {
    var state = State{};
    try state.prepare();
    try state.commit(0);
    try std.testing.expectEqual(Action.disable, try state.observe(200, 100, .{ .eof = true, .bus_busy = false }));
    try std.testing.expect(state.owned());
    try std.testing.expectEqual(Action.none, try state.observe(201, 100, .{}));
    try std.testing.expectEqual(Action.release, try state.observe(202, 100, .{ .disable_done = true }));
    try state.prepare();
    try state.commit(300);
    try std.testing.expectError(error.TimedOut, state.observe(500, 100, .{ .eof = true, .bus_busy = true }));
    try std.testing.expect(state.owned());
}

test "bulk and strided snapshot copies match scalar pixels with alignment and edge canaries" {
    var random = std.Random.DefaultPrng.init(0x534e415053484f54);
    const rng = random.random();
    var source: [320 * 240 + 2]u16 align(32) = undefined;
    var destination: [320 * 240 + 2]u16 align(32) = undefined;
    for (&source) |*pixel| pixel.* = rng.int(u16);
    for (0..1000) |i| {
        const x: u16 = if (i % 4 == 0) 0 else rng.uintLessThan(u16, 320);
        const y = rng.uintLessThan(u16, 240);
        const w: u16 = if (i % 4 == 0) 320 else rng.intRangeAtMost(u16, 1, 320 - x);
        const h = rng.intRangeAtMost(u16, 1, 240 - y);
        const r = Region{ .x = x, .y = y, .width = w, .height = h };
        @memset(&destination, 0xa55a);
        const offset = i % 2;
        try pack(source[0 .. 320 * 240], 320, 240, r, destination[offset..][0..r.pixels()]);
        for (0..h) |row| for (0..w) |col| try std.testing.expectEqual(source[(@as(usize, y) + row) * 320 + x + col], destination[offset + row * w + col]);
        if (offset != 0) try std.testing.expectEqual(0xa55a, destination[0]);
        try std.testing.expectEqual(0xa55a, destination[offset + r.pixels()]);
    }
}
