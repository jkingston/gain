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
const transport = @import("transport.zig");
const stack = @import("task_stack.zig");
const stream = @import("stream_sequence.zig");

const stacks = [_]memory.Region{ memory.output_stack, memory.ui_stack, memory.control_stack, memory.codec_stack, memory.storage_stack };
const event = 1;
const timer_hz = x.Timer.milliseconds(1000);
const ui_ticks = timer_hz / 1000;
const control_ticks = x.Timer.milliseconds(10);
const preroll_milliseconds = 100;
const decoder_batch_frames = 8192;
const startup_margin_periods = 4;
const dma_word_bytes = @sizeOf(u32);

pub const StorageService = struct {
    context: *anyopaque,
    // Called only between complete filesystem operations, on the storage task.
    poll: *const fn (*anyopaque) bool,
};

/// Native sequence callbacks preserve one storage owner and keep catalogue
/// strings out of the audio pipeline. Opening may look ahead; audible adoption
/// follows completed DMA, so it must not mutate the queue cursor prematurely.
pub const Sequence = struct {
    context: *anyopaque,
    first: stream.Track,
    open_next: *const fn (*anyopaque, *anyopaque, stream.Track) anyerror!?stream.Track,
    audible: *const fn (*anyopaque, stream.Track) void,
};

pub const SequenceTrack = stream.Track;

pub const Config = struct {
    sequence: ?Sequence = null,
    seek_index: ?*@import("audio_seek.zig").Index = null,
    seek_cache: ?*decoder.SeekCache = null,
    source_identity: u64 = 0,
    start_frame: u64 = 0,
    initially_paused: bool = false,
    force_output_24: bool = false,
    gain_q24: u32 = output.unity_gain_q24,
    descriptor_count: u8 = 120,
    buffer_count: u8 = 3,
    attenuation: u8 = 64,
    measure_stacks: bool = false,
    report_out: ?*Report = null,
    // Runs only in the control task, which exclusively owns I2C.
    background: ?struct { context: *anyopaque, poll: *const fn (*anyopaque) void } = null,

    storage_work: ?struct { context: *anyopaque, run: *const fn (*anyopaque, StorageService) void } = null,
    // Control owns routing and DAC I2C. UI receives the settled/muted state
    // through this callback and may request a coalesced pop-suppressed change.
    routing: ?struct { context: *anyopaque, poll: *const fn (*anyopaque, audio.Output) ?audio.Output } = null,

    pub fn valid(self: Config) bool {
        return self.gain_q24 <= output.maximum_gain_q24 and (self.sequence == null or self.sequence.?.first.valid()) and (playback.Config{
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
    played_frames: u64 = 0,
    deferred: ?stream.Track = null,
    sequence_tracks: u32 = 0,
    seek_clamped: bool = false,
    final_status: ?media.PlaybackStatus = null,

    pub fn empty() Report {
        return .{
            .playback = .{ .sample_rate = 0, .output_format = .signed_24_in_u32, .frames = 0, .chunks = 0, .underruns = 0, .minimum_fifo_level = 0 },
            .runtime = .{},
            .heap_peak = 0,
            .periods = 0,
            .storage_steps = 0,
            .ui_polls = 0,
            .worst_fill_ticks = 0,
            .startup_ticks = 0,
            .maximum_ui_ticks = 0,
            .maximum_ui_gap_ticks = 0,
            .stack_used = @splat(0),
        };
    }
};

fn Player(comptime Reader: type) type {
    return struct {
        const Self = @This();
        const Input = input_stream.Stream(Reader, Self);
        const ReaderControl = if (@hasField(Reader, "seek_control")) @TypeOf(@as(Reader, undefined).seek_control) else ?struct {
            context: *anyopaque,
            cancelled: *const fn (*anyopaque) bool,
        };
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
        timeline: transport.Timeline = .{},
        paused: std.atomic.Value(bool) = .init(false),
        requested_seek: u64 = 0,
        current_track: stream.Track = .{},
        deferred_track: ?stream.Track = null,
        track_configured: bool = false,
        source_switch: stream.SourceSwitch = .{},
        previous_reader_control: ReaderControl = null,
        markers: stream.Markers = .{},
        stream_renderer: stream.Renderer = .{},
        audible: stream.Audible = .{},
        sequence_tracks: u32 = 0,
        end_seek: stream.EndSeek = .{},

        pub fn play(self: *Self) !Report {
            if (!self.config.valid()) return error.InvalidConfig;
            if (self.config.sequence) |sequence| if (sequence.first.length != self.length) return error.InvalidSequenceTrack;
            if (active != null or self.workspace.burst.len < storage.fat32.sector_bytes + dma_word_bytes - 1) return error.InvalidWorkspace;
            self.started_tick = x.Timer.now();
            const health = &@import("health.zig").snapshot;
            health.stream_tracks = 0;
            health.stream_handoffs = 0;
            health.stream_deferred = 0;
            self.current_track = if (self.config.sequence) |sequence| sequence.first else .{ .length = self.length, .gain_q24 = self.config.gain_q24, .source_identity = self.config.source_identity };
            self.paused.store(self.config.initially_paused, .release);
            for (stacks) |region| stack.prepare(region.cachedSlice(u8), self.config.measure_stacks);
            defer if (self.config.report_out) |out| {
                out.* = self.snapshot();
            };
            // Input.init starts its logical window at zero. Establish the raw
            // reader at the same position before storage/codec owners split.
            try self.reader.seekTo(0);
            self.installReaderControl();
            defer if (@hasField(Reader, "seek_control")) {
                self.reader.seek_control = self.previous_reader_control;
            };
            self.input = try Input.init(self.reader, self.length, self.workspace.input, self);
            self.reservoir = try pcm.Ring.init(self.workspace.pcm);
            self.attenuation = @import("volume_control.zig").clamp(self.config.attenuation);
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
            self.runtime.deadline_at = @import("f20_display.zig").pendingDeadline;
            self.runtime.deadline_interrupt = @import("f20_display.zig").launchFromInterrupt;
            @import("f20_display.zig").useInterruptLaunch(true);
            defer @import("f20_display.zig").useInterruptLaunch(false);
            self.runtime.run(.{
                .{
                    .entry = outputEntry,
                    .stack_top = @intCast(memory.output_stack.cachedTop()),
                    .stack_bottom = @intCast(memory.output_stack.cached() + stack.guard_bytes),
                },
                .{
                    .entry = uiEntry,
                    .stack_top = @intCast(memory.ui_stack.cachedTop()),
                    .stack_bottom = @intCast(memory.ui_stack.cached() + stack.guard_bytes),
                },
                .{
                    .entry = controlEntry,
                    .stack_top = @intCast(memory.control_stack.cachedTop()),
                    .stack_bottom = @intCast(memory.control_stack.cached() + stack.guard_bytes),
                },
                .{
                    .entry = codecEntry,
                    .stack_top = @intCast(memory.codec_stack.cachedTop()),
                    .stack_bottom = @intCast(memory.codec_stack.cached() + stack.guard_bytes),
                },
                .{
                    .entry = storageEntry,
                    .stack_top = @intCast(memory.storage_stack.cachedTop()),
                    .stack_bottom = @intCast(memory.storage_stack.cached() + stack.guard_bytes),
                },
            });
            var stack_used: [stacks.len]u32 = @splat(0);
            for (stacks, 0..) |region, index| {
                const bytes = region.cachedSlice(u8);
                if (!stack.intact(bytes)) return error.StackOverflow;
                if (self.config.measure_stacks) stack_used[index] = @intCast(stack.used(bytes));
            }
            // Runtime stop joins all task stacks. A long final UI render must
            // not leave its last completed track boundary unadopted before
            // main applies EOF/Next to the queue. No scheduler traps run here.
            self.publishAudible(self.timeline.played.load(), false);
            if (self.workspace.decoder.packet.pool.statistics.live != 0) return error.DecoderLeak;
            const code = self.error_code.load(.acquire);
            if (code != 0) return @errorFromInt(@as(u16, @intCast(code)));
            return self.snapshot();
        }

        fn snapshot(self: *Self) Report {
            var stack_used: [stacks.len]u32 = @splat(0);
            if (self.config.measure_stacks) for (stacks, 0..) |region, index| {
                stack_used[index] = @intCast(stack.used(region.cachedSlice(u8)));
            };
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
                    .seek_frame = self.requested_seek,
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
                .played_frames = self.timeline.played.load(),
                .deferred = self.deferred_track,
                .sequence_tracks = self.sequence_tracks,
                .seek_clamped = self.end_seek.clamped,
                .final_status = if (self.header_ready.load(.acquire)) self.statusAt(self.timeline.played.load()) else null,
            };
        }

        fn current() *Self {
            return active.?;
        }

        pub fn cancelled(self: *Self) bool {
            return self.cancelled_flag.load(.acquire);
        }

        fn readerCancelled(context: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.cancelled()) return true;
            return if (self.previous_reader_control) |control| control.cancelled(control.context) else false;
        }

        fn installReaderControl(self: *Self) void {
            if (@hasField(Reader, "seek_control")) {
                const incoming = self.reader.seek_control;
                if (incoming == null or incoming.?.context != @as(*anyopaque, @ptrCast(self)) or incoming.?.cancelled != readerCancelled) self.previous_reader_control = incoming;
                self.reader.seek_control = .{ .context = self, .cancelled = readerCancelled };
            }
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

        pub fn configure(self: *Self, incoming: info.Information) !void {
            var information = incoming;
            if (self.config.sequence != null or self.config.force_output_24 or self.config.gain_q24 != output.unity_gain_q24) information.output_format = .signed_24_in_u32;
            if (self.cancelled()) return error.Cancelled;
            const ready = self.header_ready.load(.acquire);
            if (ready and (information.sample_rate != self.information.sample_rate or information.output_format != self.information.output_format)) {
                if (self.config.sequence != null and !self.track_configured) {
                    // A native-rate boundary is deliberately drained and
                    // reopened by the caller; never resample silently.
                    self.deferred_track = self.current_track;
                    @import("health.zig").snapshot.stream_deferred = self.current_track.occurrence;
                    return error.StreamFormatBoundary;
                }
                return error.FormatChanged;
            }
            if (ready and self.config.sequence == null) {
                if (information.channels != self.information.channels) return error.FormatChanged;
                return;
            }
            if (self.track_configured) return;
            if (!ready) {
                self.plan = try output.Plan.init(information.sample_rate, information.output_format);
                if (audio.sampleRate(information.sample_rate) == null) return error.UnsupportedSampleRate;
                if (self.plan.bytes > memory.audio_buffer_capacity) return error.InvalidWorkspace;
                if (self.reservoir.capacity() < decoder_batch_frames + startup_margin_periods * self.plan.frames) return error.InvalidWorkspace;
                self.information = information;
            }
            if (self.config.sequence != null) {
                const marker = stream.Marker.init(self.current_track, self.produced_frames, information);
                while (true) {
                    self.markers.append(marker) catch |failure| {
                        if (failure != error.MarkerBackpressure) return failure;
                        // An arbitrarily long run of sub-period/empty files
                        // cannot fit a bounded metadata queue before startup.
                        // Drain what is already admitted and let main reopen
                        // this file, rather than deadlocking startup or dropping
                        // a boundary. Normal playback waits for UI reclamation.
                        if (!self.started) {
                            self.deferred_track = self.current_track;
                            @import("health.zig").snapshot.stream_deferred = self.current_track.occurrence;
                            return error.StreamCapacityBoundary;
                        }
                        _ = self.runtime.take(event);
                        if (self.markers.free() == 0 and !self.cancelled()) self.runtime.wait(event, null);
                        if (self.cancelled()) return error.Cancelled;
                        continue;
                    };
                    break;
                }
            }
            self.track_configured = true;
            self.sequence_tracks +%= 1;
            @import("health.zig").snapshot.stream_tracks = self.sequence_tracks;
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
            var start_frame = self.config.start_frame;
            while (!self.cancelled()) {
                self.track_configured = false;
                self.workspace.decoder.seek_index = if (self.config.seek_cache) |cache| cache.forSource(self.current_track.source_identity, self.length) else self.config.seek_index;
                self.workspace.decoder.seek_source = self.current_track.source_identity;
                const decoded = decoder.run(&self.input, self.length, Self, self, self.workspace.decoder, start_frame) catch |failure| {
                    if (failure != error.Cancelled and failure != error.StreamFormatBoundary and failure != error.StreamCapacityBoundary) self.fail(failure);
                    break;
                };
                // Decoder destruction has completed before another library is
                // initialized in the same bounded pool.
                if (self.workspace.decoder.packet.pool.statistics.live != 0) {
                    self.fail(error.DecoderLeak);
                    break;
                }
                if (self.cancelled()) break;
                const prepared = self.started or self.prepared or self.prepare_requested or self.reservoir.available() != 0;
                if (self.end_seek.retry(start_frame, decoded.total_frames, self.produced_frames, prepared)) |target| {
                    self.header_ready.store(false, .release);
                    self.markers.resetBeforeStart() catch |failure| {
                        self.fail(failure);
                        break;
                    };
                    self.sequence_tracks = 0;
                    @import("health.zig").snapshot.stream_tracks = 0;
                    self.input.seekTo(0) catch |failure| {
                        if (failure != error.Cancelled) self.fail(failure);
                        break;
                    };
                    start_frame = target;
                    continue;
                }
                if (self.config.sequence == null or self.cancelled()) break;
                const generation = self.source_switch.request(self.current_track) catch |failure| {
                    self.fail(failure);
                    break;
                };
                self.runtime.notify(.storage, event);
                while (!self.source_switch.ready(generation) and !self.cancelled()) {
                    _ = self.runtime.take(event);
                    if (!self.source_switch.ready(generation) and !self.cancelled()) self.runtime.wait(event, null);
                }
                if (self.cancelled()) break;
                self.current_track = self.source_switch.result(generation) orelse break;
                start_frame = 0;
            }
            self.codec_done.store(true, .release);
            self.runtime.notify(.output, event);
            self.runtime.notify(.control, event);
            self.runtime.notify(.storage, event);
            self.runtime.retire();
        }

        /// Only the storage task replaces the file reader and compressed ring.
        /// The codec has fully unwound and waits on a separate acknowledgement.
        fn openNext(self: *Self) bool {
            if (self.cancelled()) return false;
            const request = self.source_switch.pending() orelse return false;
            const sequence = self.config.sequence orelse return false;
            var next = sequence.open_next(sequence.context, self.reader, request.previous) catch |failure| failed: {
                self.fail(failure);
                break :failed null;
            };
            if (self.cancelled()) next = null;
            if (next) |track| {
                if (!track.valid()) {
                    self.fail(error.InvalidSequenceTrack);
                    next = null;
                } else {
                    self.length = track.length;
                    self.installReaderControl();
                    self.input = Input.init(self.reader, track.length, self.workspace.input, self) catch |failure| failed: {
                        self.fail(failure);
                        next = null;
                        break :failed self.input;
                    };
                }
            }
            if (!self.source_switch.complete(request.generation, next)) self.fail(error.InvalidSourceSwitch);
            self.runtime.notify(.codec, event);
            return true;
        }

        pub fn fillInput(self: *Self) bool {
            if (self.openNext()) return true;
            const burst_bytes = self.workspace.burst.len - dma_word_bytes;
            if (self.cancelled() or self.codec_done.load(.acquire) or !self.input.producerReady(burst_bytes)) return false;
            const alignment_offset = self.input.producer_position & (dma_word_bytes - 1);
            _ = self.input.produce(self.workspace.burst[alignment_offset..][0..burst_bytes]) catch |failure| self.fail(failure);
            self.storage_steps += 1;
            return true;
        }

        pub fn backgroundConditions(self: *Self) @import("scan_admission.zig").Conditions {
            return .{
                .started = self.started,
                .cancelled = self.cancelled(),
                .sample_rate = if (self.header_ready.load(.acquire)) self.information.sample_rate else 0,
                .pcm_frames = self.reservoir.available(),
            };
        }

        fn scanPoll(context: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            @import("scan_admission.zig").refill(self);
            // A scan only borrows slack after the codec has a generous PCM
            // reserve. Waiting yields to output, UI, control and codec owners.
            while (!self.cancelled() and !self.codec_done.load(.acquire) and !@import("scan_admission.zig").admit(self.backgroundConditions())) {
                _ = self.runtime.take(event);
                self.runtime.wait(event, self.runtime.now() + x.Timer.milliseconds(1));
                @import("scan_admission.zig").refill(self);
            }
            return self.cancelled();
        }

        fn storageEntry() callconv(.c) noreturn {
            const self = current();
            while (true) {
                _ = self.runtime.take(event);
                self.storage_idle.store(false, .release);
                @import("scan_admission.zig").refill(self);
                if (@import("scan_admission.zig").admit(self.backgroundConditions())) if (self.config.storage_work) |work| {
                    work.run(work.context, .{ .context = self, .poll = scanPoll });
                };
                self.storage_idle.store(true, .release);
                self.runtime.notify(.control, event);
                self.runtime.wait(event, if (self.config.storage_work != null and !self.cancelled()) self.runtime.now() + x.Timer.milliseconds(20) else null);
            }
        }

        fn render(self: *Self, slot: u8) !void {
            const started = x.Timer.now();
            const bytes = @as([*]u8, @ptrFromInt(self.resources.buffers[slot].address))[0..self.plan.bytes];
            const result = if (self.config.sequence != null) try self.stream_renderer.render(&self.markers, &self.reservoir, bytes, self.plan, self.paused.load(.acquire)) else try transport.render(&self.reservoir, bytes, self.plan, self.config.gain_q24, &self.quantizer, self.information.source_bits > 24, self.paused.load(.acquire));
            self.timeline.queue(slot, result.frames);
            if (result.underrun and !self.codec_done.load(.acquire)) return error.AudioUnderrun;
            self.worst_fill_ticks = @max(self.worst_fill_ticks, x.Timer.elapsed(started));
            self.periods += 1;
            self.runtime.notify(.codec, event);
        }

        fn boundEnd(self: *Self) !void {
            if (self.end_bounded or !self.codec_done.load(.acquire) or self.reservoir.available() != 0) return;
            const total_chunks = @as(u64, self.periods) + self.config.buffer_count;
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
                    self.timeline.played.store(if (self.config.sequence != null) 0 else self.information.start_frame);
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
                    self.state = playback.State.init(.{
                        .buffer_count = self.config.buffer_count,
                        .descriptor_count = self.config.descriptor_count,
                        .total_chunks = std.math.maxInt(u32),
                    }) catch |failure| {
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
                        const released_slot: u8 = @intCast(self.state.?.chunks_completed % self.config.buffer_count);
                        const transition = self.state.?.advance(self.state.?.nextDescriptor()) catch |failure| {
                            self.fail(failure);
                            failed = true;
                            break;
                        };
                        self.timeline.complete(released_slot);
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
                if (self.config.background) |background| background.poll(background.context);
                if (self.prepare_requested and self.engine == null) {
                    self.engine = audio.Engine.init(self.resources, .{
                        .descriptor_count = self.config.descriptor_count,
                        .buffer_count = self.config.buffer_count,
                        .chunk_bytes = @intCast(self.plan.bytes),
                        .sample_format = audio.sampleFormat(self.plan.format),
                    }) catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                    self.engine.?.initialize(audio.sampleRate(self.information.sample_rate).?, self.attenuation) catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                }
                const volume = self.requested_volume.swap(0, .acq_rel);
                if (volume != 0) {
                    self.attenuation = @intCast(volume - 1);
                    if (self.engine != null) self.engine.?.setHardwareVolume(self.attenuation) catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                }
                if (self.engine) |*engine| {
                    engine.pollControl() catch |failure| {
                        self.fail(failure);
                        continue;
                    };
                    const health = &@import("health.zig").snapshot;
                    health.output_soft_muted = @intFromBool(if (engine.dac) |dac| dac.muted else true);
                    health.output_hard_muted = @intFromBool(@import("f20_v27.zig").audio.output_mute.get());
                    health.output_attenuation = engine.volume.attenuation;
                    if (self.config.routing) |routing| {
                        const actual: audio.Output = if (engine.route.stage == .idle) engine.route.current else .muted;
                        if (routing.poll(routing.context, actual)) |desired| engine.setOutput(desired);
                    }
                    // Initial route settling completes before DMA consumes a
                    // track opening. Default headphone startup adds no wait.
                    if (self.prepare_requested and !self.prepared and engine.route.stage == .idle) {
                        self.prepared = true;
                        self.runtime.notify(.output, event);
                    }
                }
                const diagnostics = @import("f20_diagnostics.zig");
                diagnostics.report.live_pcm_frames = @intCast(self.reservoir.available());
                diagnostics.report.live_input_bytes = @intCast(self.input.ring.available());
                diagnostics.report.live_decode_frames = @truncate(self.produced_frames);
                diagnostics.report.codec_ticks = @truncate(self.runtime.metrics.task_ticks[3]);
                diagnostics.report.control_ticks = @truncate(self.runtime.metrics.task_ticks[2]);
                diagnostics.report.storage_task_ticks = @truncate(self.runtime.metrics.task_ticks[4]);
                diagnostics.report.idle_ticks = @truncate(self.runtime.metrics.task_ticks[5]);
                diagnostics.report.live_played_frames = @truncate(self.timeline.played.load());
                diagnostics.report.live_underruns = if (self.engine) |engine| engine.underrun_count else 0;
                diagnostics.report.live_ui_gap = self.maximum_ui_gap_ticks;
                diagnostics.report.live_fill = self.worst_fill_ticks;

                self.runtime.wait(event, self.runtime.now() + control_ticks);
            }
        }

        fn publishAudible(self: *Self, completed: u64, comptime wake_owners: bool) void {
            if (!self.started) return;
            const sequence = self.config.sequence orelse return;
            while (true) {
                const previous = self.audible.current;
                const marker = self.audible.advance(&self.markers, completed) orelse break;
                if (previous != null) @import("health.zig").snapshot.stream_handoffs +%= 1;
                sequence.audible(sequence.context, marker.track);
                if (wake_owners) {
                    self.runtime.notify(.codec, event);
                    self.runtime.notify(.storage, event);
                }
            }
        }

        fn statusAt(self: *Self, completed: u64) media.PlaybackStatus {
            const ready = self.header_ready.load(.acquire);
            const natural_end = self.codec_done.load(.acquire) and self.error_code.load(.acquire) == 0 and self.requested_exit.load(.acquire) == 0;
            const audible = self.audible.current;
            const total = if (audible != null)
                self.audible.total(&self.markers, if (natural_end) self.produced_frames else null) orelse 0
            else if (ready)
                self.information.total_frames orelse if (natural_end) self.information.start_frame +| self.produced_frames else 0
            else
                0;
            const played = if (audible) |marker| marker.position(completed) else completed +| (if (ready and self.config.sequence != null) self.information.start_frame else @as(u64, 0));
            return .{
                .phase = if (!self.started) .preparing else if (self.paused.load(.acquire)) .paused else .playing,
                .sample_rate = if (ready) self.information.sample_rate else 0,
                .output_format = if (ready) self.information.output_format else .signed_24_in_u32,
                .total_frames = total,
                .played_frames = if (total == 0) played else @min(total, played),
            };
        }

        fn uiEntry() callconv(.c) noreturn {
            const self = current();
            while (true) {
                if (self.control) |control| {
                    const completed = self.timeline.played.load();
                    self.publishAudible(completed, true);
                    const status = self.statusAt(completed);
                    const total = status.total_frames;
                    const ui_started = x.Timer.now();
                    if (self.previous_ui_tick) |previous| self.maximum_ui_gap_ticks = @max(self.maximum_ui_gap_ticks, ui_started -% previous);
                    self.previous_ui_tick = ui_started;
                    const command = control.poll(control.context, status);
                    self.maximum_ui_ticks = @max(self.maximum_ui_ticks, x.Timer.elapsed(ui_started));
                    self.ui_polls += 1;
                    switch (command) {
                        .none => {},
                        .toggle_pause => self.paused.store(!self.paused.load(.acquire), .release),
                        .seek_to => |target| {
                            self.requested_seek = if (total == 0) target else @min(total - 1, target);
                            _ = self.requested_exit.cmpxchgStrong(0, @backingInt(media.PlaybackExit.seek), .acq_rel, .acquire);
                        },
                        .set_attenuation => |value| self.requested_volume.store(@as(u32, @import("volume_control.zig").clamp(value)) + 1, .release),
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

test "final joined status adopts missed markers and apportions unknown durations only at natural EOF" {
    const TestPlayer = Player(struct {});
    const Callback = struct {
        calls: u32 = 0,
        occurrence: u32 = 0,

        fn open(_: *anyopaque, _: *anyopaque, _: stream.Track) anyerror!?stream.Track {
            return null;
        }

        fn adopt(context: *anyopaque, track: stream.Track) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.occurrence = track.occurrence;
        }
    };
    var callback = Callback{};
    var player: TestPlayer = undefined;
    player.config = .{ .sequence = .{ .context = &callback, .first = .{ .occurrence = 17, .length = 4096 }, .open_next = Callback.open, .audible = Callback.adopt } };
    player.header_ready = .init(true);
    player.information = .{ .kind = .mp3, .sample_rate = 48000, .channels = 2, .output_format = .signed_24_in_u32, .start_frame = 1000 };
    player.started = true;
    player.paused = .init(false);
    player.codec_done = .init(false);
    player.error_code = .init(0);
    player.requested_exit = .init(0);
    player.produced_frames = 1600;
    player.markers = .{};
    const first = stream.Marker.init(.{ .occurrence = 17 }, 0, player.information);
    var second = first;
    second.track.occurrence = 18;
    second.sequence = 1537;
    second.start_frame = 0;
    try player.markers.append(first);
    try player.markers.append(second);
    player.markers.copied.store(2, .release);
    player.audible = .{};
    _ = player.audible.advance(&player.markers, 0);
    const before = player.statusAt(1500);
    try std.testing.expectEqual(2537, before.total_frames);
    try std.testing.expectEqual(2500, before.played_frames);
    // The UI missed the final period. Joined adoption must precede the final
    // checkpoint and EOF queue decision, using the completed-frame frontier.
    player.codec_done.store(true, .release);
    player.publishAudible(1600, false);
    const final = player.statusAt(1600);
    try std.testing.expectEqual(1, callback.calls);
    try std.testing.expectEqual(18, callback.occurrence);
    try std.testing.expectEqual(63, final.total_frames);
    try std.testing.expectEqual(63, final.played_frames);
    // An ordinary cancellation or decoder failure is not an inferred EOF.
    player.requested_exit.store(@backingInt(media.PlaybackExit.stopped), .release);
    try std.testing.expectEqual(0, player.statusAt(1600).total_frames);
    player.requested_exit.store(0, .release);
    player.error_code.store(@intFromError(error.Truncated), .release);
    try std.testing.expectEqual(0, player.statusAt(1600).total_frames);
    // Exact decoder/container totals always take precedence over inference.
    player.audible.current.?.total_frames = 3207;
    try std.testing.expectEqual(3207, player.statusAt(1600).total_frames);
}

test "single-file EOF reconstruction retains the seek origin and never invents a cancellation duration" {
    const TestPlayer = Player(struct {});
    var player: TestPlayer = undefined;
    player.config = .{};
    player.header_ready = .init(true);
    player.information = .{ .kind = .mp3, .sample_rate = 48000, .channels = 2, .output_format = .signed_24_in_u32, .start_frame = 1000 };
    player.started = true;
    player.paused = .init(false);
    player.codec_done = .init(true);
    player.error_code = .init(0);
    player.requested_exit = .init(0);
    player.produced_frames = 537;
    player.audible = .{};
    try std.testing.expectEqual(1537, player.statusAt(1537).total_frames);
    try std.testing.expectEqual(1537, player.statusAt(1537).played_frames);
    player.requested_exit.store(@backingInt(media.PlaybackExit.seek), .release);
    try std.testing.expectEqual(0, player.statusAt(1200).total_frames);
    player.information.total_frames = 9999;
    try std.testing.expectEqual(9999, player.statusAt(1200).total_frames);
}
