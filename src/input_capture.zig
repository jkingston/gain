//! Timestamped physical input. The producer captures edges independently of
//! rendering; the consumer debounces and decodes them without allocation.
const std = @import("std");

pub const Button = enum(u3) {
    play,
    volume_up,
    volume_down,
    menu,
    previous,
    next,
    back,
    power,

    pub fn mask(self: Button) u8 {
        return @as(u8, 1) << @backingInt(self);
    }
};

pub const Sample = struct { at: u32, buttons: u8, wheel: u2 };
pub const Change = struct { button: Button, pressed: bool };
pub const Event = struct {
    at: u32,
    action: union(enum) { button: Change, wheel: i2, cancel },
};

/// Single producer/consumer. The board masks interrupts around consumer calls;
/// no partially read sample or overflow recovery may race the interrupt owner.
pub const Queue = struct {
    pub const capacity = 64;
    samples: [capacity]Sample = undefined,
    read: u32 = 0,
    write: u32 = 0,
    latest: Sample,
    overflowed: bool = false,
    dropped: u32 = 0,
    high_water: u32 = 0,

    pub fn init(sample: Sample) Queue {
        return .{ .latest = sample };
    }

    pub fn push(self: *Queue, sample: Sample) void {
        self.latest = sample;
        if (self.overflowed or self.write -% self.read == capacity) {
            self.overflowed = true;
            self.dropped +|= 1;
            return;
        }
        self.samples[self.write % capacity] = sample;
        self.write +%= 1;
        self.high_water = @max(self.high_water, self.write -% self.read);
    }

    fn pop(self: *Queue) ?Sample {
        if (self.read == self.write) return null;
        const sample = self.samples[self.read % capacity];
        self.read +%= 1;
        return sample;
    }
};

pub const Decoder = struct {
    settle_ticks: u32,
    transitions_per_detent: u3,
    raw: u8,
    stable: u8,
    suppressed: u8,
    changed_at: [8]u32,
    wheel: u2,
    wheel_fraction: i8 = 0,
    invalid_transitions: u32 = 0,
    pending: [9]Event = undefined,
    pending_count: usize = 0,
    pending_index: usize = 0,

    pub fn init(sample: Sample, settle_ticks: u32, transitions_per_detent: u3) Decoder {
        std.debug.assert(settle_ticks > 0 and settle_ticks < std.math.maxInt(i32));
        std.debug.assert(transitions_per_detent > 0 and transitions_per_detent <= 4);
        return .{
            .settle_ticks = settle_ticks,
            .transitions_per_detent = transitions_per_detent,
            .raw = sample.buttons,
            .stable = sample.buttons,
            .suppressed = sample.buttons,
            .changed_at = @splat(sample.at),
            .wheel = sample.wheel,
        };
    }

    fn append(self: *Decoder, event: Event) void {
        std.debug.assert(self.pending_count < self.pending.len);
        self.pending[self.pending_count] = event;
        self.pending_count += 1;
    }

    fn settle(self: *Decoder, at: u32) void {
        for (std.enums.values(Button)) |button| {
            const mask = button.mask();
            if ((self.raw ^ self.stable) & mask == 0 or at -% self.changed_at[@backingInt(button)] < self.settle_ticks) continue;
            const pressed = self.raw & mask != 0;
            self.stable = (self.stable & ~mask) | (self.raw & mask);
            const suppressed = self.suppressed & mask != 0;
            if (!pressed) self.suppressed &= ~mask;
            if (!suppressed) self.append(.{
                .at = self.changed_at[@backingInt(button)] +% self.settle_ticks,
                .action = .{ .button = .{ .button = button, .pressed = pressed } },
            });
        }
    }

    fn observe(self: *Decoder, sample: Sample) void {
        // Settle the previous level before applying the next edge. A complete
        // press/release during a long paint is retained with its original times.
        self.settle(sample.at);
        for (std.enums.values(Button)) |button| {
            if ((self.raw ^ sample.buttons) & button.mask() != 0) self.changed_at[@backingInt(button)] = sample.at;
        }
        self.raw = sample.buttons;
        const previous = self.wheel;
        self.wheel = sample.wheel;
        if (previous == sample.wheel) return;
        if (previous ^ sample.wheel == 3) {
            self.wheel_fraction = 0;
            self.invalid_transitions +|= 1;
            return;
        }
        // Gray-code phase order: 00 -> 10 -> 11 -> 01 -> 00 is forward.
        const phase = [_]i8{ 0, 3, 1, 2 };
        const difference = @mod(phase[sample.wheel] - phase[previous], 4);
        self.wheel_fraction += if (difference == 1) @as(i8, 1) else -1;
        const detent: i8 = self.transitions_per_detent;
        if (@abs(self.wheel_fraction) >= self.transitions_per_detent) {
            const direction: i2 = if (self.wheel_fraction > 0) 1 else -1;
            self.wheel_fraction -= @as(i8, direction) * detent;
            self.append(.{ .at = sample.at, .action = .{ .wheel = direction } });
        }
    }

    fn oldestFirst(self: *Decoder, now: u32) void {
        // Independent debounce deadlines can mature in a different order from
        // button IDs. Preserve chronological actions, including over OST wrap.
        // At most nine items: insertion avoids a general sorting engine in
        // the firmware and bounds the interrupt-masked consumer work to 36 moves.
        var i: usize = 1;
        while (i < self.pending_count) : (i += 1) {
            const item = self.pending[i];
            var at = i;
            while (at > 0 and now -% item.at > now -% self.pending[at - 1].at) : (at -= 1) self.pending[at] = self.pending[at - 1];
            self.pending[at] = item;
        }
    }

    pub fn reset(self: *Decoder, sample: Sample) void {
        const invalid = self.invalid_transitions;
        self.* = init(sample, self.settle_ticks, self.transitions_per_detent);
        self.invalid_transitions = invalid;
    }

    /// At most Queue.capacity samples are consumed in one call. Timestamps may
    /// wrap once between services; the board's OST service interval is shorter.
    pub fn next(self: *Decoder, queue: *Queue, now: u32) ?Event {
        if (queue.overflowed) {
            queue.read = queue.write;
            queue.overflowed = false;
            self.reset(queue.latest);
            return .{ .at = now, .action = .cancel };
        }
        if (self.pending_index < self.pending_count) {
            defer self.pending_index += 1;
            return self.pending[self.pending_index];
        }
        self.pending_count = 0;
        self.pending_index = 0;
        for (0..Queue.capacity) |_| {
            if (queue.pop()) |sample| self.observe(sample) else self.settle(now);
            if (self.pending_count != 0) {
                self.oldestFirst(now);
                self.pending_index = 1;
                return self.pending[0];
            }
            if (queue.read == queue.write) {
                self.settle(now);
                if (self.pending_count != 0) {
                    self.oldestFirst(now);
                    self.pending_index = 1;
                    return self.pending[0];
                }
                break;
            }
        }
        return null;
    }

    /// An observed release inhibits repeats immediately, before release debounce.
    pub fn held(self: *const Decoder) u8 {
        return self.raw & self.stable & ~self.suppressed;
    }
};

test "debounce uses elapsed time per button and retains simultaneous transitions" {
    var queue = Queue.init(.{ .at = 0, .buttons = 0, .wheel = 0 });
    var decoder = Decoder.init(queue.latest, 6, 4);
    queue.push(.{ .at = 10, .buttons = Button.next.mask(), .wheel = 0 });
    try std.testing.expect(decoder.next(&queue, 15) == null);
    // A volume bounce must not restart Next's independent debounce.
    queue.push(.{ .at = 15, .buttons = Button.next.mask() | Button.volume_up.mask(), .wheel = 0 });
    const next = decoder.next(&queue, 16).?;
    try std.testing.expectEqual(Button.next, next.action.button.button);
    try std.testing.expectEqual(16, next.at);
    const volume = decoder.next(&queue, 21).?;
    try std.testing.expectEqual(Button.volume_up, volume.action.button.button);
    try std.testing.expect(decoder.next(&queue, 21) == null);
    queue.push(.{ .at = 22, .buttons = 0, .wheel = 0 });
    try std.testing.expect(decoder.next(&queue, 22) == null);
    try std.testing.expectEqual(0, decoder.held());
    try std.testing.expect(!decoder.next(&queue, 28).?.action.button.pressed);
    try std.testing.expect(!decoder.next(&queue, 28).?.action.button.pressed);
}

test "a whole press and release between paints survives edge capture" {
    var queue = Queue.init(.{ .at = 0, .buttons = 0, .wheel = 0 });
    var decoder = Decoder.init(queue.latest, 6, 4);
    queue.push(.{ .at = 100, .buttons = Button.play.mask(), .wheel = 0 });
    queue.push(.{ .at = 180, .buttons = 0, .wheel = 0 });
    const press = decoder.next(&queue, 400).?;
    const release = decoder.next(&queue, 400).?;
    try std.testing.expect(press.action.button.pressed);
    try std.testing.expectEqual(106, press.at);
    try std.testing.expect(!release.action.button.pressed);
    try std.testing.expectEqual(186, release.at);
    try std.testing.expect(decoder.next(&queue, 400) == null);
}

test "wheel bounce cancels, invalid phase jumps rebase, and timestamps wrap" {
    var queue = Queue.init(.{ .at = 0xfffffff0, .buttons = 0, .wheel = 0 });
    var decoder = Decoder.init(queue.latest, 6, 4);
    for ([_]u2{ 2, 0, 2, 3, 1, 0 }) |wheel| queue.push(.{ .at = 2, .buttons = 0, .wheel = wheel });
    try std.testing.expectEqual(@as(i2, 1), decoder.next(&queue, 2).?.action.wheel);
    try std.testing.expect(decoder.next(&queue, 2) == null);
    queue.push(.{ .at = 4, .buttons = Button.back.mask(), .wheel = 3 });
    const press = decoder.next(&queue, 10).?;
    try std.testing.expectEqual(Button.back, press.action.button.button);
    try std.testing.expectEqual(1, decoder.invalid_transitions);
    decoder.reset(.{ .at = 0xfffffffd, .buttons = 0, .wheel = 0 });
    queue.push(.{ .at = 0xfffffffe, .buttons = Button.next.mask(), .wheel = 0 });
    try std.testing.expectEqual(4, decoder.next(&queue, 5).?.at);
}

test "overflow cancels stale actions and requires held controls to be released" {
    var queue = Queue.init(.{ .at = 0, .buttons = 0, .wheel = 0 });
    var decoder = Decoder.init(queue.latest, 6, 4);
    for (0..Queue.capacity + 4) |i| queue.push(.{ .at = @intCast(i), .buttons = Button.next.mask(), .wheel = 0 });
    try std.testing.expectEqual(4, queue.dropped);
    try std.testing.expectEqual(.cancel, std.meta.activeTag(decoder.next(&queue, 100).?.action));
    try std.testing.expect(decoder.next(&queue, 110) == null);
    try std.testing.expectEqual(0, decoder.held());
    queue.push(.{ .at = 120, .buttons = 0, .wheel = 0 });
    try std.testing.expect(decoder.next(&queue, 130) == null);
    queue.push(.{ .at = 140, .buttons = Button.next.mask(), .wheel = 0 });
    try std.testing.expect(decoder.next(&queue, 150).?.action.button.pressed);
}

test "queue sequence counters wrap without losing captured samples" {
    var queue = Queue.init(.{ .at = 0, .buttons = 0, .wheel = 0 });
    queue.read = std.math.maxInt(u32) - 1;
    queue.write = queue.read;
    for (0..5) |i| queue.push(.{ .at = @intCast(i), .buttons = 0, .wheel = 0 });
    for (0..5) |i| try std.testing.expectEqual(i, queue.pop().?.at);
    try std.testing.expect(queue.pop() == null);
}

test "independent button deadlines are delivered chronologically over clock wrap" {
    var queue = Queue.init(.{ .at = 0xfffffff0, .buttons = 0, .wheel = 0 });
    var decoder = Decoder.init(queue.latest, 6, 4);
    queue.push(.{ .at = 0xfffffffc, .buttons = Button.next.mask(), .wheel = 0 });
    queue.push(.{ .at = 0xfffffffe, .buttons = Button.next.mask() | Button.play.mask(), .wheel = 0 });
    const first = decoder.next(&queue, 10).?;
    const second = decoder.next(&queue, 10).?;
    try std.testing.expectEqual(Button.next, first.action.button.button);
    try std.testing.expectEqual(Button.play, second.action.button.button);
    try std.testing.expectEqual(2, first.at);
    try std.testing.expectEqual(4, second.at);
}

const EventObserver = struct {
    held: u8 = 0,

    fn consume(self: *EventObserver, event: Event) !void {
        switch (event.action) {
            .cancel => self.held = 0,
            .wheel => |direction| try std.testing.expect(direction == -1 or direction == 1),
            .button => |change| {
                const mask = change.button.mask();
                // A delivered edge must change the consumer's physical state:
                // no duplicate presses or orphan releases, even after overflow.
                try std.testing.expect((self.held & mask != 0) != change.pressed);
                if (change.pressed) self.held |= mask else self.held &= ~mask;
            },
        }
    }
};

fn fuzzCapture(_: void, smith: *std.testing.Smith) !void {
    var buffer: [1536]u8 = undefined;
    const bytes = buffer[0..smith.slice(&buffer)];
    var queue = Queue.init(.{ .at = 0xffffff00, .buttons = 0, .wheel = 0 });
    var decoder = Decoder.init(queue.latest, 6, 4);
    var observer = EventObserver{};
    var at = queue.latest.at;
    var i: usize = 0;
    while (i + 2 < @min(bytes.len, 1536)) : (i += 3) {
        at +%= bytes[i];
        queue.push(.{ .at = at, .buttons = bytes[i + 1], .wheel = @truncate(bytes[i + 2]) });
        if (bytes[i + 2] & 4 != 0) {
            for (0..1024) |_| {
                const event = decoder.next(&queue, at) orelse break;
                try observer.consume(event);
            }
        }
    }
    at +%= 200;
    queue.push(.{ .at = at, .buttons = 0, .wheel = queue.latest.wheel });
    for (0..1024) |_| {
        const event = decoder.next(&queue, at +% 6) orelse break;
        try observer.consume(event);
    }
    try std.testing.expectEqual(0, observer.held);
    try std.testing.expectEqual(0, decoder.held());
    try std.testing.expect(decoder.next(&queue, at +% 100) == null);
}

test "captured edge streams recover without duplicate or stuck buttons" {
    try std.testing.fuzz({}, fuzzCapture, .{ .corpus = &.{ &.{ 0, 255, 0, 0, 0, 4 }, &.{ 255, 1, 2, 255, 0, 4 }, &.{ 1, 1, 2, 1, 3, 3, 1, 0, 4 } } });
}
