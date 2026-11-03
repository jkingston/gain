//! A scan executes on the player's sole storage task. Polling only happens at
//! filesystem boundaries; the player pumps compressed input before proceeding.
const std = @import("std");
const core = @import("library.zig");
const native = @import("f20_library.zig");
const diag = @import("f20_diagnostics.zig");
const memory = @import("f20_memory.zig");
const x = @import("x1000.zig");
const player = @import("f20_player.zig");
const views = @import("progressive_view.zig");

pub const State = struct {
    volume: *native.Volume,
    projection: *views.Pair,
    covers: ?*@import("f20_covers.zig").Loader = null,
    requested: bool = false,
    queued: ?bool = null,
    cold: bool = false,
    complete: bool = false,
    playing: bool = false,
    deferred_artwork: bool = false,
    pending: ?core.Owned = null,
    service: ?player.StorageService = null,
    stats: core.Stats = .{},
    phase: []const u8 = "Ready",
    last_publication: u32 = 0,
    summary: diag.IndexSummary = .{},
    error_pending: ?anyerror = null,

    pub fn init(volume: *native.Volume) !State {
        comptime {
            if (@sizeOf(views.Pair) > memory.scan_views.bytes) @compileError("progressive views exceed reserved memory");
        }
        const pair: *views.Pair = @ptrFromInt(memory.scan_views.cached());
        pair.* = .{};
        const baseline = if (diag.catalog) |*catalog| &catalog.value else &core.Catalog{};
        try pair.publish(baseline, baseline.tracks, volume.serial, true);
        return .{ .volume = volume, .projection = pair };
    }

    pub fn request(self: *State, cold: bool) void {
        if (self.pending != null or diag.report.scan_active != 0) {
            // USB ACK confirms acceptance. A request made while catalogue
            // persistence is finishing must not disappear at that boundary.
            self.queued = cold or (self.queued orelse false);
            return;
        }
        self.cold = cold;
        self.complete = false;
        self.requested = true;
    }

    pub fn run(context: *anyopaque, service: player.StorageService) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (self.covers) |cache| cache.service(self.volume);
        if (!self.requested) return;
        self.requested = false;
        self.service = service;
        defer self.service = null;
        self.scan() catch |failure| {
            if (failure == error.Cancelled) {
                diag.report.scan_cancelled += 1;
                self.requested = true;
            } else {
                diag.report.scan_failure = @intFromError(failure);
                self.error_pending = failure;
                diag.report.scan_last_command = self.volume.device.last_command;
                diag.report.scan_last_status = self.volume.device.last_status;
                diag.report.scan_last_flags = self.volume.device.last_flags;
            }
            self.phase = if (failure == error.Cancelled) "Scan paused" else "Scan failed";
        };
    }

    fn poll(context: *anyopaque) bool {
        const self: *State = @ptrCast(@alignCast(context));
        x.Watchdog.kick();
        if (self.service.?.poll(self.service.?.context)) return true;
        if (self.covers) |cache| cache.service(self.volume);
        return false;
    }

    fn progress(context: *anyopaque, phase: []const u8, stats: core.Stats, _: u32) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.stats = stats;
        self.phase = phase;
        diag.report.scan_visited = stats.visited;
        diag.report.scan_total = stats.candidates;
    }

    fn checkpoint(context: *anyopaque, _: *const core.Catalog, tracks: []const core.Track, stats: core.Stats) !void {
        const self: *State = @ptrCast(@alignCast(context));
        if (poll(self)) return error.Cancelled;
        if (self.last_publication != 0 and x.Timer.elapsed(self.last_publication) < x.Timer.milliseconds(300)) return;
        const began = x.Timer.now();
        const retained_art = core.Catalog{ .albums = if (diag.catalog) |catalog| catalog.value.albums else &.{} };
        const baseline = if (!self.cold and diag.catalog != null) &diag.catalog.?.value else &retained_art;
        try self.projection.publish(baseline, tracks, self.volume.serial, false);
        self.last_publication = x.Timer.now();
        diag.report.scan_worst_publication = @max(diag.report.scan_worst_publication, x.Timer.elapsed(began));
        diag.report.scan_publications += 1;
        diag.report.scan_view_tracks = @intCast(self.projection.current().track_count);
        diag.report.scan_view_albums = @intCast(self.projection.current().album_count);
        self.stats = stats;
    }

    fn aborted(context: *anyopaque, previous: *const core.Catalog) void {
        const self: *State = @ptrCast(@alignCast(context));
        const revision = self.projection.prepare(previous, previous.tracks, self.volume.serial, true) catch empty: {
            break :empty self.projection.prepare(&.{}, &.{}, self.volume.serial, true) catch unreachable;
        };
        // The UI cannot republish old artwork paths between withdrawing its
        // preview and clearing requests. No allocation, I/O or drawing here.
        const status = x.Interrupts.disableCpu();
        self.projection.commit(revision);
        if (self.covers) |cache| cache.cache.clearRequests();
        x.Interrupts.restoreCpu(status);
    }

    fn scan(self: *State) !void {
        diag.report.scan_active = 1;
        diag.report.scan_complete = 0;
        diag.report.scan_failure = 0;
        diag.report.scan_played_start = diag.report.live_played_frames;
        self.last_publication = 0;
        const began = x.Timer.now();
        const io_before = self.volume.device.counters;
        defer {
            diag.report.scan_active = 0;
            diag.report.scan_played_end = diag.report.live_played_frames;
        }
        var scratch = std.heap.FixedBufferAllocator.init(memory.scan_scratch.cachedSlice(u8));
        var maps = std.heap.FixedBufferAllocator.init(memory.scan_maps.cachedSlice(u8));
        defer {
            diag.report.scan_scratch_peak = @intCast(scratch.end_index);
            diag.report.scan_maps_peak = @intCast(maps.end_index);
        }
        var backend = native.Backend.init(self.volume, .{
            .context = self,
            .poll = poll,
            .progress = progress,
            .checkpoint = checkpoint,
            .aborted = aborted,
        }, maps.allocator());
        backend.concurrent = self.playing;
        defer backend.deinit();
        const baseline = if (diag.catalog) |*catalog| &catalog.value else &core.Catalog{};
        var next = try core.scanWithScratch(diag.backgroundAllocator(), scratch.allocator(), &backend, baseline, if (self.cold) .verify else .quick, &backend);
        errdefer {
            aborted(self, baseline);
            next.deinit();
        }
        if (diag.catalog) |old| next.value.generation = old.value.generation + 1;
        try self.projection.publish(baseline, next.value.tracks, self.volume.serial, true);
        self.pending = next;
        self.complete = true;
        self.phase = "Library updated";
        diag.report.scan_publications += 1;
        diag.report.scan_view_tracks = @intCast(next.value.tracks.len);
        diag.report.scan_view_albums = @intCast(next.value.albums.len);
        diag.report.scan_complete = 1;
        diag.report.scan_scratch_peak = @intCast(scratch.end_index);
        self.deferred_artwork = self.playing;
        diag.report.scan_deferred_artwork = if (self.playing) @intCast(next.value.albums.len) else 0;
        diag.report.index_ticks = x.Timer.elapsed(began);
        diag.report.index_tracks = @intCast(next.value.tracks.len);
        diag.report.index_albums = @intCast(next.value.albums.len);
        diag.report.index_parsed = next.value.stats.parsed;
        diag.report.index_reused = next.value.stats.reused;
        diag.report.index_errors = next.value.stats.errors;
        diag.report.index_bytes = @intCast(backend.metrics.source_bytes);
        diag.report.index_heap = @intCast(next.bytes());
        diag.report.index_runs += 1;
        diag.report.index_metadata_ticks = @truncate(backend.metrics.metadata_ticks);
        diag.report.index_artwork_ticks = @truncate(backend.metrics.artwork_ticks);
        diag.report.index_directory_ticks = @truncate(backend.metrics.enumeration_ticks);
        diag.report.art_prepared = backend.metrics.art_prepared;
        diag.report.art_reused = backend.metrics.art_reused;
        const io = self.volume.device.counters;
        diag.report.index_read_sectors = @intCast(io.read_sectors - io_before.read_sectors);
        diag.report.index_written_sectors = @intCast(io.write_sectors - io_before.write_sectors);
        diag.report.index_io_ticks = @truncate(io.ticks - io_before.ticks);
        diag.report.index_io_failures = io.failures - io_before.failures;
        self.summary = .{
            .stats = next.value.stats,
            .metrics = backend.metrics,
            .reads = io.reads - io_before.reads,
            .writes = io.writes - io_before.writes,
            .bus_hz = self.volume.device.bus_hz,
            .scratch_bytes = @intCast(scratch.end_index),
            .verify = self.cold,
        };
    }

    pub fn finish(self: *State) void {
        // No player/USB worker may retain old catalogue references here.
        if (self.error_pending) |failure| {
            diag.failed(2, failure);
            self.error_pending = null;
        }
        if (self.pending) |next| {
            if (self.covers) |cache| cache.cache.clearRequests();
            diag.finishBackground(next);
            diag.recordIndex(self.summary);
            self.pending = null;
            // Image preparation and cache writes use idle storage ownership.
            // A quick refresh reuses unchanged metadata and prepares new art.
            if (self.deferred_artwork and !self.playing) {
                self.deferred_artwork = false;
                self.request(false);
            }
        }
        if (self.queued) |verify| {
            self.queued = null;
            self.request(verify);
        }
    }
};
