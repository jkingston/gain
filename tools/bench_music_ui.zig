//! Production UI workloads with resident synthetic artwork. No storage or
//! device timing is emulated; the enclosing benchmark measures host CPU work.
const std = @import("std");
const ui = @import("gain").ui_api;
const core = ui.library;

const Platform = struct {
    pub fn now() u32 {
        return 0;
    }

    pub fn trace(_: anytype, _: u32, _: u32) void {}

    pub const Index = struct {
        pub const State = struct {
            projection: *ui.progressive_view.Pair,
            phase: []const u8 = "Reading tags",

            pub fn request(_: *@This(), _: bool) void {}
        };
    };

    pub const Display = struct {
        pub const Frozen = ui.presentation.Region;
    };

    pub const Diagnostics = struct {
        pub var catalog: ?struct { value: core.Catalog } = null;
        pub var report: struct {
            failure: u32 = 0,
            scan_active: u32 = 0,
            scan_total: u32 = 0,
            scan_visited: u32 = 0,
            selected_album_low: u32 = 0,
            selected_album_high: u32 = 0,
            selected_album_rank: u32 = 0,
            ui_animation_frames: u32 = 0,
            ui_animation_gap_max: u32 = 0,
            ui_animation_slow: u32 = 0,
            ui_draw_max: u32 = 0,
            ui_drawn: u32 = 0,
            cover_header_max: u32 = 0,
            cover_scene_max: u32 = 0,
            cover_caption_max: u32 = 0,
        } = .{};
    };
};

pub const Scene = struct {
    pair: ui.progressive_view.Pair = .{},
    cache: ui.cover_cache.Cache = .{},
    index: Platform.Index.State = undefined,
    work: ui.cover_cache.Cache.WorkQueue = .{},
    state: ui.music_ui.Controller(Platform) = undefined,
    track_memory: [8192]u8 = undefined,
    pixels: [320 * 240]u16 = undefined,

    pub fn init(self: *Scene, catalog: *const core.Catalog, tile: *const ui.cover_flow.Prepared) !void {
        self.* = .{};
        try self.pair.publish(catalog, catalog.tracks, catalog.source, true);
        self.index = .{ .projection = &self.pair };
        self.state = .{ .index = &self.index, .covers = &self.cache, .track_store = .init(&self.track_memory) };
        self.state.navigate(.albums);
        self.state.selection = 4;
        self.state.flow = 4;
        for (self.pair.current().albums[0..self.pair.current().album_count], 0..) |album, slot| {
            if (slot >= ui.cover_cache.Cache.slots) break;
            const load = ui.cover_cache.Cache.Load{ .slot = slot, .request = .{ .id = album.id, .art = album.art } };
            self.cache.begin(load);
            self.cache.tiles[slot] = tile.*;
            self.cache.publish(load);
        }
        self.state.renderInto(&self.pixels, 0);
    }

    pub fn moving(self: *Scene, iteration: usize) !u64 {
        Platform.Diagnostics.report.scan_active = 0;
        self.state.flow = 3.5 + @as(f32, @floatFromInt(iteration % 60)) / 60;
        self.state.renderInto(&self.pixels, iteration * 17);
        std.mem.doNotOptimizeAway(&self.pixels);
        return self.pixels[100 * 320 + 160];
    }

    pub fn scanProgress(self: *Scene, iteration: usize) !u64 {
        Platform.Diagnostics.report.scan_active = 1;
        Platform.Diagnostics.report.scan_total = 8192;
        Platform.Diagnostics.report.scan_visited = @intCast(iteration * 32 % 8192);
        self.state.flow = 4;
        self.state.renderInto(&self.pixels, iteration * 17);
        std.mem.doNotOptimizeAway(&self.pixels);
        return self.pixels[100 * 320 + 160];
    }

    pub fn cachePoll(self: *Scene, _: usize) !u64 {
        const revision = self.cache.request_revision.load(.acquire);
        if (self.work.pending(revision)) {
            if (self.work.next(&self.cache, self.cache.requested, revision)) |load| return load.request.id;
        }
        std.mem.doNotOptimizeAway(&self.cache);
        return 0;
    }
};
