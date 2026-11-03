//! Host benchmarks of production algorithms. Synthetic inputs only; elapsed
//! host time does not model MIPS cycles, SD latency, LCD scanout or battery use.
const std = @import("std");
const gain = @import("gain");
const ui = gain.ui_api;
const core = ui.library;
const trials = 9;
const host_allocator = std.heap.c_allocator;

const Result = struct {
    name: []const u8,
    items: usize,
    repetitions: usize,
    p50_ns: u64,
    p95_ns: u64,
    min_ns: u64,
    checksum: u64,
};

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn measure(io: std.Io, writer: *std.Io.Writer, name: []const u8, items: usize, repetitions: usize, context: anytype, comptime operation: anytype) !void {
    var samples: [trials]u64 = undefined;
    var checksum: u64 = 0;
    _ = try operation(context, 0);
    for (&samples) |*sample| {
        const start = now(io);
        for (0..repetitions) |i| checksum +%= try operation(context, i);
        sample.* = @intCast(now(io) - start);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.mem.doNotOptimizeAway(checksum);
    try std.json.Stringify.value(Result{
        .name = name,
        .items = items,
        .repetitions = repetitions,
        .p50_ns = samples[trials / 2] / repetitions,
        .p95_ns = samples[trials - 1] / repetitions,
        .min_ns = samples[0] / repetitions,
        .checksum = checksum,
    }, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tracks: []core.Track,
    entries: []core.Entry,
    view: *ui.progressive_view.Snapshot,
    baseline: core.Owned,
    metadata_calls: usize = 0,

    fn init(count: usize, tracks_per_album: usize) !Fixture {
        var arena = std.heap.ArenaAllocator.init(host_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const tracks = try a.alloc(core.Track, count);
        const entries = try a.alloc(core.Entry, count);
        for (tracks, entries, 0..) |*track, *entry, i| {
            const album = i / tracks_per_album;
            const artist = try std.fmt.allocPrint(a, "Synthetic Artist {d:0>3}", .{album % 32});
            const title = try std.fmt.allocPrint(a, "Synthetic Album {d:0>4}", .{album});
            const path = try std.fmt.allocPrint(a, "Music/{s}/{s}/{d:0>4}.flac", .{ artist, title, i });
            const stamp = core.Stamp{ .size = 200000, .modified = 1, .device = 1, .inode = i + 1 };
            track.* = .{
                .id = i + 1,
                .path = path,
                .stamp = stamp,
                .meta = .{
                    .title = try std.fmt.allocPrint(a, "Synthetic Song {d}", .{(count - i) % count}),
                    .artist = artist,
                    .album_artist = artist,
                    .album = title,
                    .disc = @intCast(i % tracks_per_album / 12 + 1),
                    .track = @intCast(i % 12 + 1),
                    .codec = "flac",
                    .sample_rate = 48000,
                    .duration_ms = 180000,
                },
            };
            entry.* = .{ .path = path, .kind = .audio, .stamp = stamp };
        }
        std.mem.sort(core.Entry, entries, {}, struct {
            fn less(_: void, left: core.Entry, right: core.Entry) bool {
                return std.mem.order(u8, left.path, right.path) == .lt;
            }
        }.less);
        const view = try a.create(ui.progressive_view.Snapshot);
        var result = Fixture{ .arena = arena, .tracks = tracks, .entries = entries, .view = view, .baseline = undefined };
        result.baseline = try core.scan(host_allocator, &result, &.{}, .quick, &Observer{});
        return result;
    }

    fn deinit(self: *Fixture) void {
        self.baseline.deinit();
        self.arena.deinit();
    }

    pub fn enumerate(self: *Fixture, a: std.mem.Allocator) !core.Enumeration {
        return .{ .source = 1, .entries = try core.clone(a, self.entries) };
    }

    pub fn metadata(self: *Fixture, a: std.mem.Allocator, entry: core.Entry) !core.Metadata {
        self.metadata_calls += 1;
        return core.clone(a, self.tracks[entry.stamp.inode - 1].meta);
    }

    pub fn artwork(_: *Fixture, _: std.mem.Allocator, _: core.Album, _: []const core.Track, _: []const core.Entry, _: ?core.Artwork, _: core.Mode) !core.Artwork {
        return .{};
    }

    pub fn playlist(_: *Fixture, _: std.mem.Allocator, _: []const u8, _: []const core.Track) !core.Playlist {
        return error.NoPlaylist;
    }
};

const Observer = struct {
    pub fn cancelled(_: *const @This()) bool {
        return false;
    }

    pub fn progress(_: *const @This(), _: []const u8, _: core.Stats, _: u32) void {}
};

fn projection(fixture: *Fixture, iteration: usize) !u64 {
    try fixture.view.build(&fixture.baseline.value, fixture.baseline.value.tracks, 1, true, @intCast(iteration));
    std.mem.doNotOptimizeAway(fixture.view);
    return fixture.view.tracks[fixture.view.artist_track_order[fixture.tracks.len - 1]].id;
}

fn coldScan(fixture: *Fixture, _: usize) !u64 {
    var result = try core.scan(host_allocator, fixture, &.{}, .quick, &Observer{});
    defer result.deinit();
    return result.value.tracks.len + result.value.albums.len;
}

fn warmScan(fixture: *Fixture, _: usize) !u64 {
    const before = fixture.metadata_calls;
    var result = try core.scan(host_allocator, fixture, &fixture.baseline.value, .quick, &Observer{});
    defer result.deinit();
    if (fixture.metadata_calls != before) return error.UnexpectedMetadataRead;
    return result.value.stats.reused + result.value.albums.len;
}

var pixels: [320 * 240]u16 = undefined;
var packed_pixels: [320 * 240]u16 align(4) = undefined;
var frames: [4096]gain.pcm_reservoir.StereoFrame = undefined;
var audio_bytes: [1920 * 8]u8 align(4) = undefined;
var prepared: ui.cover_flow.Prepared = undefined;
var art: [112 * 112]u16 = undefined;

fn text(_: void, iteration: usize) !u64 {
    const c = ui.canvas.Canvas.init(&pixels);
    c.clear(@truncate(iteration));
    const labels = [_][]const u8{ "A long synthetic album title with mixed punctuation — and more text", "Café music • 2026 edition", "Synthetic Artist", "0123456789 / 0123456789", "á…artist’s song", "A deliberately longer piece of synthetic metadata to be truncated" };
    for (labels, 0..) |label, i| c.ellipsis(-3 + @as(i32, @intCast(iteration % 8)), @intCast(i * 32), 288, label, .reading, 0x1234);
    std.mem.doNotOptimizeAway(&pixels);
    return pixels[10000];
}

fn flow(_: void, iteration: usize) !u64 {
    @memset(&pixels, ui.cover_flow.background);
    var cards: [7]ui.cover_flow.Card = undefined;
    const phase = @as(f32, @floatFromInt(iteration % 60)) / 60;
    for ([_]i32{ -3, 3, -2, 2, -1, 1, 0 }, &cards) |offset, *card| card.* = .{ .texture = &prepared, .quad = ui.cover_flow.project(@as(f32, @floatFromInt(offset)) - phase) };
    ui.cover_flow.paintScene(.{ .pixels = &pixels }, &cards);
    std.mem.doNotOptimizeAway(&pixels);
    return pixels[(iteration * 23) % pixels.len];
}

fn prepare(_: void, _: usize) !u64 {
    ui.cover_flow.prepare(.{ .pixels = &art, .width = 112, .height = 112 }, &prepared);
    std.mem.doNotOptimizeAway(&prepared);
    return prepared.pixels[213];
}

fn pack(_: void, iteration: usize) !u64 {
    try ui.presentation.pack(&pixels, 320, 240, .{ .x = 0, .y = 0, .width = 320, .height = 240 }, &packed_pixels);
    std.mem.doNotOptimizeAway(&packed_pixels);
    return packed_pixels[iteration % packed_pixels.len];
}

fn output(context: bool, iteration: usize) !u64 {
    var ring = try gain.pcm_reservoir.Ring.initFilled(&frames, frames.len);
    ring.consumer_index = iteration % 3000;
    ring.producer_index = ring.consumer_index;
    var quantizer = gain.pcm.Sample.Quantizer{};
    const plan = try gain.audio_output.Plan.init(192000, .signed_24_in_u32);
    const rendered = if (context) try gain.audio_output.renderPeriodDithered(&ring, &audio_bytes, plan, gain.audio_output.unity_gain_q24, &quantizer) else try gain.audio_output.renderPeriod(&ring, &audio_bytes, plan, gain.audio_output.unity_gain_q24);
    std.mem.doNotOptimizeAway(&audio_bytes);
    return rendered.frames + audio_bytes[iteration % audio_bytes.len];
}

var packet: [65536 + 64]u8 = undefined;
var page: [65025]u8 = undefined;
var floats: [16384]f32 = undefined;
var converted: [8192]gain.pcm_reservoir.StereoFrame = undefined;
var codec_arena: [512 * 1024]u8 align(16) = undefined;
var cache: [65536]u8 = undefined;
var compressed: [256 * 1024]u8 = undefined;
var decode_left: [65535]i32 = undefined;
var decode_right: [65535]i32 = undefined;
var encoded: [12 * 1024 * 1024]u8 = undefined;
var scratch_bytes: [8 * 1024 * 1024]u8 = undefined;

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn seekTo(self: *Reader, at: u32) !void {
        if (at > self.bytes.len) return error.SeekBounds;
        self.position = at;
    }

    pub fn read(self: *Reader, destination: []u8) !usize {
        const n = @min(destination.len, self.bytes.len - self.position);
        @memcpy(destination[0..n], self.bytes[self.position..][0..n]);
        self.position += n;
        return n;
    }
};

const Sink = struct {
    frames: usize = 0,
    checksum: u64 = 0,

    pub fn configure(_: *Sink, _: gain.media_info.Information) !void {}

    pub fn push(self: *Sink, data: []const gain.pcm_reservoir.StereoFrame) !void {
        self.frames += data.len;
        if (data.len != 0) self.checksum +%= @as(u32, @bitCast(data[0].left)) +% @as(u32, @bitCast(data[data.len - 1].right));
    }
};

fn decode(case: @import("fixtures").Case, _: usize) !u64 {
    var reader = Reader{ .bytes = case.bytes };
    var pool = try gain.codec_pool.Pool.init(&codec_arena);
    var sink = Sink{};
    _ = try gain.media_decoder.run(&reader, case.bytes.len, Sink, &sink, .{
        .packet = .{ .packet = &packet, .page = &page, .pcm = &floats, .frames = &converted, .pool = &pool },
        .cache = &cache,
        .compressed = &compressed,
        .left = &decode_left,
        .right = &decode_right,
    }, 0);
    if (sink.frames != case.frames or pool.statistics.live != 0) return error.DecodeMismatch;
    return sink.checksum;
}

const Buffer = struct {
    position: usize = 0,

    pub fn write(self: *Buffer, bytes: []const u8) !void {
        if (bytes.len > encoded.len - self.position) return error.BufferLimit;
        @memcpy(encoded[self.position..][0..bytes.len], bytes);
        self.position += bytes.len;
    }
};

fn encodeCatalog(fixture: *Fixture, _: usize) !u64 {
    var buffer = Buffer{};
    try ui.catalog_codec.encode(&buffer, fixture.baseline.value);
    std.mem.doNotOptimizeAway(&encoded);
    return buffer.position;
}

fn decodeCatalog(length: usize, _: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(host_allocator);
    defer arena.deinit();
    var reader = Reader{ .bytes = encoded[0..length] };
    var limits = ui.catalog_codec.Limits{};
    const value = try ui.catalog_codec.decode(core.Catalog, &reader, arena.allocator(), &limits);
    try ui.catalog_codec.validate(&value, arena.allocator());
    return value.tracks.len + value.albums.len;
}

const Scratch = struct {
    inner: std.heap.FixedBufferAllocator,
    peak: usize = 0,

    fn allocator(self: *Scratch) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }

    fn allocate(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.alloc(&self.inner, length, alignment, address);
        self.peak = @max(self.peak, self.inner.end_index);
        return result;
    }

    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, address: usize) bool {
        const self: *Scratch = @ptrCast(@alignCast(context));
        const result = std.heap.FixedBufferAllocator.resize(&self.inner, bytes, alignment, length, address);
        self.peak = @max(self.peak, self.inner.end_index);
        return result;
    }

    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, length: usize, address: usize) ?[*]u8 {
        return if (resize(context, bytes, alignment, length, address)) bytes.ptr else null;
    }

    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Scratch = @ptrCast(@alignCast(context));
        std.heap.FixedBufferAllocator.free(&self.inner, bytes, alignment, address);
    }
};

fn resourceUse(writer: *std.Io.Writer, fixture: *Fixture, warm: bool) !void {
    var scratch = Scratch{ .inner = std.heap.FixedBufferAllocator.init(&scratch_bytes) };
    var result = try core.scanWithScratch(host_allocator, scratch.allocator(), fixture, if (warm) &fixture.baseline.value else &.{}, .quick, &Observer{});
    defer result.deinit();
    try std.json.Stringify.value(.{ .name = if (warm) "scan_warm_memory_usage" else "scan_cold_memory_usage", .items = fixture.tracks.len, .scratch_peak_bytes = scratch.peak, .catalogue_bytes = result.bytes() }, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

// Keep the original full-card search here as a performance reference. Its
// observable selection is also compared with the bounded production lookup.
const SidecarContext = struct { fixture: *Fixture, reference: bool };

fn sidecar(context: SidecarContext, iteration: usize) !u64 {
    const album = context.fixture.baseline.value.albums[iteration % context.fixture.baseline.value.albums.len];
    const entries = context.fixture.entries;
    const chosen = if (context.reference) reference: {
        for ([_][]const u8{ "cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.png" }) |name| {
            for (entries) |entry| if (entry.kind == .artwork and std.mem.eql(u8, std.fs.path.dirname(entry.path) orelse "", album.directory) and std.ascii.eqlIgnoreCase(std.fs.path.basename(entry.path), name)) break :reference entry;
        }
        break :reference @as(?core.Entry, null);
    } else core.sidecarArtwork(entries, album.directory);
    return if (chosen) |entry| core.hash(entry.path) else 0;
}

pub fn main(init: std.process.Init) !void {
    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &stdout.interface;
    for ([_]usize{ 128, 1024, 8192 }) |count| {
        var fixture = try Fixture.init(count, 16);
        defer fixture.deinit();
        try measure(init.io, writer, "projection", count, 3, &fixture, projection);
        try measure(init.io, writer, "scan_cold_memory", count, 2, &fixture, coldScan);
        try measure(init.io, writer, "scan_warm_memory", count, 2, &fixture, warmScan);
        try resourceUse(writer, &fixture, false);
        try resourceUse(writer, &fixture, true);
        if (count == 8192) {
            try measure(init.io, writer, "catalogue_encode", count, 3, &fixture, encodeCatalog);
            try measure(init.io, writer, "catalogue_decode_validate", count, 3, @as(usize, @intCast(try encodeCatalog(&fixture, 0))), decodeCatalog);
            const old_entries = fixture.entries;
            fixture.entries = try fixture.arena.allocator().alloc(core.Entry, count + fixture.baseline.value.albums.len / 2);
            @memcpy(fixture.entries[0..count], old_entries);
            for (fixture.baseline.value.albums[0 .. fixture.baseline.value.albums.len / 2], fixture.entries[count..]) |album, *entry| entry.* = .{ .kind = .artwork, .path = try std.fmt.allocPrint(fixture.arena.allocator(), "{s}/folder.png", .{album.directory}) };
            std.mem.sort(core.Entry, fixture.entries, {}, struct {
                fn less(_: void, a: core.Entry, b: core.Entry) bool {
                    return std.mem.order(u8, a.path, b.path) == .lt;
                }
            }.less);
            try measure(init.io, writer, "sidecar_full_card_reference", count, 512, SidecarContext{ .fixture = &fixture, .reference = true }, sidecar);
            try measure(init.io, writer, "sidecar_album_subtree", count, 512, SidecarContext{ .fixture = &fixture, .reference = false }, sidecar);
        }
    }
    var skew = try Fixture.init(8192, 8192);
    defer skew.deinit();
    try measure(init.io, writer, "projection_one_album", 8192, 3, &skew, projection);
    for (&art, 0..) |*pixel, i| pixel.* = @truncate(i *% 31337 +% i / 112);
    for (&frames, 0..) |*frame, i| frame.* = .{ .left = @bitCast(@as(u32, @truncate(i *% 982451653))), .right = @bitCast(@as(u32, @truncate(i *% 32452843))) };
    _ = try prepare({}, 0);
    try measure(init.io, writer, "text_six_rows", 6, 500, {}, text);
    try measure(init.io, writer, "cover_flow_seven_textures", 7, 200, {}, flow);
    try measure(init.io, writer, "artwork_prepare", 112 * 112, 100, {}, prepare);
    try measure(init.io, writer, "pack_full_frame", pixels.len, 1000, {}, pack);
    try measure(init.io, writer, "pcm_192k_period", 1920, 1000, false, output);
    try measure(init.io, writer, "pcm_192k_dither_period", 1920, 1000, true, output);
    for (@import("fixtures").cases) |case| {
        const name = try std.fmt.allocPrint(host_allocator, "decode_{s}", .{case.name});
        defer host_allocator.free(name);
        try measure(init.io, writer, name, case.frames, 3, case, decode);
    }
}
