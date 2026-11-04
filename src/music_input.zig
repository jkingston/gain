//! Physical samples enter the same navigation policy as simulator button edges.
const std = @import("std");
const capture = @import("input_capture.zig");
const media = @import("f20_media.zig");

pub const Stream = struct {
    queue: capture.Queue,
    decoder: capture.Decoder,

    pub fn init(sample: capture.Sample, settle_ticks: u32) Stream {
        return .{ .queue = .init(sample), .decoder = .init(sample, settle_ticks, 4) };
    }

    pub fn observe(self: *Stream, sample: capture.Sample) void {
        if (sample.buttons != self.queue.latest.buttons or sample.wheel != self.queue.latest.wheel) self.queue.push(sample);
    }

    pub fn reset(self: *Stream, sample: capture.Sample) void {
        self.queue = .init(sample);
        self.decoder.reset(sample);
    }

    pub fn dispatch(self: *Stream, controller: anytype, at: u32, now_ms: u64, ticks_per_ms: u32, playing: bool) media.PlaybackCommand {
        // Drain releases before considering a repeat. An entire gesture may
        // have been captured while the display was painting another frame.
        for (0..capture.Queue.capacity) |_| {
            const event = self.decoder.next(&self.queue, at) orelse break;
            const event_ms = now_ms -| ((at -% event.at) / ticks_per_ms);
            const command = switch (event.action) {
                .button => |edge| controller.button(edge.button, edge.pressed, event_ms, playing),
                .wheel => |direction| controller.wheel(direction, event_ms, playing),
                .cancel => cancelled: {
                    // The decoder suppresses initially-held buttons until
                    // release. Their old policy state must also be withdrawn.
                    controller.cancelInput(0);
                    break :cancelled media.PlaybackCommand.none;
                },
            };
            if (std.meta.activeTag(command) != .none) return command;
        }
        if (self.queue.read != self.queue.write or self.decoder.pending_index < self.decoder.pending_count) return .none;
        return controller.repeat(now_ms, self.decoder.held(), playing);
    }
};
