pub const maximum_buffers = 4;

pub const Config = struct {
    buffer_count: u8,
    descriptor_count: u8,
    total_chunks: u32,

    pub fn valid(self: Config) bool {
        return self.buffer_count >= 2 and
            self.buffer_count <= maximum_buffers and
            self.descriptor_count >= self.buffer_count and
            self.descriptor_count <= 128 and
            self.total_chunks >= self.buffer_count and
            (self.total_chunks <= self.descriptor_count or
                self.descriptor_count % self.buffer_count == 0);
    }
};

test "long streams require descriptor and buffer rings to realign at wrap" {
    const testing = @import("std").testing;
    try testing.expect((Config{
        .buffer_count = 3,
        .descriptor_count = 120,
        .total_chunks = 240,
    }).valid());
    try testing.expect(!(Config{
        .buffer_count = 3,
        .descriptor_count = 128,
        .total_chunks = 240,
    }).valid());
    try testing.expect((Config{
        .buffer_count = 3,
        .descriptor_count = 5,
        .total_chunks = 5,
    }).valid());
}

pub const SlotState = enum {
    free,
    filling,
    ready,
    dma_owned,
};

pub const Slot = struct {
    state: SlotState = .free,
    chunk: u32 = 0,
};

pub const Refill = struct {
    slot: u8,
    chunk: u32,
};

pub const Advance = struct {
    refill: ?Refill,
    finished: bool,
};

pub const Error = error{
    InvalidConfig,
    AlreadyFinished,
    UnexpectedDescriptor,
    BufferNotReady,
    InvalidRefill,
};

/// Owns buffer lifecycle and descriptor order for a linked-DMA playback stream.
/// Hardware and simulation both drive this state with the same descriptor and
/// refill completion events.
pub const State = struct {
    config: Config,
    slots: [maximum_buffers]Slot = @splat(.{}),
    chunks_completed: u32 = 0,
    next_chunk_to_load: u32 = 0,
    finished: bool = false,

    pub fn init(config: Config) Error!State {
        if (!config.valid()) return error.InvalidConfig;

        var self = State{ .config = config };
        for (0..config.buffer_count) |slot_index| {
            self.slots[slot_index] = .{
                .state = if (slot_index == 0) .dma_owned else .ready,
                .chunk = @intCast(slot_index),
            };
        }
        self.next_chunk_to_load = config.buffer_count;
        return self;
    }

    pub fn currentChunk(self: State) ?u32 {
        if (self.finished) return null;
        return self.chunks_completed;
    }

    pub fn expectedDescriptor(self: State) u7 {
        return @intCast(self.chunks_completed % self.config.descriptor_count);
    }

    pub fn slot(self: State, index: u8) Slot {
        return self.slots[index];
    }

    /// Records that DMA completed the current chunk and linked to the observed
    /// descriptor. A refill request identifies the released buffer and the
    /// next chunk that must be loaded into it.
    pub fn advance(self: *State, observed_descriptor: u7) Error!Advance {
        if (self.finished) return error.AlreadyFinished;

        const completed_chunk = self.chunks_completed;
        const next_completed_count = completed_chunk + 1;
        const expected_descriptor: u7 = @intCast(next_completed_count % self.config.descriptor_count);
        if (observed_descriptor != expected_descriptor) return error.UnexpectedDescriptor;

        const released_slot: u8 = @intCast(completed_chunk % self.config.buffer_count);
        if (self.slots[released_slot].state != .dma_owned or
            self.slots[released_slot].chunk != completed_chunk)
        {
            return error.BufferNotReady;
        }

        if (next_completed_count < self.config.total_chunks) {
            const next_slot: u8 = @intCast(next_completed_count % self.config.buffer_count);
            if (self.slots[next_slot].state != .ready or
                self.slots[next_slot].chunk != next_completed_count)
            {
                return error.BufferNotReady;
            }
        }

        self.chunks_completed = next_completed_count;
        self.slots[released_slot].state = .free;

        var refill: ?Refill = null;
        if (self.next_chunk_to_load < self.config.total_chunks) {
            refill = .{
                .slot = released_slot,
                .chunk = self.next_chunk_to_load,
            };
            self.slots[released_slot] = .{
                .state = .filling,
                .chunk = self.next_chunk_to_load,
            };
            self.next_chunk_to_load += 1;
        }

        if (next_completed_count == self.config.total_chunks) {
            self.finished = true;
            return .{ .refill = refill, .finished = true };
        }

        const next_slot: u8 = @intCast(next_completed_count % self.config.buffer_count);
        self.slots[next_slot].state = .dma_owned;
        return .{ .refill = refill, .finished = false };
    }

    pub fn completeRefill(self: *State, refill: Refill) Error!void {
        if (refill.slot >= self.config.buffer_count) return error.InvalidRefill;
        var target = &self.slots[refill.slot];
        if (target.state != .filling or target.chunk != refill.chunk) {
            return error.InvalidRefill;
        }
        target.state = .ready;
    }
};
