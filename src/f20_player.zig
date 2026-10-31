//! F20 task wiring for the portable decoder, input ring, PCM reservoir and
//! fixed-period output. Only storage reads the card; only control uses I2C.
//! Output preempts both. Interrupt handlers only mask sources and notify owners.
const std = @import("std");
const port = @import("x1000_runtime.zig");
const x = @import("x1000.zig");
const audio = @import("f20_audio.zig");
const media = @import("f20_media.zig");
const decoder = @import("media_decoder.zig");
const output = @import("audio_output.zig");
const pcm = @import("pcm_reservoir.zig");
const storage = @import("f20_storage.zig");
const memory = @import("f20_memory.zig");
const info = @import("media_info.zig");
const playback = @import("playback.zig");
const input_stream = @import("input_stream.zig");
const codec_pool = @import("codec_pool.zig");
const stack = @import("task_stack.zig");
const stacks = [_]memory.Region{ memory.output_stack, memory.ui_stack, memory.control_stack, memory.codec_stack, memory.storage_stack };
const event = 1;
const timer_hz = x.Timer.milliseconds(1000);
const ui_ticks = timer_hz / 60;
const control_ticks = x.Timer.milliseconds(10);
const preroll_milliseconds = 100;
const decoder_batch_frames = 8192;
const startup_margin_periods = 4;
const dma_word_bytes = @sizeOf(u32);

pub const Config = struct {
    descriptor_count: u8 = 120,
    buffer_count: u8 = 3,
    attenuation: u8 = 64,
    measure_stacks: bool = false,

    pub fn valid(self: Config) bool {
        return (playback.Config{
            .descriptor_count = self.descriptor_count,
            .buffer_count = self.buffer_count,
            .total_chunks = std.math.maxInt(u32),
        }).valid();
    }
};

const Workspace = struct {
    decoder: decoder.Workspace,
    input: []u8,
    burst: []u8,
    pcm: []pcm.StereoFrame,

    pub fn device(pool: *codec_pool.Pool) Workspace {
        return .{
            .decoder = .{
                .packet = .{
                    .packet = memory.codec_packet.cachedSlice(u8),
                    .page = memory.codec_page.cachedSlice(u8),
                    .pcm = memory.codec_float_pcm.cachedSlice(f32),
                    .frames = memory.decoded_frames.cachedSlice(pcm.StereoFrame)[0..decoder_batch_frames],
                    .pool = pool,
                },
                .cache = memory.decoder_cache.cachedSlice(u8),
                .compressed = memory.flac_compressed.cachedSlice(u8),
                .left = memory.flac_left.cachedSlice(i32),
                .right = memory.flac_right.cachedSlice(i32),
            },
            .input = memory.stream_input.cachedSlice(u8),
            .burst = memory.storage_burst.uncachedSlice(u8),
            .pcm = memory.pcm_reservoir.cachedSlice(pcm.StereoFrame),
        };
    }
};
pub const Report = struct {
    playback: media.Result,
    runtime: port.Metrics,
    heap_peak: u32,
    periods: u32,
    storage_steps: u32,
    ui_polls: u32,
    worst_fill_ticks: u32,
    startup_ticks: u32,
    maximum_ui_ticks: u32,
    maximum_ui_gap_ticks: u32,
    stack_used: [stacks.len]u32,
};
fn Player(comptime Reader: type) type {
    return struct {
        const Self = @This();
        const Input = input_stream.Stream(Reader, Self);
        var active: ?*Self = null;
        runtime: port.Runtime = .{},
        reader: *Reader,
        length: u32,
        resources: audio.Engine.Resources,
        workspace: Workspace,
        config: Config,
        control: ?media.PlaybackControl,
        sd: ?*storage.Controller,
        input: Input = undefined,
        reservoir: pcm.Ring = undefined,
        information: info.Information = undefined,
        plan: output.Plan = undefined,
        engine: ?audio.Engine = null,
        state: ?playback.State = null,
        cancelled_flag: std.atomic.Value(bool) = .init(false),
        codec_done: std.atomic.Value(bool) = .init(false),
        header_ready: std.atomic.Value(bool) = .init(false),
        storage_idle: std.atomic.Value(bool) = .init(true),
        output_idle: std.atomic.Value(bool) = .init(true),
        error_code: std.atomic.Value(u32) = .init(0),
        requested_exit: std.atomic.Value(u32) = .init(0),
        requested_volume: std.atomic.Value(u32) = .init(0),
        prepare_requested: bool = false,
        prepared: bool = false,
        started: bool = false,
        drained: bool = false,
        end_bounded: bool = false,
        produced_frames: u64 = 0,
        periods: u32 = 0,
        storage_steps: u32 = 0,
        ui_polls: u32 = 0,
        worst_fill_ticks: u32 = 0,
        startup_ticks: u32 = 0,
        maximum_ui_ticks: u32 = 0,
        maximum_ui_gap_ticks: u32 = 0,
        previous_ui_tick: ?u32 = null,
        started_tick: u32 = 0,
        attenuation: u8 = 0,
        quantizer: @import("pcm.zig").Sample.Quantizer = .{},

        pub fn play(self: *Self) !Report {
            if (!self.config.valid()) return error.InvalidConfig;
            if (active != null or self.workspace.burst.len < storage.fat32.sector_bytes + dma_word_bytes - 1) return error.InvalidWorkspace;
            self.started_tick = x.Timer.now();
            for (stacks) |region| stack.prepare(region.cachedSlice(u8), self.config.measure_stacks);
            self.input = try Input.init(self.reader, self.length, self.workspace.input, self);
            self.reservoir = try pcm.Ring.init(self.workspace.pcm);
            self.attenuation = @min(128, @max(16, self.config.attenuation));
            active = self;
            defer active = null;
            const masks = x.Interrupts.masks();
            defer x.Interrupts.restore(masks);
            // Only this player's claimed peripherals may interrupt while
            // the executive owns the CPU; restore its caller's masks on exit.
            x.Interrupts.maskAll();
            if (self.sd) |controller| controller.waiter = .{ .context = self, .prepare = prepareSd, .wait = waitSd };
            defer if (self.sd) |controller| {
                controller.waiter = null;
            };
            self.runtime.hardware_interrupt = interrupt;
            self.runtime.run(.{
                .{ .entry = outputEntry, .stack_top = @intCast(memory.output_stack.cachedTop()), .stack_bottom = @intCast(memory.output_stack.cached() + stack.guard_bytes) },
                .{ .entry = uiEntry, .stack_top = @intCast(memory.ui_stack.cachedTop()), .stack_bottom = @intCast(memory.ui_stack.cached() + stack.guard_bytes) },
                .{ .entry = controlEntry, .stack_top = @intCast(memory.control_stack.cachedTop()), .stack_bottom = @intCast(memory.control_stack.cached() + stack.guard_bytes) },
                .{ .entry = codecEntry, .stack_top = @intCast(memory.codec_stack.cachedTop()), .stack_bottom = @intCast(memory.codec_stack.cached() + stack.guard_bytes) },
                .{ .entry = storageEntry, .stack_top = @intCast(memory.storage_stack.cachedTop()), .stack_bottom = @intCast(memory.storage_stack.cached() + stack.guard_bytes) },
            });
            var stack_used: [stacks.len]u32 = @splat(0);
            for (stacks, 0..) |region, index| {
                const bytes = region.cachedSlice(u8);
                if (!stack.intact(bytes)) return error.StackOverflow;
                if (self.config.measure_stacks) stack_used[index] = @intCast(stack.used(bytes));
            }
            if (self.workspace.decoder.packet.pool.statistics.live != 0) return error.DecoderLeak;
            const code = self.error_code.load(.acquire);
            if (code != 0) return @errorFromInt(@as(u16, @intCast(code)));
            return .{
                .playback = .{
                    .sample_rate = if (self.header_ready.load(.acquire)) self.information.sample_rate else 0,
                    .output_format = if (self.header_ready.load(.acquire)) self.information.output_format else .signed_24_in_u32,
                    .frames = self.produced_frames,
                    .chunks = if (self.state) |state| state.chunks_completed else 0,
                    .underruns = if (self.engine) |engine| engine.underrun_count else 0,
                    .minimum_fifo_level = if (self.engine) |engine| engine.minimum_fifo_level else 0,
                    .stopped = self.requested_exit.load(.acquire) != 0,
                    .exit = @fromBackingInt(@intCast(self.requested_exit.load(.acquire))),
                    .attenuation = self.attenuation,
                },
                .runtime = self.runtime.metrics,
                .heap_peak = self.workspace.decoder.packet.pool.statistics.peak,
                .periods = self.periods,
                .storage_steps = self.storage_steps,
                .ui_polls = self.ui_polls,
                .worst_fill_ticks = self.worst_fill_ticks,
                .startup_ticks = self.startup_ticks,
                .maximum_ui_ticks = self.maximum_ui_ticks,
                .maximum_ui_gap_ticks = self.maximum_ui_gap_ticks,
                .stack_used = stack_used,
            };
        }
        fn current() *Self {
            return active.?;
        }
        pub fn cancelled(self: *Self) bool {
            return self.cancelled_flag.load(.acquire);
        }
        pub fn wakeStorage(self: *Self) void {
            self.runtime.notify(.storage, event);
        }
        pub fn wakeInput(self: *Self) void {
            self.runtime.notify(.codec, event);
        }
        pub fn prepareInputWait(self: *Self) void {
            _ = self.runtime.take(event);
        }
        pub fn waitInput(self: *Self) void {
            self.runtime.wait(event, null);
        }
        fn fail(self: *Self, failure: anyerror) void {
            _ = self.error_code.cmpxchgStrong(0, @intFromError(failure), .acq_rel, .acquire);
            self.cancel();
        }
        fn cancel(self: *Self) void {
            self.cancelled_flag.store(true, .release);
            for ([_]port.Task{ .output, .codec, .storage, .control }) |task| self.runtime.notify(task, event);
        }
        pub fn configure(self: *Self, information: info.Information) !void {
            if (self.cancelled()) return error.Cancelled;
            if (self.header_ready.load(.acquire)) {
                if (information.sample_rate != self.information.sample_rate or information.channels != self.information.channels or information.output_format != self.information.output_format) return error.FormatChanged;
                return;
            }
            self.plan = try output.Plan.init(information.sample_rate, information.output_format);
            if (audio.sampleRate(information.sample_rate) == null) return error.UnsupportedSampleRate;
            // Keep enough PCM beyond one decoder callback to publish EOF while
            // at least four DMA periods still separate output from that boundary.
            if (self.reservoir.capacity() < decoder_batch_frames + startup_margin_periods * self.plan.frames) return error.InvalidWorkspace;
            self.information = information;
            self.header_ready.store(true, .release);
            self.runtime.notify(.output, event);
        }
        pub fn push(self: *Self, frames: []const pcm.StereoFrame) !void {
            var offset: usize = 0;
            while (offset < frames.len) {
                if (self.cancelled()) return error.Cancelled;
                const count = self.reservoir.write(frames[offset..]);
                self.produced_frames += count;
                offset += count;
                self.runtime.notify(.output, event);
                if (count == 0) {
                    _ = self.runtime.take(event);
                    if (self.reservoir.free() == 0 and !self.cancelled()) self.runtime.wait(event, null);
                }
            }
        }
        fn codecEntry() callconv(.c) noreturn {
            const self = current();
            _ = decoder.run(&self.input, self.length, Self, self, self.workspace.decoder, 0) catch |failure| {
                if (failure != error.Cancelled) self.fail(failure);
            };
            self.codec_done.store(true, .release);
            self.runtime.notify(.output, event);
            self.runtime.notify(.control, event);
            self.runtime.notify(.storage, event);
            self.runtime.retire();
        }
        fn storageEntry() callconv(.c) noreturn {
            const self = current();
            while (true) {
                _ = self.runtime.take(event);
                const burst_bytes = self.workspace.burst.len - dma_word_bytes;
                if (!self.cancelled() and !self.codec_done.load(.acquire) and self.input.producerReady(burst_bytes)) {
                    self.storage_idle.store(false, .release);
                    const alignment_offset = self.input.producer_position & (dma_word_bytes - 1);
                    _ = self.input.produce(self.workspace.burst[alignment_offset..][0..burst_bytes]) catch |failure| {
                        self.fail(failure);
                    };
                    self.storage_steps += 1;
                    self.storage_idle.store(true, .release);
                    self.runtime.notify(.control, event);
                    continue;
                }
                self.storage_idle.store(true, .release);
                self.runtime.wait(event, null);
            }
        }
        fn render(self: *Self, slot: u8) !void {
            const started = x.Timer.now();
            const bytes = @as([*]u8, @ptrFromInt(self.resources.buffers[slot].address))[0..self.plan.bytes];
            const result = if (self.information.source_bits > 24) try output.renderPeriodDithered(&self.reservoir, bytes, self.plan, output.unity_gain_q24, &self.quantizer) else try output.renderPeriod(&self.reservoir, bytes, self.plan, output.unity_gain_q24);
            if (result.underrun and !self.codec_done.load(.acquire)) return error.AudioUnderrun;
            self.worst_fill_ticks = @max(self.worst_fill_ticks, x.Timer.elapsed(started));
            self.periods += 1;
            self.runtime.notify(.codec, event);
        }
        fn boundEnd(self: *Self) !void {
            if (self.end_bounded or !self.codec_done.load(.acquire)) return;
            const data_chunks = std.math.divCeil(u64, self.produced_frames, self.plan.frames) catch return error.InvalidDuration;
            const total_chunks = data_chunks + self.config.buffer_count;
            if (total_chunks > std.math.maxInt(u32)) return error.InvalidDuration;
            // Three drained silence periods guarantee cyclic DMA/FIFO cannot
            // replay old samples while the control task performs orderly shutdown.
            try self.state.?.finishAfter(@intCast(total_chunks));
            self.end_bounded = true;
        }
        fn outputEntry() callconv(.c) noreturn {
            const self = current();
            while (true) {
                _ = self.runtime.take(event);
                if (self.cancelled()) {
                    x.Interrupts.mask(.pdma);
                    x.Interrupts.mask(.pdma_descriptor);
                    x.Interrupts.mask(.aic);
                    if (self.started) self.engine.?.haltDma();
                    self.output_idle.store(true, .release);
                    self.runtime.notify(.control, event);
                    self.runtime.retire();
                }
                if (!self.started) {
                    if (!self.header_ready.load(.acquire)) {
                        self.runtime.wait(event, null);
                        continue;
                    }
                    const eof = self.codec_done.load(.acquire);
                    if (eof and self.produced_frames == 0) {
                        self.fail(error.EmptyChunk);
                        continue;
                    }
                    const prime = @max(self.config.buffer_count * self.plan.frames, self.plan.sample_rate * preroll_milliseconds / 1000);
                    if (!eof and self.reservoir.available() < prime) {
                        self.runtime.wait(event, null);
                        continue;
                    }
                    if (!self.prepared) {
                        self.prepare_requested = true;
                        self.runtime.notify(.control, event);
                        self.runtime.wait(event, null);
                        continue;
                    }
                    self.output_idle.store(false, .release);
                    self.state = playback.State.init(.{ .buffer_count = self.config.buffer_count, .descriptor_count = self.config.descriptor_count, .total_chunks = std.math.maxInt(u32) }) catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                    self.boundEnd() catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                    var failed = false;
                    for (0..self.config.buffer_count) |slot| self.render(@intCast(slot)) catch |failure| {
                        self.fail(failure);
                        failed = true;
                        break;
                    };
                    if (failed) continue;
                    self.engine.?.start() catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                    self.started = true;
                    self.startup_ticks = x.Timer.elapsed(self.started_tick);
                }
                self.boundEnd() catch |failure| {
                    self.fail(failure);
                    continue;
                };
                const observed = self.engine.?.pollDma() catch |failure| {
                    self.fail(failure);
                    continue;
                };
                if (observed.underrun or observed.dma_fault) {
                    self.fail(if (observed.underrun) error.AudioUnderrun else error.AudioDmaFault);
                    continue;
                }
                if (observed.descriptor) |descriptor| {
                    const completions = self.state.?.completionsTo(descriptor) catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                    var failed = false;
                    for (0..completions) |_| {
                        const transition = self.state.?.advance(self.state.?.nextDescriptor()) catch |failure| {
                            self.fail(failure);
                            failed = true;
                            break;
                        };
                        if (transition.refill) |refill| {
                            self.render(refill.slot) catch |failure| {
                                self.fail(failure);
                                failed = true;
                                break;
                            };
                            self.state.?.completeRefill(refill) catch |failure| {
                                self.fail(failure);
                                failed = true;
                                break;
                            };
                        }
                    }
                    if (failed) continue;
                    if (self.state.?.finished) {
                        x.Interrupts.mask(.pdma);
                        x.Interrupts.mask(.pdma_descriptor);
                        x.Interrupts.mask(.aic);
                        self.engine.?.haltDma();
                        self.output_idle.store(true, .release);
                        self.drained = true;
                        self.runtime.notify(.control, event);
                        self.runtime.retire();
                    }
                }
                x.Interrupts.unmask(.pdma);
                x.Interrupts.unmask(.pdma_descriptor);
                x.Interrupts.unmask(.aic);
                // IRQs drive refills; a bounded fallback catches missing edges
                // before three cyclic buffers can overrun ownership.
                const period_ticks = self.plan.refillWatchdogTicks(timer_hz);
                self.runtime.wait(event, self.runtime.now() + period_ticks);
            }
        }
        fn controlEntry() callconv(.c) noreturn {
            const self = current();
            while (true) {
                _ = self.runtime.take(event);
                if (self.requested_exit.load(.acquire) != 0 and !self.cancelled()) self.cancel();
                if (self.drained and !self.cancelled()) self.cancel();
                if (self.cancelled()) {
                    if (self.output_idle.load(.acquire) and self.storage_idle.load(.acquire) and self.codec_done.load(.acquire)) {
                        if (self.engine) |*engine| {
                            if (self.drained and self.error_code.load(.acquire) == 0) engine.finish() catch |failure| {
                                _ = self.error_code.cmpxchgStrong(0, @intFromError(failure), .acq_rel, .acquire);
                            } else engine.stop();
                        }
                        self.runtime.stop();
                    }
                    self.runtime.wait(event, null);
                    continue;
                }
                if (self.prepare_requested and !self.prepared) {
                    self.engine = audio.Engine.init(self.resources, .{ .descriptor_count = self.config.descriptor_count, .buffer_count = self.config.buffer_count, .chunk_bytes = @intCast(self.plan.bytes), .sample_format = audio.sampleFormat(self.plan.format) }) catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                    self.engine.?.initialize(audio.sampleRate(self.information.sample_rate).?, self.attenuation) catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                    self.prepared = true;
                    self.runtime.notify(.output, event);
                }
                const volume = self.requested_volume.swap(0, .acq_rel);
                if (volume != 0) {
                    self.attenuation = @intCast(volume - 1);
                    if (self.started) self.engine.?.setHardwareVolume(self.attenuation) catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                }
                if (self.started) self.engine.?.pollControl() catch |failure| {
                    self.fail(failure);
                    continue;
                };
                self.runtime.wait(event, self.runtime.now() + control_ticks);
            }
        }
        fn uiEntry() callconv(.c) noreturn {
            const self = current();
            while (true) {
                if (self.control) |control| {
                    const ready = self.header_ready.load(.acquire);
                    const total = if (ready) self.information.total_frames orelse if (self.codec_done.load(.acquire)) self.produced_frames else 0 else 0;
                    const played = if (self.state) |state| @as(u64, state.chunks_completed) * self.plan.frames else 0;
                    const ui_started = x.Timer.now();
                    if (self.previous_ui_tick) |previous| self.maximum_ui_gap_ticks = @max(self.maximum_ui_gap_ticks, ui_started -% previous);
                    self.previous_ui_tick = ui_started;
                    const command = control.poll(control.context, .{ .phase = if (self.started) .playing else .preparing, .sample_rate = if (ready) self.information.sample_rate else 0, .output_format = if (ready) self.information.output_format else .signed_24_in_u32, .total_frames = total, .played_frames = if (total == 0) played else @min(total, played) });
                    self.maximum_ui_ticks = @max(self.maximum_ui_ticks, x.Timer.elapsed(ui_started));
                    self.ui_polls += 1;
                    switch (command) {
                        .none => {},
                        .set_attenuation => |value| self.requested_volume.store(@as(u32, @min(128, @max(16, value))) + 1, .release),
                        .stop, .next, .previous => {
                            const exit: media.PlaybackExit = switch (command) {
                                .stop => .stopped,
                                .next => .next,
                                .previous => .previous,
                                else => unreachable,
                            };
                            _ = self.requested_exit.cmpxchgStrong(0, @backingInt(exit), .acq_rel, .acquire);
                        },
                    }
                    if (std.meta.activeTag(command) != .none) self.runtime.notify(.control, event);
                }
                self.runtime.wait(event, self.runtime.now() + ui_ticks);
            }
        }
        fn interrupt(runtime: *port.Runtime) void {
            if (x.Interrupts.pending(.pdma_descriptor) or x.Interrupts.pending(.pdma) or x.Interrupts.pending(.aic)) {
                x.Interrupts.mask(.pdma);
                x.Interrupts.mask(.pdma_descriptor);
                x.Interrupts.mask(.aic);
                runtime.notifyFromInterrupt(.output, event);
            }
            if (x.Interrupts.pending(.msc0)) {
                x.Interrupts.mask(.msc0);
                runtime.notifyFromInterrupt(.storage, event);
            }
        }
        fn prepareSd(context: *anyopaque, wanted: u32) void {
            const self: *Self = @ptrCast(@alignCast(context));
            _ = self.runtime.take(event);
            x.Msc0.interrupt_mask.write(~wanted);
            x.Interrupts.unmask(.msc0);
        }
        fn waitSd(context: *anyopaque, remaining: u32) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.runtime.wait(event, self.runtime.now() + remaining);
        }
    };
}

/// The reader is exclusively owned until this returns. Cancellation unwinds
/// decoder allocations and outstanding card reads before task stacks are reused.
pub fn playFile(reader: anytype, length: u32, card: ?*storage.Controller, config: Config, control: ?media.PlaybackControl) !Report {
    var pool = try codec_pool.Pool.init(@alignCast(memory.decoder_arena.cachedSlice(u8)));
    var buffers: [audio.maximum_buffers]audio.Buffer = undefined;
    for (&buffers, 0..) |*buffer, index| buffer.* = .{ .address = memory.audio_buffers.uncached() + index * memory.audio_buffer_capacity };
    var player = Player(@TypeOf(reader.*)){
        .reader = reader,
        .length = length,
        .sd = card,
        .resources = .{ .descriptors = @ptrFromInt(memory.audio_descriptors.uncached()), .buffers = buffers },
        .workspace = .device(&pool),
        .config = config,
        .control = control,
    };
    return player.play();
}

test "playback admission rejects impossible buffer rings before tasks start" {
    try std.testing.expect((Config{}).valid());
    try std.testing.expect((Config{ .buffer_count = 4 }).valid());
    try std.testing.expect(!(Config{ .buffer_count = 0 }).valid());
    try std.testing.expect(!(Config{ .buffer_count = 5 }).valid());
    try std.testing.expect(!(Config{ .descriptor_count = 4 }).valid());
    try std.testing.expect(!(Config{ .descriptor_count = 129 }).valid());
}
