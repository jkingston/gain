//! Desktop adapter for the production player UI, loaded by the generic host.
//! Optional catalogue JSON is read-only. Transport uses a test clock, not audio.
const std = @import("std");
const gain = @import("gain_ui");
const api = gain.simulator;
const core = gain.library;
const media = gain.media;
const host_sd = @import("host_sd.zig");

extern fn getenv([*:0]const u8) ?[*:0]const u8;

extern fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;

extern fn fseek(*anyopaque, c_long, c_int) c_int;

extern fn ftell(*anyopaque) c_long;

extern fn fread([*]u8, usize, usize, *anyopaque) usize;

extern fn fclose(*anyopaque) c_int;

var milliseconds: u64 = 0;
var projection: gain.progressive_view.Pair = .{};
var cache: gain.cover_cache.Cache = .{};
var track_memory: [32 * 1024]u8 = undefined;
var state: State = undefined;
var index: Platform.Index.State = .{};
var catalogue: ?std.json.Parsed(core.Catalog) = null;
var playing = false;
var started_at: u64 = 0;
var presented_revision: u64 = 0;
var host_io: std.Io.Threaded = undefined;
var mutex: std.Io.Mutex = .init;
var sd_root: ?[]const u8 = null;
var sd_catalogue: ?core.Owned = null;
var scan_thread: ?std.Thread = null;
var scan_finished: std.atomic.Value(bool) = .init(true);
var stopping: std.atomic.Value(bool) = .init(false);
var scan_mode: core.Mode = .quick;
var scan_failure: u32 = 0;

fn lock() void {
    mutex.lockUncancelable(host_io.io());
}

fn unlock() void {
    mutex.unlock(host_io.io());
}

fn scanCancelled(_: *anyopaque) bool {
    return stopping.load(.acquire);
}

fn scanProgress(_: *anyopaque, phase: []const u8, stats: core.Stats, _: u32) void {
    lock();
    defer unlock();
    index.phase = phase;
    Platform.Diagnostics.report.scan_visited = stats.visited;
    Platform.Diagnostics.report.scan_total = stats.candidates;
}

fn publish(previous: *const core.Catalog, tracks: []const core.Track, source: u64, complete: bool) !void {
    // The worker alone builds inactive slots. Commit under the callback lock;
    // no UI callback can still hold the slot that becomes inactive afterward.
    const revision = try projection.prepare(previous, tracks, source, complete);
    lock();
    defer unlock();
    projection.commit(revision);
    cache.clearRequests();
}

fn scanCheckpoint(_: *anyopaque, previous: *const core.Catalog, tracks: []const core.Track, _: core.Stats) !void {
    if (stopping.load(.acquire)) return error.Cancelled;
    try publish(previous, tracks, core.hash(sd_root.?), false);
}

fn scanAborted(_: *anyopaque, previous: *const core.Catalog) void {
    publish(previous, previous.tracks, previous.source, true) catch {};
}

fn replaceText(_: *anyopaque, destination: *[]const u8, text: []const u8) void {
    lock();
    defer unlock();
    destination.* = text;
}

fn scan() !void {
    const io = host_io.io();
    const root = try std.Io.Dir.cwd().openDir(io, sd_root.?, .{ .iterate = true });
    defer root.close(io);
    var backend = host_sd.Backend{
        .root = root,
        .io = io,
        .source = core.hash(sd_root.?),
        .hooks = .{ .context = &index, .cancelled = scanCancelled, .progress = scanProgress, .checkpoint = scanCheckpoint, .aborted = scanAborted, .replace_text = replaceText },
    };
    const old = if (sd_catalogue) |*owned| &owned.value else &core.Catalog{};
    var next = try core.scan(std.heap.c_allocator, &backend, old, scan_mode, &backend);
    errdefer next.deinit();
    try publish(&next.value, next.value.tracks, next.value.source, true);
    lock();
    const previous = sd_catalogue;
    sd_catalogue = next;
    Platform.Diagnostics.catalog = .{ .value = next.value };
    index.phase = "Ready";
    unlock();
    if (previous) |owned| {
        var obsolete = owned;
        obsolete.deinit();
    }
}

fn scanEntry() void {
    defer scan_finished.store(true, .release);
    lock();
    Platform.Diagnostics.report.scan_active = 1;
    scan_failure = 0;
    index.phase = "Finding music";
    unlock();
    scan() catch |failure| {
        lock();
        index.phase = if (failure == error.Cancelled) "Scan paused" else "Scan failed";
        scan_failure = if (failure == error.Cancelled) 0 else @intFromError(failure);
        unlock();
        if (failure != error.Cancelled) std.debug.print("Player UI SD scan: {s}\n", .{@errorName(failure)});
    };
    lock();
    Platform.Diagnostics.report.scan_active = 0;
    unlock();
}

fn startScan() void {
    if (!scan_finished.load(.acquire)) return;
    if (scan_thread) |thread| thread.join();
    scan_thread = null;
    index.requested = false;
    scan_mode = if (index.verify) .verify else .quick;
    scan_finished.store(false, .release);
    scan_thread = std.Thread.spawn(.{}, scanEntry, .{}) catch |failure| {
        scan_finished.store(true, .release);
        index.phase = "Scan unavailable";
        std.debug.print("Player UI SD scan: {s}\n", .{@errorName(failure)});
        return;
    };
}

const Platform = struct {
    pub fn now() u32 {
        return @truncate(milliseconds *% 6000);
    }

    pub fn trace(_: anytype, _: u32, _: u32) void {}

    pub const Index = struct {
        pub const State = struct {
            projection: *gain.progressive_view.Pair = &projection,
            phase: []const u8 = "Ready",
            requested: bool = false,
            verify: bool = false,

            pub fn request(self: *@This(), verify: bool) void {
                self.verify = verify;
                self.requested = true;
            }
        };
    };

    pub const Diagnostics = struct {
        pub var catalog: ?struct { value: core.Catalog } = null;
        pub var report: struct {
            failure: u32 = 0,
            scan_active: u32 = 0,
            scan_visited: u32 = 0,
            scan_total: u32 = 0,
            selected_album_low: u32 = 0,
            selected_album_high: u32 = 0,
            selected_album_rank: u32 = 0,
            ui_drawn: u32 = 0,
            ui_draw_max: u32 = 0,
            ui_animation_frames: u32 = 0,
            ui_animation_gap_max: u32 = 0,
            ui_animation_slow: u32 = 0,
            cover_header_max: u32 = 0,
            cover_scene_max: u32 = 0,
            cover_caption_max: u32 = 0,
        } = .{};
    };

    pub const Display = struct {
        pub const Frozen = struct {};
        var pixels: api.Pixels = undefined;
        var frozen: api.Pixels = undefined;
        var presented: api.Pixels = undefined;
        var revision: u64 = 0;
        pub const framebuffer = &pixels;
        pub const last_failure: ?anyerror = null;

        pub fn renderIntervalMs() u64 {
            return 16;
        }

        pub fn poll() enum { idle, busy, failed } {
            return .idle;
        }

        pub fn freeze(_: gain.presentation.Region) !Frozen {
            frozen = pixels;
            return .{};
        }

        pub fn presentFrozen(_: Frozen, _: bool) !void {
            presented = frozen;
            revision +%= 1;
        }
    };
};

const State = gain.music_ui.Controller(Platform);

fn loadCatalogue() !void {
    const path = getenv("GAIN_UI_CATALOG") orelse return;
    const file = fopen(path, "rb") orelse return error.OpenCatalogue;
    defer _ = fclose(file);
    if (fseek(file, 0, 2) != 0) return error.ReadCatalogue;
    const length = ftell(file);
    if (length < 0 or length > 32 * 1024 * 1024 or fseek(file, 0, 0) != 0) return error.CatalogueLimit;
    const bytes = try std.heap.c_allocator.alloc(u8, @intCast(length));
    defer std.heap.c_allocator.free(bytes);
    if (fread(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.ReadCatalogue;
    var parsed = try std.json.parseFromSlice(core.Catalog, std.heap.c_allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    // Preparation/activation happens between app callbacks on this host thread.
    const next = try projection.prepare(&parsed.value, parsed.value.tracks, parsed.value.source, true);
    projection.commit(next);
    if (catalogue) |*old| old.deinit();
    catalogue = parsed;
    Platform.Diagnostics.catalog = .{ .value = parsed.value };
}

fn init(at: u64) callconv(.c) void {
    host_io = .init(std.heap.c_allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    mutex = .init;
    stopping.store(false, .release);
    scan_finished.store(true, .release);
    scan_failure = 0;
    sd_root = if (getenv("GAIN_SD_ROOT")) |path| std.mem.span(path) else null;
    milliseconds = at;
    projection = .{};
    cache = .{};
    index = .{};
    Platform.Diagnostics.report = .{};
    Platform.Diagnostics.catalog = null;
    playing = false;
    presented_revision = 0;
    Platform.Display.revision = 0;
    projection.publish(&.{}, &.{}, 0, true) catch unreachable;
    if (sd_root == null) loadCatalogue() catch |failure| {
        index.phase = "Catalogue unavailable";
        std.debug.print("Player UI catalogue: {s}\n", .{@errorName(failure)});
    };
    state = .{ .index = &index, .covers = &cache, .track_store = .init(&track_memory) };
    index.requested = sd_root != null;
}

fn apply(command: media.PlaybackCommand, at: u64) void {
    switch (command) {
        .none, .set_attenuation => {},
        .stop => playing = false,
        .previous, .next => {
            if (state.neighbouringTrack(if (command == .previous) -1 else 1)) |track| state.queue(track);
        },
    }
    if (state.requested_track != null) {
        const track = state.track_store.begin() orelse return;
        state.playing_track = track;
        state.requested_track = null;
        started_at = at;
        playing = true;
    }
}

fn input(event: api.Event, at: u64) callconv(.c) void {
    lock();
    defer unlock();
    milliseconds = at;
    // The host forwards OS repeats for apps that want them; this player owns
    // its repeat clock and deliberately consumes only physical press/release.
    if (event.phase == .repeat) return;
    if (event.input == .up or event.input == .down) {
        if (event.phase == .press) apply(state.wheel(if (event.input == .up) -1 else 1, at, playing), at);
        return;
    }
    const button: gain.navigation.Button = switch (event.input) {
        .select => .play,
        .back => .back,
        .menu => .menu,
        .previous => .previous,
        .next => .next,
        .volume_up => .volume_up,
        .volume_down => .volume_down,
        .power => .power,
        .up, .down => unreachable,
    };
    apply(state.button(button, event.phase == .press, at, playing), at);
}

fn frame(pixels: *api.Pixels, at: u64) callconv(.c) bool {
    // Joining/spawning happens outside the callback lock; the worker may need
    // that lock to publish its final state while shutdown/reload waits for it.
    if (sd_root != null and index.requested) startScan();
    lock();
    defer unlock();
    milliseconds = at;
    if (sd_root == null and index.requested) {
        index.requested = false;
        loadCatalogue() catch |failure| std.debug.print("Player UI catalogue: {s}\n", .{@errorName(failure)});
    }
    apply(state.repeat(at, state.input_policy.held, playing), at);
    if (state.playing_track) |track| {
        const rate = @max(1, track.meta.sample_rate);
        const total = track.meta.duration_ms * rate / 1000;
        state.status = .{
            .phase = if (playing) .playing else .preparing,
            .sample_rate = rate,
            .output_format = .signed_24_in_u32,
            .total_frames = total,
            .played_frames = if (playing) @min(total, (at -| started_at) * rate / 1000) else state.status.played_frames,
        };
    }
    state.frame(at);
    if (presented_revision == Platform.Display.revision) return false;
    pixels.* = Platform.Display.presented;
    presented_revision = Platform.Display.revision;
    return true;
}

fn deinit() callconv(.c) void {
    stopping.store(true, .release);
    if (scan_thread) |thread| thread.join();
    scan_thread = null;
    if (sd_catalogue) |*owned| owned.deinit();
    sd_catalogue = null;
    if (catalogue) |*parsed| parsed.deinit();
    catalogue = null;
    host_io.deinit();
}

const interface = api.Api{ .init = init, .input = input, .frame = frame, .deinit = deinit };

export fn gain_app_api() callconv(.c) *const api.Api {
    return &interface;
}

/// Read-only app diagnostics for automated UI tests. The simulator host does
/// not import this contract or depend on any player screen or library concept.
pub const Status = extern struct {
    version: u32 = 1,
    screen: u32,
    selection: u32,
    first: u32,
    rows: u32,
    tracks: u32,
    albums: u32,
    artists: u32,
    revision: u32,
    scanning: u32,
    failure: u32,
    scan_failure: u32,
    parsed: u32,
    reused: u32,
    playing: u32,
    held: u32,
    selected_id: u64,
    playing_id: u64,
};

export fn gain_player_ui_status(output: *Status) callconv(.c) void {
    lock();
    defer unlock();
    const view = state.snapshot();
    output.* = .{
        .screen = @backingInt(state.screen),
        .selection = @intCast(state.selection),
        .first = @intCast(state.first),
        .rows = @intCast(state.rows()),
        .tracks = @intCast(view.track_count),
        .albums = @intCast(view.album_count),
        .artists = @intCast(view.artist_count),
        .revision = view.revision,
        .scanning = @intFromBool(!scan_finished.load(.acquire) or index.requested),
        .failure = Platform.Diagnostics.report.failure,
        .scan_failure = scan_failure,
        .parsed = if (sd_catalogue) |owned| owned.value.stats.parsed else 0,
        .reused = if (sd_catalogue) |owned| owned.value.stats.reused else 0,
        .playing = @intFromBool(playing),
        .held = state.input_policy.held,
        .selected_id = state.selected_id,
        .playing_id = if (state.playing_track) |track| track.id else 0,
    };
}
