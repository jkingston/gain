//! Application-owned measurement and persistence. Never writes while playback
//! workers or the USB host own SD; no file allocation and no text hot-path logs.
const std = @import("std");
const x = @import("x1000.zig");
const memory = @import("f20_memory.zig");
const portable = @import("diagnostics.zig");
const usb = @import("f20_usb.zig");
const native = @import("f20_library.zig");
const library = @import("library.zig");
const codec = @import("catalog_codec.zig");
const store = @import("catalog_store.zig");
const managed = @import("managed_file.zig");

pub const Volume = native.Volume;
pub var log: portable.Collector = .{};
pub var report: Report = .{};

pub const Report = extern struct {
    magic: u32 = 0x474d4554,
    usb_state: u32 = 0,
    version: u32 = 1,
    stage: u32 = 0,
    failure: u32 = 0,
    boot_ticks: u32 = 0,
    index_ticks: u32 = 0,
    index_load_ticks: u32 = 0,
    index_save_ticks: u32 = 0,
    index_tracks: u32 = 0,
    index_albums: u32 = 0,
    index_parsed: u32 = 0,
    index_reused: u32 = 0,
    index_errors: u32 = 0,
    index_bytes: u32 = 0,
    index_heap: u32 = 0,
    index_metadata_ticks: u32 = 0,
    index_artwork_ticks: u32 = 0,
    index_directory_ticks: u32 = 0,
    art_prepared: u32 = 0,
    art_reused: u32 = 0,
    log_pages: u32 = 0,
    log_failures: u32 = 0,
    log_dropped: u32 = 0,
    codec_ticks: u32 = 0,
    idle_ticks: u32 = 0,
    played_frames: u32 = 0,
    playback_runs: u32 = 0,
    playback_frames: u32 = 0,
    underruns: u32 = 0,
    startup_ticks: u32 = 0,
    fill_ticks: u32 = 0,
    ui_ticks: u32 = 0,
    ui_gap_ticks: u32 = 0,
    irq_ticks: u32 = 0,
    battery_mv: u32 = 0,
    charge_ua: u32 = 0,
    discharge_ua: u32 = 0,
    usb_mv: u32 = 0,
    usb_ua: u32 = 0,
    power_valid: u32 = 0,
    coulomb_charge: u32 = 0,
    coulomb_discharge: u32 = 0,
    adc_rate: u32 = 0,
    coulomb_running: u32 = 0,
    charge_uah: u32 = 0,
    discharge_uah: u32 = 0,
    battery_energy_uwh: u32 = 0,
    sectors: u32 = 0,
    index_runs: u32 = 0,
    index_read_sectors: u32 = 0,
    index_written_sectors: u32 = 0,
    index_io_ticks: u32 = 0,
    index_io_failures: u32 = 0,
    index_stack_used: u32 = 0,
    scan_active: u32 = 0,
    scan_visited: u32 = 0,
    scan_total: u32 = 0,
    scan_publications: u32 = 0,
    scan_view_tracks: u32 = 0,
    scan_view_albums: u32 = 0,
    scan_cancelled: u32 = 0,
    scan_scratch_peak: u32 = 0,
    scan_worst_publication: u32 = 0,
    scan_played_start: u32 = 0,
    scan_played_end: u32 = 0,
    scan_complete: u32 = 0,
    live_played_frames: u32 = 0,
    live_underruns: u32 = 0,
    live_ui_gap: u32 = 0,
    live_fill: u32 = 0,
    live_storage_stack: u32 = 0,
    scan_deferred_artwork: u32 = 0,
    selected_album_low: u32 = 0,
    selected_album_high: u32 = 0,
    selected_album_rank: u32 = 0,
    scan_failure: u32 = 0,
    control_ticks: u32 = 0,
    ui_task_ticks: u32 = 0,
    storage_task_ticks: u32 = 0,
    scan_maps_peak: u32 = 0,
    build_id_low: u32 = 0,
    build_id_high: u32 = 0,
    ui_drawn: u32 = 0,
    ui_draw_max: u32 = 0,
    ui_animation_gap_max: u32 = 0,
    ui_animation_slow: u32 = 0,
    ui_animation_frames: u32 = 0,
    live_pcm_frames: u32 = 0,
    live_input_bytes: u32 = 0,
    live_decode_frames: u32 = 0,
    ui_trace_next: u32 = 0,
    raw_timer: u32 = 0,
    ui_clock_wraps: u32 = 0,
    power_samples_dropped: u32 = 0,
    ui_stack_used: u32 = 0,
    cover_header_max: u32 = 0,
    cover_scene_max: u32 = 0,
    cover_caption_max: u32 = 0,
    scan_last_command: u32 = 0,
    scan_last_status: u32 = 0,
    scan_last_flags: u32 = 0,
};

var clocks: @import("executive.zig").Clock = .{ .previous = 0 };
var started: u32 = 0;
var last_power: u64 = 0;
var last_health: u64 = 0;
var allocators: [2]std.heap.FixedBufferAllocator = undefined;
var current_slot: u1 = 0;
pub var catalog: ?library.Owned = null;
var committed: ?store.Header = null;
var catalogue_file: ?@import("fat32.zig").File = null;
var log_file: ?@import("fat32.zig").File = null;
var log_page: u32 = 0;

var volume_ptr: ?*Volume = null;
var previous_coulomb: ?@import("axp192.zig").Coulomb = null;
var power_since: u64 = 0;
var session: u64 = 0;
var build: u64 = 0;
var stack_painted = false;
var boot_recorded = false;

pub fn initialize(build_identity: u64, painted: bool) void {
    stack_painted = painted;
    boot_recorded = false;
    started = x.Timer.now();
    clocks = .{ .previous = started };
    build = build_identity;
    report.build_id_low = @truncate(build_identity);
    report.build_id_high = @truncate(build_identity >> 32);
    session = (@as(u64, started) << 32) ^ build;
    allocators[0] = std.heap.FixedBufferAllocator.init(memory.catalog_a.cachedSlice(u8));
    allocators[1] = std.heap.FixedBufferAllocator.init(memory.catalog_b.cachedSlice(u8));
}

pub fn now() u64 {
    return clocks.sample(x.Timer.now());
}

pub fn event(kind: portable.Kind, values: [12]u32) void {
    log.record(.{ .kind = kind, .ticks = now(), .values = values });
}

pub fn failed(subsystem: u32, failure: anyerror) void {
    report.failure = @intFromError(failure);
    var fields: [12]u32 = @splat(0);
    fields[0] = subsystem;
    var name: [44]u8 = @splat(0);
    const text = @errorName(failure);
    @memcpy(name[0..@min(name.len, text.len)], text[0..@min(name.len, text.len)]);
    for (0..11) |i| fields[i + 1] = std.mem.readInt(u32, name[i * 4 ..][0..4], .little);
    event(.fault, fields);
}

pub fn attach(volume: *Volume) void {
    volume_ptr = volume;
    report.sectors = @intCast(volume.device.capacity_sectors);
    catalogue_file = null;
    log_file = null;
    committed = null;
    const block: *[512]u8 = @ptrCast(memory.storage_burst.uncachedSlice(u8).ptr);
    catalogue_file = managed.open(volume, ".gain/catalog.bin", .catalog, block) catch null;
    log_file = managed.open(volume, ".gain/diagnostics.bin", .diagnostics, block) catch null;
    if (log_file) |file| {
        var reader = volume.reader(file) catch return;
        var latest: ?portable.Cursor = null;
        const pages = (file.size - managed.prefix_bytes) / portable.page_bytes;
        for ([_]u32{ 512, 1024 }) |offset| {
            reader.seekTo(offset) catch continue;
            if ((reader.read(block) catch 0) != 512) continue;
            if (portable.cursorDecode(block, pages)) |cursor| {
                if (latest == null or cursor.sequence > latest.?.sequence) latest = cursor;
            }
        }
        if (latest) |cursor| {
            log_page = cursor.page;
            log.sequence = @max(log.sequence, cursor.sequence);
        } else log_page = 0;
    }
}

pub fn detached() void {
    volume_ptr = null;
    catalogue_file = null;
    log_file = null;
}

pub fn load(volume: *Volume) !bool {
    const file = catalogue_file orelse return false;
    const began = x.Timer.now();
    defer report.index_load_ticks = x.Timer.elapsed(began);
    const bank_bytes = (file.size - managed.prefix_bytes) / 2;
    var raw = try volume.reader(file);
    var candidates: [2]?store.Header = .{ null, null };
    const block: *[512]u8 = @ptrCast(memory.storage_burst.uncachedSlice(u8).ptr);
    for (0..2) |bank| {
        try raw.seekTo(@intCast(managed.prefix_bytes + bank * bank_bytes));
        if (try raw.read(block) == 512) candidates[bank] = store.parseHeader(block, @intCast(bank), bank_bytes);
    }
    const first: usize = if (candidates[1] != null and (candidates[0] == null or candidates[1].?.generation > candidates[0].?.generation)) 1 else 0;
    for ([_]usize{ first, first ^ 1 }) |bank| {
        const header = candidates[bank] orelse continue;
        if (header.source != volume.serial) continue;
        const target: u1 = current_slot ^ 1;
        allocators[target].reset();
        var arena = std.heap.ArenaAllocator.init(allocators[target].allocator());
        raw = try volume.reader(file);
        try raw.seekTo(managed.prefix_bytes + @as(u32, @intCast(bank)) * bank_bytes + 512);
        var input = CatalogueInput{ .raw = raw, .position = raw.position };
        const buffers = memory.storage_burst.uncachedSlice(u8);
        const half = buffers.len / 2;
        var buffered = try @import("f20_storage.zig").ReadAheadReader(CatalogueInput).init(&input, .{ buffers[0..half], buffers[half..] });
        var reader = CheckedReader(@TypeOf(buffered)){ .inner = &buffered, .remaining = header.length };
        var limits: codec.Limits = .{};
        const value = codec.decode(library.Catalog, &reader, arena.allocator(), &limits) catch {
            arena.deinit();
            continue;
        };
        if (reader.remaining != 0 or reader.crc.final() != header.checksum or value.source != volume.serial or value.generation != header.generation) {
            arena.deinit();
            continue;
        }
        codec.validate(&value, allocators[target].allocator()) catch {
            arena.deinit();
            continue;
        };
        if (catalog) |*old| old.deinit();
        catalog = .{ .arena = arena, .value = value };
        current_slot = target;
        committed = header;
        report.index_tracks = @intCast(value.tracks.len);
        report.index_albums = @intCast(value.albums.len);
        return true;
    }
    return false;
}

// Decoding scalar fields must consume prefetched RAM, not reread an SD sector
// for every integer. Service USB between bounded bulk reads before SD ownership
// can change; no USB work runs inside a controller transaction.
const CatalogueInput = struct {
    raw: Volume.Reader,
    position: u32,

    pub fn read(self: *@This(), output: []u8) !usize {
        x.Watchdog.kick();
        usb.poll();
        if (usb.needsHandoff()) return error.Cancelled;
        const count = try self.raw.read(output);
        self.position = self.raw.position;
        return count;
    }
};

fn CheckedReader(comptime R: type) type {
    return struct {
        inner: *R,
        remaining: u32,
        crc: std.hash.Crc32 = std.hash.Crc32.init(),

        pub fn read(self: *@This(), out: []u8) !usize {
            const n = try self.inner.read(out[0..@min(out.len, self.remaining)]);
            self.remaining -= @intCast(n);
            self.crc.update(out[0..n]);
            return n;
        }
    };
}

pub fn scan(volume: *Volume, hooks: native.Hooks, mode: library.Mode) !void {
    const began = x.Timer.now();
    const io_before = volume.device.counters;
    report.failure = 0;
    report.stage = 1;
    defer report.stage = 0;
    const target: u1 = current_slot ^ 1;
    allocators[target].reset();
    var scratch = std.heap.FixedBufferAllocator.init(memory.compressed_ring.cachedSlice(u8));
    var backend = native.Backend.init(volume, hooks, scratch.allocator());
    defer backend.deinit();
    var empty = library.Catalog{};
    const old = if (catalog) |*previous| &previous.value else &empty;
    var next = try library.scanWithScratch(allocators[target].allocator(), scratch.allocator(), &backend, old, mode, &backend);
    errdefer next.deinit();
    if (stack_painted) {
        const stack = @import("task_stack.zig");

        const bytes = memory.boot_stack.cachedSlice(u8);
        if (!stack.intact(bytes)) return error.StackOverflow;
        report.index_stack_used = @intCast(stack.used(bytes));
    }
    if (committed) |header| next.value.generation = @max(next.value.generation, header.generation + 1);
    report.index_tracks = @intCast(next.value.tracks.len);
    report.index_albums = @intCast(next.value.albums.len);
    report.index_parsed = next.value.stats.parsed;
    report.index_reused = next.value.stats.reused;
    report.index_errors = next.value.stats.errors;
    report.index_heap = @intCast(next.bytes());
    report.index_bytes = @intCast(backend.metrics.source_bytes);
    report.index_metadata_ticks = @intCast(backend.metrics.metadata_ticks);
    report.index_artwork_ticks = @intCast(backend.metrics.artwork_ticks);
    report.index_directory_ticks = @intCast(backend.metrics.enumeration_ticks);
    report.art_prepared = backend.metrics.art_prepared;
    report.art_reused = backend.metrics.art_reused;
    report.index_ticks = x.Timer.elapsed(began);
    report.index_runs += 1;
    if (catalogue_file) |file| {
        const writing = x.Timer.now();
        var writer = try volume.overwrite(file);
        const previous_bank = committed;
        committed = store.save(&writer, &next.value, previous_bank, (file.size - managed.prefix_bytes) / 2, memory.storage_burst.uncachedSlice(u8)) catch |err| no_cache: {
            failed(2, err);
            break :no_cache previous_bank;
        };
        report.index_save_ticks = x.Timer.elapsed(writing);
    }
    if (catalog) |*previous| previous.deinit();
    catalog = next;
    current_slot = target;
    const io = volume.device.counters;
    report.index_read_sectors = @intCast(io.read_sectors - io_before.read_sectors);
    report.index_written_sectors = @intCast(io.write_sectors - io_before.write_sectors);
    report.index_io_ticks = @truncate(io.ticks - io_before.ticks);
    report.index_io_failures = io.failures - io_before.failures;
    recordIndex(.{
        .stats = next.value.stats,
        .metrics = backend.metrics,
        .reads = io.reads - io_before.reads,
        .writes = io.writes - io_before.writes,
        .bus_hz = volume.device.bus_hz,
        .scratch_bytes = @intCast(scratch.end_index),
        .verify = mode == .verify,
    });
}

pub const IndexSummary = struct {
    stats: library.Stats = .{},
    metrics: native.Metrics = .{},
    reads: u32 = 0,
    writes: u32 = 0,
    bus_hz: u32 = 0,
    scratch_bytes: u32 = 0,
    verify: bool = false,
};

/// Emit one bounded set of summaries after storage/playback ownership joins.
pub fn recordIndex(summary: IndexSummary) void {
    event(.library, .{
        report.index_ticks,
        report.index_tracks,
        report.index_albums,
        report.index_parsed,
        report.index_reused,
        report.index_errors,
        report.index_bytes,
        report.index_heap,
        report.index_load_ticks,
        report.index_save_ticks,
        report.art_prepared,
        report.art_reused,
    });
    event(.library_phases, .{
        report.index_directory_ticks,
        report.index_metadata_ticks,
        report.index_artwork_ticks,
        summary.metrics.metadata_max,
        summary.metrics.artwork_max,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
    });
    event(.library_io, .{
        report.index_read_sectors,
        report.index_written_sectors,
        summary.reads,
        summary.writes,
        report.index_io_ticks,
        report.index_io_failures,
        summary.bus_hz,
        summary.scratch_bytes,
        report.index_heap,
        report.index_stack_used,
        0,
        0,
    });
    const changes = summary.stats;
    event(.library_changes, .{
        changes.added,
        changes.changed,
        changes.renamed,
        changes.removed,
        changes.errors,
        @intFromBool(summary.verify),
        0,
        0,
        0,
        0,
        0,
        0,
    });
}

pub fn flush() void {
    const volume = volume_ptr orelse return;
    const file = log_file orelse return;
    if (report.stage == 2 or (!usb.session().playerAllowed() and !usb.needsHandoff())) return;
    if (log.count == 0) return;
    const pages = (file.size - managed.prefix_bytes) / portable.page_bytes;
    const block: *[portable.page_bytes]u8 = @ptrCast(memory.storage_burst.uncachedSlice(u8).ptr);
    var writer = volume.overwrite(file) catch return;
    var budget: usize = 8;
    while (log.count != 0 and budget != 0) : (budget -= 1) {
        const n = log.page(block, build, session);
        writer.seekTo(managed.prefix_bytes + (log_page % pages) * portable.page_bytes) catch |err| {
            disableLog(err);
            return;
        };
        writer.write(block) catch |err| {
            disableLog(err);
            return;
        };
        writer.sync() catch |err| {
            disableLog(err);
            return;
        };
        log.committed(n);
        log_page = (log_page + 1) % pages;
        report.log_pages += 1;
    }
    portable.cursorEncode(.{ .sequence = log.sequence, .page = log_page }, @ptrCast(block));
    // Alternate cursors; never rewrite the immutable provisioning header.
    writer.seekTo(512 + @as(u32, @intCast(log.sequence & 1)) * 512) catch |err| {
        disableLog(err);
        return;
    };
    writer.write(block[0..512]) catch |err| {
        disableLog(err);
        return;
    };
    writer.sync() catch |err| {
        disableLog(err);
        return;
    };
    report.log_dropped = log.dropped +| log.suppressed_faults;
}

fn disableLog(failure: anyerror) void {
    log_file = null;
    report.log_failures += 1;
    failed(3, failure);
}

pub fn samplePower(pmic: *@import("f20_power.zig").Controller) void {
    const ticks = now();
    if (ticks - last_power < x.Timer.milliseconds(10_000)) return;
    last_power = ticks;
    const telemetry = pmic.telemetry() catch |err| {
        report.power_valid = 0;
        report.coulomb_running = 0;
        previous_coulomb = null;
        if (err == error.UnstableAdc) {
            report.power_valid = 0;
            report.power_samples_dropped += 1;
            return;
        }
        failed(4, err);
        return;
    };
    report.battery_mv = telemetry.battery_mv orelse 0;
    report.charge_ua = telemetry.charge_microamps orelse 0;
    report.discharge_ua = telemetry.discharge_microamps orelse 0;
    report.usb_mv = telemetry.usb_mv orelse 0;
    report.usb_ua = telemetry.usb_microamps orelse 0;
    report.power_valid = @as(u32, @intFromBool(telemetry.battery_mv != null)) |
        (@as(u32, @intFromBool(telemetry.charge_microamps != null)) << 1) |
        (@as(u32, @intFromBool(telemetry.usb_microamps != null)) << 2) |
        (@as(u32, @intFromBool(telemetry.status.usb_present)) << 3) |
        (@as(u32, @intFromBool(telemetry.status.battery_present)) << 4) |
        (@as(u32, @intFromBool(telemetry.status.charging)) << 5) |
        (@as(u32, @intFromBool(telemetry.status.usb_usable)) << 6) |
        (@as(u32, @intFromBool(telemetry.status.over_temperature)) << 7) |
        (@as(u32, @intFromBool(telemetry.usb_mv != null)) << 8);
    const counter = pmic.coulomb() catch null;
    if (counter) |value| {
        report.coulomb_charge = value.charge;
        report.coulomb_discharge = value.discharge;
        report.adc_rate = value.rate_hz;
        report.coulomb_running = @intFromBool(value.running);
        if (previous_coulomb) |previous| if (value.deltaMicroampHours(previous)) |delta| {
            const seconds = (ticks - power_since) / x.Timer.milliseconds(1000);
            const max_counts = (@as(u64, value.rate_hz) * seconds * 8191) / 65536 + 2;
            if (value.charge -% previous.charge <= max_counts and value.discharge -% previous.discharge <= max_counts) {
                report.charge_uah +|= @intCast(delta.charge);
                report.discharge_uah +|= @intCast(delta.discharge);
                report.battery_energy_uwh +|= @intCast(delta.discharge * report.battery_mv / 1000);
            }
        };
        previous_coulomb = value;
        power_since = ticks;
    } else {
        previous_coulomb = null;
        report.coulomb_running = 0;
    }
    if (ticks - last_health >= x.Timer.milliseconds(60_000)) {
        last_health = ticks;
        event(.power, .{
            report.battery_mv,
            report.charge_ua,
            report.discharge_ua,
            report.usb_mv,
            report.usb_ua,
            report.power_valid,
            report.coulomb_charge,
            report.coulomb_discharge,
            report.adc_rate,
            report.coulomb_running,
            0,
            0,
        });
    }
}

pub fn playback(value: @import("f20_player.zig").Report) void {
    report.ui_stack_used = value.stack_used[1];
    report.control_ticks = @truncate(value.runtime.task_ticks[2]);
    report.ui_task_ticks = @truncate(value.runtime.task_ticks[1]);
    report.storage_task_ticks = @truncate(value.runtime.task_ticks[4]);
    report.live_storage_stack = value.stack_used[4];
    report.codec_ticks = @truncate(value.runtime.task_ticks[3]);
    report.idle_ticks = @truncate(value.runtime.task_ticks[5]);
    report.played_frames = @truncate(value.played_frames);
    report.playback_runs += 1;
    report.playback_frames = @truncate(value.playback.frames);
    report.underruns += value.playback.underruns;
    report.startup_ticks = value.startup_ticks;
    report.fill_ticks = value.worst_fill_ticks;
    report.ui_ticks = value.maximum_ui_ticks;
    report.ui_gap_ticks = value.maximum_ui_gap_ticks;
    report.irq_ticks = value.runtime.maximum_handler_ticks;
    var task_values: [12]u32 = undefined;
    for (value.runtime.task_ticks, 0..) |ticks, i| {
        task_values[i * 2] = @truncate(ticks);
        task_values[i * 2 + 1] = @truncate(ticks >> 32);
    }
    event(.task_times, task_values);
    event(.playback, .{
        value.playback.sample_rate,
        @truncate(value.playback.frames),
        value.periods,
        value.playback.underruns,
        value.playback.minimum_fifo_level,
        value.startup_ticks,
        value.worst_fill_ticks,
        value.maximum_ui_ticks,
        value.maximum_ui_gap_ticks,
        value.runtime.maximum_handler_ticks,
        value.heap_peak,
        @backingInt(value.playback.exit),
    });
}

pub fn booted() void {
    if (boot_recorded) return;
    boot_recorded = true;
    report.boot_ticks = x.Timer.elapsed(started);
    event(.boot, .{ report.boot_ticks, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
}

// Called only after prior playback workers have joined or by its sole storage
// owner. The live catalogue remains pinned until finishBackground runs outside
// the executive, including the metadata used by Now Playing.
pub fn backgroundAllocator() std.mem.Allocator {
    const target = current_slot ^ 1;
    allocators[target].reset();
    return allocators[target].allocator();
}

pub fn finishBackground(next: library.Owned) void {
    if (catalogue_file) |file| if (volume_ptr) |volume| {
        const began = x.Timer.now();
        if (volume.overwrite(file)) |raw| {
            var writer = raw;
            committed = store.save(&writer, &next.value, committed, (file.size - managed.prefix_bytes) / 2, memory.scan_io.uncachedSlice(u8)[0..65536]) catch |failure| failed_save: {
                failed(2, failure);
                break :failed_save committed;
            };
        } else |_| {}
        report.index_save_ticks = x.Timer.elapsed(began);
    };
    if (catalog) |*old| old.deinit();
    catalog = next;
    current_slot ^= 1;
}
