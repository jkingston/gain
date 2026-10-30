pub const Priority = enum { normal, urgent };

pub const Region = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn pixels(self: Region) u32 {
        return @as(u32, self.width) * self.height;
    }
};

pub const Chunk = struct {
    region: Region,
    first_pixel: u32,
    pixel_count: u16,
    starts_region: bool,
    completes_region: bool,
};

/// Allocation-free scheduler for incremental LCD transfers. Requests are
/// coalesced by priority; an urgent volume update runs before a queued progress
/// update. Re-requesting an active region queues one complete refresh so a
/// change made halfway through a transfer cannot leave mixed old/new pixels.
pub const Scheduler = struct {
    active: ?Region = null,
    active_priority: Priority = .normal,
    cursor: u32 = 0,
    pending_urgent: ?Region = null,
    pending_normal: ?Region = null,

    pub fn request(self: *Scheduler, region: Region, priority: Priority) void {
        if (region.pixels() == 0) return;
        if (priority == .urgent and self.active != null and self.active_priority == .normal) {
            self.pending_normal = self.active;
            self.active = null;
            self.cursor = 0;
        }
        switch (priority) {
            .urgent => self.pending_urgent = region,
            .normal => self.pending_normal = region,
        }
    }

    pub fn next(self: *Scheduler, maximum_pixels: u16) ?Chunk {
        if (maximum_pixels == 0) return null;
        if (self.active == null) {
            if (self.pending_urgent) |region| {
                self.active = region;
                self.active_priority = .urgent;
                self.pending_urgent = null;
            } else if (self.pending_normal) |region| {
                self.active = region;
                self.active_priority = .normal;
                self.pending_normal = null;
            } else return null;
            self.cursor = 0;
        }

        const region = self.active.?;
        const remaining = region.pixels() - self.cursor;
        const count: u16 = @intCast(@min(remaining, maximum_pixels));
        const chunk = Chunk{
            .region = region,
            .first_pixel = self.cursor,
            .pixel_count = count,
            .starts_region = self.cursor == 0,
            .completes_region = count == remaining,
        };
        self.cursor += count;
        if (chunk.completes_region) {
            self.active = null;
            self.cursor = 0;
        }
        return chunk;
    }

    /// Takes one complete dirty region for an asynchronous display backend.
    pub fn take(self: *Scheduler) ?Region {
        if (self.active == null) {
            if (self.pending_urgent) |region| {
                self.active = region;
                self.active_priority = .urgent;
                self.pending_urgent = null;
            } else if (self.pending_normal) |region| {
                self.active = region;
                self.active_priority = .normal;
                self.pending_normal = null;
            } else return null;
            self.cursor = 0;
        }
        const region = self.active.?;
        if (self.cursor != 0) return null;
        self.active = null;
        return region;
    }
};

test "transfer work is strictly bounded per audio poll" {
    const testing = @import("std").testing;
    var scheduler = Scheduler{};
    scheduler.request(.{ .x = 275, .y = 7, .width = 18, .height = 7 }, .urgent);

    var chunks: u8 = 0;
    var pixels: u32 = 0;
    while (scheduler.next(32)) |chunk| {
        try testing.expect(chunk.pixel_count <= 32);
        try testing.expectEqual(chunks == 0, chunk.starts_region);
        chunks += 1;
        pixels += chunk.pixel_count;
    }
    try testing.expectEqual(@as(u8, 4), chunks);
    try testing.expectEqual(@as(u32, 18 * 7), pixels);
}

test "urgent work precedes normal work and repeated changes are coalesced" {
    const testing = @import("std").testing;
    const progress = Region{ .x = 0, .y = 180, .width = 320, .height = 42 };
    const volume = Region{ .x = 275, .y = 7, .width = 18, .height = 7 };
    var scheduler = Scheduler{};
    scheduler.request(progress, .normal);
    scheduler.request(volume, .urgent);
    scheduler.request(volume, .urgent);

    const first = scheduler.next(32).?;
    try testing.expectEqual(volume, first.region);
    while (scheduler.next(32)) |_| {}
    try testing.expect(scheduler.active == null);
    try testing.expect(scheduler.pending_urgent == null);
    try testing.expect(scheduler.pending_normal == null);
}

test "urgent work preempts and restarts an active normal transfer" {
    const testing = @import("std").testing;
    const progress = Region{ .x = 0, .y = 180, .width = 320, .height = 42 };
    const volume = Region{ .x = 275, .y = 7, .width = 18, .height = 7 };
    var scheduler = Scheduler{};
    scheduler.request(progress, .normal);
    try testing.expectEqual(progress, scheduler.next(32).?.region);
    scheduler.request(volume, .urgent);

    const urgent = scheduler.next(32).?;
    try testing.expectEqual(volume, urgent.region);
    while (scheduler.active != null or scheduler.pending_urgent != null) {
        _ = scheduler.next(32).?;
    }
    const restarted = scheduler.next(32).?;
    try testing.expectEqual(progress, restarted.region);
    try testing.expect(restarted.starts_region);
}

test "change during an active transfer schedules one complete refresh" {
    const testing = @import("std").testing;
    const volume = Region{ .x = 275, .y = 7, .width = 18, .height = 7 };
    var scheduler = Scheduler{};
    scheduler.request(volume, .urgent);
    _ = scheduler.next(32).?;
    scheduler.request(volume, .urgent);
    scheduler.request(volume, .urgent);

    var starts: u8 = 1;
    while (scheduler.next(32)) |chunk| {
        starts += @intFromBool(chunk.starts_region);
    }
    try testing.expectEqual(@as(u8, 2), starts);
}

test "asynchronous backend takes urgent regions as complete jobs" {
    const testing = @import("std").testing;
    const progress = Region{ .x = 0, .y = 180, .width = 320, .height = 42 };
    const volume = Region{ .x = 275, .y = 7, .width = 18, .height = 7 };
    var scheduler = Scheduler{};
    scheduler.request(progress, .normal);
    scheduler.request(volume, .urgent);
    try testing.expectEqual(volume, scheduler.take().?);
    try testing.expectEqual(progress, scheduler.take().?);
    try testing.expect(scheduler.take() == null);
}
