//! Shared music interaction, animation and rasterization. Platform supplies
//! presentation, indexing and diagnostics; rendering performs no storage I/O.
const std = @import("std");
const draw = @import("canvas.zig");

const C = draw.Canvas;
const core = @import("library.zig");
const views = @import("progressive_view.zig");
const covers = @import("cover_cache.zig");
const media = @import("f20_media.zig");
const flow_scene = @import("cover_flow.zig");

const paper = draw.rgb(247, 247, 242);
const ink = draw.rgb(31, 42, 44);
const muted = draw.rgb(102, 114, 113);
const line = draw.rgb(217, 222, 216);
const accent = draw.rgb(35, 101, 91);
const selected = draw.rgb(226, 234, 225);

pub const Input = enum(u3) { select, back, home, up, down, volume_up, volume_down };

pub const Screen = enum { home, albums, tracks, player, library };

/// Platform dependencies are resolved at compile time; no runtime dispatch is
/// added to drawing or presentation. See f20_music_ui.zig for the device adapter.
pub fn Controller(comptime Platform: type) type {
    const lcd = Platform.Display;
    const index = Platform.Index;
    const diag = Platform.Diagnostics;
    return struct {
        const State = @This();
        index: *index.State,
        covers: *covers.Cache,
        screen: Screen = .home,
        selection: usize = 0,
        first: usize = 0,
        album_id: u64 = 0,
        selected_id: u64 = 0,
        selected_track_anchor: u64 = 0,
        flow: f32 = 0,
        flow_at: u64 = 0,
        revision: u32 = 0,
        cover_revision: u32 = 0,
        track_store: @import("track_selection.zig").Store,
        requested_track: ?*const core.Track = null,
        requested_folders: bool = false,
        playing_track: ?*const core.Track = null,
        attenuation: u8 = 64,
        animation: @import("volume_transition.zig").Transition = .{},
        status: media.PlaybackStatus = .{
            .phase = .preparing,
            .sample_rate = 0,
            .output_format = .signed_24_in_u32,
            .total_frames = 0,
            .played_frames = 0,
        },
        dirty: bool = true,
        major: bool = true,
        pending_frame: @import("render_ahead.zig").State = .{},
        frozen: lcd.Frozen = undefined,
        last_submission: u64 = 0,
        continuous: bool = false,
        motion_flags: u32 = 0,
        last_second: u64 = 0,
        last_visited: u32 = 0,
        last_active: u32 = 0,
        battery_mv: u32 = 0,
        failure: bool = false,
        rendered_surface: usize = 0,
        rendered_screen: ?Screen = null,
        rendered_selection: usize = 0,
        rendered_revision: u32 = 0,
        rendered_count: usize = 0,
        rendered_battery: u32 = 0,
        rendered_scan_active: u32 = 0,
        rendered_scan_visited: u32 = 0,

        fn fail(self: *State, failure: anyerror) void {
            if (!self.failure) diag.report.failure = @intFromError(failure);
            self.failure = true;
        }

        fn benchmarkClock() u32 {
            return Platform.now();
        }

        pub fn snapshot(self: *const State) *const views.Snapshot {
            return self.index.projection.current();
        }

        pub fn queue(self: *State, track: *const core.Track) void {
            self.requested_track = self.track_store.queue(track) catch |failure| {
                self.fail(failure);
                return;
            };
        }

        pub fn navigate(self: *State, screen: Screen) void {
            self.screen = screen;
            self.rendered_screen = null;
            self.pending_frame.ready = false;
            self.selection = 0;
            self.first = 0;
            self.selected_id = 0;
            self.selected_track_anchor = 0;
            self.revision = 0;
            self.flow = 0;
            self.dirty = true;
            self.major = true;
        }

        fn trackAt(self: *const State, position: usize) ?*const core.Track {
            const view = self.snapshot();
            const album = view.albumIndex(self.album_id) orelse return null;
            var found: usize = 0;
            for (view.track_order[0..view.track_count]) |i| {
                const track = view.tracks[i];
                if (view.track_groups[i] != album) continue;
                if (found == position) return track;
                found += 1;
            }
            return null;
        }

        pub fn neighbouringTrack(self: *const State, direction: i2) ?*const core.Track {
            const current = self.playing_track orelse return null;
            const view = self.snapshot();
            for (view.track_order[0..view.track_count], 0..) |index_value, rank| {
                if (view.tracks[index_value].id != current.id) continue;
                const next = if (direction < 0) rank -| 1 else rank + 1;
                if (next == rank or next >= view.track_count) return null;
                const candidate = view.track_order[next];
                if (view.track_groups[candidate] != view.track_groups[index_value]) return null;
                return view.tracks[candidate];
            }
            return null;
        }

        fn rows(self: *const State) usize {
            return switch (self.screen) {
                .home => 4,
                .albums => self.snapshot().album_count,
                .tracks => if (self.snapshot().albumIndex(self.album_id)) |i| self.snapshot().albums[i].count else 0,
                .library => 2,
                .player => 0,
            };
        }

        pub fn handle(self: *State, event: Input, now: u64, playing: bool) media.PlaybackCommand {
            self.dirty = true;
            switch (event) {
                .volume_up, .volume_down => {
                    self.attenuation = if (event == .volume_up) self.attenuation -| 4 else @min(128, self.attenuation +| 4);
                    self.attenuation = @max(16, self.attenuation);
                    self.animation.request(now, @as(u32, 128 - self.attenuation) * 100 / 112);
                    return .{ .set_attenuation = self.attenuation };
                },
                .home => self.navigate(.home),
                .back => {
                    const album = if (self.screen == .tracks) self.snapshot().albumIndex(self.album_id) else null;
                    self.navigate(if (self.screen == .tracks) .albums else .home);
                    if (album) |rank| {
                        self.selection = rank;
                        self.flow = @floatFromInt(rank);
                        self.selected_id = self.snapshot().albums[rank].id;
                        self.selected_track_anchor = self.snapshot().albums[rank].representative.id;
                    }
                },
                .up, .down => {
                    if (self.screen == .player and playing) return if (event == .up) .previous else .next;
                    if (self.screen == .albums) self.advanceFlow(now);
                    const count = self.rows();
                    if (count > 0) self.selection = if (event == .up) self.selection -| 1 else @min(count - 1, self.selection + 1);
                    if (self.selection < self.first) self.first = self.selection;
                    if (self.selection >= self.first + 5) self.first = self.selection - 4;
                    if (self.screen == .albums and count > 0) {
                        self.selected_id = self.snapshot().albums[self.selection].id;
                        self.selected_track_anchor = self.snapshot().albums[self.selection].representative.id;
                    }
                    if (self.screen == .tracks) if (self.trackAt(self.selection)) |track| {
                        self.selected_id = track.id;
                    };
                },
                .select => switch (self.screen) {
                    .home => if (self.selection == 3) {
                        self.requested_folders = true;
                        if (playing) return .stop;
                    } else self.navigate(switch (self.selection) {
                        0 => .player,
                        1 => .albums,
                        else => .library,
                    }),
                    .albums => if (self.snapshot().album_count > 0) {
                        self.album_id = self.snapshot().albums[self.selection].id;
                        self.navigate(.tracks);
                    },
                    .tracks => if (self.trackAt(self.selection)) |track| {
                        self.queue(track);
                        self.navigate(.player);
                        if (playing) return .stop;
                    },
                    .player => if (playing) {
                        return .stop;
                    } else if (self.playing_track) |track| {
                        self.queue(track);
                    },
                    .library => self.index.request(self.selection == 1),
                },
            }
            return .none;
        }

        fn reconcile(self: *State) void {
            const view = self.snapshot();
            if (view.revision == self.revision) return;
            if (self.screen == .albums and self.selected_id != 0) {
                var target = view.albumIndex(self.selected_id);
                if (target == null and self.selected_track_anchor != 0) for (view.tracks[0..view.track_count], 0..) |track, i| {
                    if (track.id == self.selected_track_anchor) {
                        target = view.track_groups[i];
                        break;
                    }
                };
                if (target) |position| {
                    const delta = @as(f32, @floatFromInt(position)) - @as(f32, @floatFromInt(self.selection));
                    self.flow += delta;
                    self.selection = position;
                } else self.selection = @min(self.selection, view.album_count -| 1);
            }
            if (self.screen == .tracks) {
                const offset = self.selection -| self.first;
                var rank: usize = 0;
                for (view.tracks[0..view.track_count], 0..) |track, i| {
                    if (self.selected_id != 0 and track.id == self.selected_id) {
                        self.album_id = view.albums[view.track_groups[i]].id;
                        break;
                    }
                }
                if (view.albumIndex(self.album_id)) |album| {
                    for (view.track_order[0..view.track_count]) |i| {
                        const track = view.tracks[i];
                        if (view.track_groups[i] != album) continue;
                        if (track.id == self.selected_id) {
                            self.selection = rank;
                            break;
                        }
                        rank += 1;
                    }
                    self.selection = @min(self.selection, view.albums[album].count -| 1);
                    self.first = self.selection -| offset;
                    if (self.trackAt(self.selection)) |track| self.selected_id = track.id;
                }
            }
            self.revision = view.revision;
            self.dirty = true;
            if (self.screen == .albums and view.album_count > 0) {
                self.selected_id = view.albums[self.selection].id;
                self.selected_track_anchor = view.albums[self.selection].representative.id;
                diag.report.selected_album_low = @truncate(self.selected_id);
                diag.report.selected_album_high = @truncate(self.selected_id >> 32);
                diag.report.selected_album_rank = @intCast(self.selection);
            }
        }

        fn advanceFlow(self: *State, now: u64) void {
            // A retarget first advances the old destination to the event time.
            // Idle time never becomes time spent moving towards a new album.
            const elapsed: f32 = @floatFromInt(@min(1000, now -| self.flow_at));
            const target: f32 = @floatFromInt(self.selection);
            if (self.flow != target) self.flow += (target - self.flow) * (1 - @exp(-elapsed / 55));
            self.flow_at = now;
        }

        pub fn isAnimating(self: *const State, now: u64) bool {
            return (self.screen == .albums and @abs(self.flow - @as(f32, @floatFromInt(self.selection))) > 0.005) or self.animation.isAnimating(now);
        }

        pub fn refreshBattery(self: *State, millivolts: u32, now: u64) void {
            // A header-only change must not replace a region transfer during
            // the short volume fade. A stable volume hold can refresh normally.
            if (self.battery_mv == millivolts or (self.screen == .player and self.animation.isAnimating(now))) return;
            self.battery_mv = millivolts;
            self.dirty = true;
            self.major = true;
        }

        pub fn frame(self: *State, now: u64) void {
            self.reconcile();
            const defer_cosmetic = self.screen == .player and self.animation.isAnimating(now);
            if (!defer_cosmetic and self.covers.revision.load(.acquire) != self.cover_revision) {
                self.cover_revision = self.covers.revision.load(.acquire);
                self.dirty = true;
                self.major = true;
            }
            const volume_moving = self.animation.tick(now);
            if (volume_moving) self.dirty = true;
            if (!defer_cosmetic and self.last_active != diag.report.scan_active) {
                self.last_active = diag.report.scan_active;
                self.dirty = true;
                self.major = true;
            }
            if (self.last_visited != diag.report.scan_visited) {
                self.last_visited = diag.report.scan_visited;
                self.dirty = true;
            }
            if (self.screen == .player and self.last_second != self.status.played_frames / @max(1, self.status.sample_rate)) {
                self.last_second = self.status.played_frames / @max(1, self.status.sample_rate);
                self.dirty = true;
            }
            const moving = self.screen == .albums and @abs(self.flow - @as(f32, @floatFromInt(self.selection))) > 0.005;
            const motion_flags = @as(u32, @intFromBool(moving)) | (@as(u32, @intFromBool(volume_moving)) << 1);
            if (motion_flags != self.motion_flags) {
                self.motion_flags = motion_flags;
                Platform.trace(.motion, Platform.now(), motion_flags);
            }
            if (!moving and self.screen == .albums and self.flow != @as(f32, @floatFromInt(self.selection))) {
                self.flow = @floatFromInt(self.selection);
                self.dirty = true;
                self.major = true;
            }
            if (!moving and !volume_moving) self.continuous = false;
            if (moving) {
                self.dirty = true;
                self.major = true;
            }
            // DMA launch/completion polling has its own deadline. Never throttle it
            // to the animation cadence or a scan-synchronized region misses its slot.
            const busy = switch (lcd.poll()) {
                .busy => true,
                .failed => {
                    self.fail(lcd.last_failure orelse error.DisplayFailed);
                    return;
                },
                .idle => false,
            };
            var submitted = false;
            if (self.pending_frame.ready and !busy) {
                if (!self.submit(now)) return;
                submitted = true;
            }
            if (!self.pending_frame.dueAt(now, self.dirty, lcd.renderIntervalMs())) return;
            if (moving) self.advanceFlow(now);
            const draw_started = Platform.now();
            Platform.trace(.model, draw_started, (@as(u32, @intFromBool(moving)) << 31) | (@as(u32, @intFromBool(volume_moving)) << 30) | (@as(u32, @backingInt(self.screen)) << 27) | (@as(u32, @intCast(self.selection)) << 11) | @as(u32, @intCast(@min(2047, self.rows()))));
            Platform.trace(.flow, draw_started, @bitCast(self.flow));
            if (!self.major and self.screen == .player) self.renderTimelineInto(lcd.framebuffer, now) else self.render(now);
            const draw_ticks = Platform.now() -% draw_started;
            Platform.trace(.render, Platform.now(), draw_ticks);
            diag.report.ui_draw_max = @max(diag.report.ui_draw_max, draw_ticks);
            const full = self.major or self.screen != .player;
            self.frozen = lcd.freeze(if (full) .{ .x = 0, .y = 0, .width = 320, .height = 240 } else .{ .x = 0, .y = 188, .width = 320, .height = 42 }) catch |failure| {
                self.fail(failure);
                return;
            };
            self.pending_frame.rendered(now, full, moving or volume_moving);
            self.dirty = false;
            self.major = false;
            // Rendering may overlap DMA: that transfer reads its immutable copy.
            // Packing and changing panel commands still wait for its drain ACK.
            if (!busy and !submitted) _ = self.submit(now);
        }

        fn submit(self: *State, now: u64) bool {
            lcd.presentFrozen(self.frozen, !self.pending_frame.full) catch |failure| {
                self.fail(failure);
                return false;
            };
            diag.report.ui_drawn += 1;
            if (self.pending_frame.animated) {
                if (self.continuous) {
                    const gap = now - self.last_submission;
                    diag.report.ui_animation_gap_max = @max(diag.report.ui_animation_gap_max, @as(u32, @intCast(gap)));
                    if (gap > 25) diag.report.ui_animation_slow += 1;
                }
                diag.report.ui_animation_frames += 1;
                self.continuous = true;
            }
            self.last_submission = now;
            self.pending_frame.submitted();
            return true;
        }

        fn label(c: C, x: i32, y: i32, w: u16, text: []const u8, role: draw.fonts.Role, color: draw.Color) void {
            c.ellipsis(x, y, w, text, role, color);
        }

        fn centered(c: C, y: i32, width: u16, text: []const u8, role: draw.fonts.Role, color: draw.Color) void {
            const measured = @min(width, draw.textWidth(text, role));
            label(c, @divTrunc(320 - @as(i32, measured), 2), y, measured, text, role, color);
        }

        fn header(self: *State, c: C, title: []const u8, detail: []const u8) void {
            label(c, 16, 11, 198, title, .serif, ink);
            c.right(265, 25, detail, .caption, muted);
            c.fill(16, 54, 288, 1, line);
            c.fill(282, 18, 21, 10, muted);
            c.fill(283, 19, 19, 8, paper);
            c.fill(304, 21, 2, 4, muted);
            if (self.battery_mv > 0) c.fill(284, 20, @intCast(@min(17, (self.battery_mv -| 3300) * 17 / 900)), 6, accent);
        }

        fn image(self: *State, c: C, album: views.Album, x: i32, y: i32, w: u16, h: u16, lean: i32) void {
            const tile = self.covers.get(album.id, album.art) orelse {
                c.rounded(x, y, w, h, 2, line);
                return;
            };
            if (tile.width == 0 or tile.height == 0) {
                c.rounded(x, y, w, h, 2, line);
                return;
            }
            for (0..w) |xx| {
                const dx = x + @as(i32, @intCast(xx));
                if (dx < 0 or dx >= 320) continue;
                const source_x = xx * flow_scene.texture_edge / w;
                if (source_x < tile.x or source_x >= tile.x + tile.width) continue;
                const slope = if (lean == 0) 0 else @divTrunc((@as(i32, @intCast(xx)) - @as(i32, w / 2)) * lean, @as(i32, w));
                const top = y + slope;
                const start: usize = @intCast(@max(0, -top));
                const end: usize = @intCast(@max(0, @min(@as(i32, h), 240 - top)));
                if (start >= end) continue;
                var source_y = start * flow_scene.texture_edge / h;
                var remainder = start * flow_scene.texture_edge % h;
                var destination: usize = @intCast((top + @as(i32, @intCast(start))) * 320 + dx);
                for (start..end) |_| {
                    if (source_y >= tile.y and source_y < tile.y + tile.height) c.surface.pixels[destination] = tile.pixels[source_x * flow_scene.texture_edge + source_y];
                    destination += 320;
                    remainder += flow_scene.texture_edge;
                    while (remainder >= h) {
                        remainder -= h;
                        source_y += 1;
                    }
                }
            }
        }

        fn clock(buf: []u8, seconds: u64) []const u8 {
            return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ seconds / 60, seconds % 60 }) catch "";
        }

        fn timeline(self: *State, c: C, now: u64) void {
            var buf: [96]u8 = undefined;
            const mix = self.animation.mix(now);
            const volume_width: u16 = @intFromFloat(std.math.clamp(self.animation.value(now) / 100, 0, 1) * 288);
            const progress_width: u16 = @intCast(if (self.status.total_frames > 0) @min(288, self.status.played_frames * 288 / self.status.total_frames) else 0);
            const opacity: u8 = @intFromFloat(mix * 255);
            c.rounded(16, 190, 288, 12, 3, line);
            if (volume_width > 0) c.rounded(16, 190, volume_width, 12, 3, draw.blend(line, accent, opacity));
            if (progress_width > 0) c.rounded(16, 190, progress_width, 12, 3, draw.blend(line, accent, 255 - opacity));
            const overlap = @min(volume_width, progress_width);
            if (overlap > 0) c.rounded(16, 190, overlap, 12, 3, accent);
            if (mix < 0.5) {
                label(c, 16, 208, 80, clock(&buf, self.status.played_frames / @max(1, self.status.sample_rate)), .caption, draw.blend(muted, paper, @intFromFloat(mix * 2 * 255)));
                c.right(304, 208, clock(&buf, self.status.total_frames / @max(1, self.status.sample_rate)), .caption, muted);
            } else {
                label(c, 16, 208, 80, "Volume", .caption, draw.blend(paper, muted, @intFromFloat((mix - 0.5) * 2 * 255)));
                c.right(304, 208, std.fmt.bufPrint(&buf, "{d}", .{@as(u32, 128 - self.attenuation) * 100 / 112}) catch "", .caption, muted);
            }
        }

        pub fn renderTimelineInto(self: *State, pixels: *[320 * 240]u16, now: u64) void {
            const c = C.init(pixels);
            c.fill(0, 188, 320, 42, paper);
            if (self.playing_track != null) self.timeline(c, now);
        }

        fn render(self: *State, now: u64) void {
            self.renderInto(lcd.framebuffer, now);
        }

        pub fn renderInto(self: *State, pixels: *[320 * 240]u16, now: u64) void {
            const c = C.init(pixels);
            const view = self.snapshot();
            const retained = self.screen == .albums and self.rendered_screen == .albums and self.rendered_surface == @intFromPtr(pixels);
            const header_changed = !retained or self.rendered_selection != self.selection or self.rendered_count != view.album_count or self.rendered_battery != self.battery_mv or self.rendered_scan_active != diag.report.scan_active or self.rendered_scan_visited != diag.report.scan_visited;
            const caption_changed = !retained or self.rendered_selection != self.selection or self.rendered_revision != view.revision;
            if (retained) c.fill(0, 32, 320, 161, paper) else c.clear(paper);
            var buf: [96]u8 = undefined;
            for (&self.covers.requested) |*request| request.* = .{};
            switch (self.screen) {
                .home => {
                    self.header(c, "Music", std.fmt.bufPrint(&buf, "{d} tracks", .{view.track_count}) catch "");
                    for ([_][]const u8{ "Now Playing", "Albums", "Library", "Folders" }, 0..) |name, i| {
                        const y: i32 = 64 + @as(i32, @intCast(i)) * 34;
                        if (i == self.selection) c.rounded(12, y, 296, 32, 4, selected);
                        label(c, 20, y + 3, 260, name, .reading, if (i == self.selection) accent else ink);
                        c.chevron(294, y + 11, muted);
                    }
                },
                .library => {
                    self.header(c, "Library", std.fmt.bufPrint(&buf, "{d} albums", .{view.album_count}) catch "");
                    label(c, 16, 63, 288, self.index.phase, .reading, ink);
                    for ([_][]const u8{ "Update library", "Verify library" }, 0..) |name, i| {
                        const y: i32 = 121 + @as(i32, @intCast(i)) * 32;
                        if (i == self.selection) c.rounded(12, y, 296, 30, 4, selected);
                        label(c, 20, y + 2, 280, name, .body, ink);
                    }
                },
                .albums => {
                    const header_started = benchmarkClock();
                    if (header_changed) {
                        c.fill(0, 0, 320, 32, paper);
                        label(c, 12, 3, 180, "Albums", .body, ink);
                        c.right(274, 8, std.fmt.bufPrint(&buf, "{d} / {d}", .{ if (view.album_count > 0) self.selection + 1 else 0, view.album_count }) catch "", .caption, muted);
                        c.fill(286, 11, 20, 9, muted);
                        c.fill(287, 12, 18, 7, paper);
                        c.fill(307, 14, 2, 3, muted);
                        if (self.battery_mv > 0) c.fill(288, 13, @intCast(@min(16, (self.battery_mv -| 3300) * 16 / 900)), 5, accent);
                        c.fill(12, 30, 296, 1, line);
                    }
                    const scene_started = benchmarkClock();
                    diag.report.cover_header_max = @max(diag.report.cover_header_max, scene_started -% header_started);
                    const anchor: i32 = @intFromFloat(@round(self.flow));
                    var request: usize = 0;
                    // Ask for the visible seven and the destination's centre and
                    // neighbours. Ten requests fit the existing twelve-tile cache.
                    for ([_]i32{ 0, -1, 1, -2, 2, -3, 3 }) |offset| {
                        const i = anchor + offset;
                        if (i < 0 or i >= view.album_count) continue;
                        const album = view.albums[@intCast(i)];
                        self.covers.request(request, album.id, album.art);
                        request += 1;
                    }
                    for ([_]i32{ 0, -1, 1 }) |offset| {
                        const i = @as(i32, @intCast(self.selection)) + offset;
                        if (i < 0 or i >= view.album_count or @abs(i - anchor) <= 3) continue;
                        const album = view.albums[@intCast(i)];
                        self.covers.request(request, album.id, album.art);
                        request += 1;
                    }
                    var cards: [7]flow_scene.Card = undefined;
                    var card_count: usize = 0;
                    for ([_]i32{ -3, 3, -2, 2, -1, 1, 0 }) |offset| {
                        const i = anchor + offset;
                        if (i < 0 or i >= view.album_count) continue;
                        const album = view.albums[@intCast(i)];
                        const distance = @as(f32, @floatFromInt(i)) - self.flow;
                        if (@abs(distance) > 3.4) continue;
                        const texture = self.covers.get(album.id, album.art);
                        cards[card_count] = .{ .texture = texture, .quad = flow_scene.project(distance) };
                        card_count += 1;
                    }
                    flow_scene.paintScene(.{ .pixels = pixels }, cards[0..card_count]);
                    const caption_started = benchmarkClock();
                    diag.report.cover_scene_max = @max(diag.report.cover_scene_max, caption_started -% scene_started);
                    if (caption_changed) {
                        c.fill(0, 193, 320, 47, paper);
                        if (view.album_count > 0) {
                            const album = view.albums[self.selection];
                            centered(c, 193, 296, album.title, .reading, ink);
                            centered(c, 215, 296, album.artist, .caption, muted);
                        }
                    }
                    if (view.album_count == 0) centered(c, 105, 288, "No albums yet", .reading, muted);
                    diag.report.cover_caption_max = @max(diag.report.cover_caption_max, benchmarkClock() -% caption_started);
                    if (diag.report.scan_active != 0) {
                        c.rounded(80, 12, 3, 3, 1, accent);
                        if (diag.report.scan_total > 0) c.fill(12, 30, @intCast(@min(296, @as(u64, diag.report.scan_visited) * 296 / diag.report.scan_total)), 1, accent);
                    }
                },
                .tracks => {
                    const album = if (view.albumIndex(self.album_id)) |i| view.albums[i] else null;
                    self.header(c, if (album) |a| a.title else "Tracks", "");
                    var i = self.first;
                    while (i < self.first + 5) : (i += 1) {
                        const track = self.trackAt(i) orelse break;
                        const y: i32 = 61 + @as(i32, @intCast(i - self.first)) * 29;
                        if (i == self.selection) c.rounded(12, y, 296, 29, 4, selected);
                        label(c, 20, y + 1, 280, track.meta.title, .reading, if (i == self.selection) accent else ink);
                    }
                },
                .player => {
                    self.header(c, "Now Playing", "");
                    if (self.playing_track) |track| {
                        var album: views.Album = .{
                            .id = 0,
                            .title = track.meta.album,
                            .artist = track.meta.album_artist,
                            .directory = core.editionRoot(track.path),
                            .release_id = track.meta.release_id,
                            .representative = track,
                        };
                        if (diag.catalog) |catalog| if (catalog.value.trackById(track.id)) |t| {
                            if (catalog.value.tracks[t].album_index < catalog.value.albums.len) {
                                const a = catalog.value.albums[catalog.value.tracks[t].album_index];
                                album.id = a.id;
                                album.art = a.art;
                            }
                        };
                        self.covers.request(0, album.id, album.art);
                        self.image(c, album, 16, 65, 112, 112, 0);
                        label(c, 144, 64, 160, track.meta.title, .title, ink);
                        label(c, 144, 104, 160, track.meta.artist, .body, ink);
                        label(c, 144, 130, 160, track.meta.album, .caption, muted);
                        label(c, 144, 163, 160, track.meta.codec, .caption, muted);
                        self.timeline(c, now);
                    } else label(c, 16, 100, 288, "Choose a track", .title, ink);
                },
            }
            if (self.screen != .player and self.screen != .albums and diag.report.scan_active != 0) {
                c.fill(0, 213, 320, 27, paper);
                c.fill(16, 213, 288, 1, line);
                label(c, 16, 218, 175, self.index.phase, .caption, muted);
                c.right(304, 218, std.fmt.bufPrint(&buf, "{d} / {d}", .{ diag.report.scan_visited, diag.report.scan_total }) catch "", .caption, muted);
                if (diag.report.scan_total > 0) c.fill(16, 237, @intCast(@min(288, @as(u64, diag.report.scan_visited) * 288 / diag.report.scan_total)), 2, accent);
            }
            if (self.screen == .player and diag.report.scan_active != 0) c.rounded(266, 22, 4, 4, 2, accent);
            self.covers.publishRequests();
            self.rendered_surface = @intFromPtr(pixels);
            self.rendered_screen = self.screen;
            self.rendered_selection = self.selection;
            self.rendered_revision = view.revision;
            self.rendered_count = view.album_count;
            self.rendered_battery = self.battery_mv;
            self.rendered_scan_active = diag.report.scan_active;
            self.rendered_scan_visited = diag.report.scan_visited;
        }
    };
}

// The host fixture provides no MMIO, filesystem or wall clock. It exercises
// the same controller with a deterministic DMA completion schedule.
const TestPlatform = struct {
    var milliseconds: u64 = 0;
    pub fn now() u32 {
        return @truncate(milliseconds * 6000);
    }
    pub fn trace(_: @import("display_trace.zig").Kind, _: u32, _: u32) void {}
    pub const Index = struct {
        pub const State = struct {
            volume: *anyopaque = undefined,
            projection: *views.Pair,
            phase: []const u8 = "Ready",
            requested: bool = false,
            pub fn request(self: *@This(), _: bool) void {
                self.requested = true;
            }
        };
    };
    pub const Diagnostics = struct {
        pub const Report = struct {
            cover_caption_max: u32 = 0,
            cover_header_max: u32 = 0,
            cover_scene_max: u32 = 0,
            failure: u32 = 0,
            scan_active: u32 = 0,
            scan_total: u32 = 0,
            scan_visited: u32 = 0,
            selected_album_high: u32 = 0,
            selected_album_low: u32 = 0,
            selected_album_rank: u32 = 0,
            ui_animation_frames: u32 = 0,
            ui_animation_gap_max: u32 = 0,
            ui_animation_slow: u32 = 0,
            ui_draw_max: u32 = 0,
            ui_drawn: u32 = 0,
        };
        pub var report: Report = .{};
        pub var catalog: ?core.Owned = null;
    };
    pub const Display = struct {
        const Region = @import("display_transfer.zig").Region;
        pub const Frozen = struct { region: Region, bank: u1 };
        pub var last_failure: ?anyerror = null;
        var pixels: [320 * 240]u16 = undefined;
        pub const framebuffer = &pixels;
        var banks: [2][320 * 240]u16 = undefined;
        var active: u1 = 0;
        var busy_until: u64 = 0;
        var latency: u64 = 19;
        var submissions: usize = 0;
        var active_hash: u32 = 0;
        var corrupted: bool = false;
        pub fn renderIntervalMs() u64 {
            return 11;
        }
        pub fn poll() enum { idle, busy, failed } {
            if (TestPlatform.milliseconds < busy_until) return .busy;
            if (busy_until != 0) {
                corrupted = corrupted or active_hash != std.hash.Crc32.hash(std.mem.sliceAsBytes(&banks[active]));
                busy_until = 0;
            }
            return .idle;
        }
        pub fn freeze(region: Region) !Frozen {
            const free = active ^ 1;
            try @import("presentation.zig").pack(framebuffer, 320, 240, region, &banks[free]);
            return .{ .region = region, .bank = free };
        }
        pub fn presentFrozen(frozen: Frozen, _: bool) !void {
            if (busy_until != 0) return error.Owned;
            active = frozen.bank;
            active_hash = std.hash.Crc32.hash(std.mem.sliceAsBytes(&banks[active]));
            busy_until = TestPlatform.milliseconds + latency;
            submissions += 1;
        }
        fn reset() void {
            busy_until = 0;
            latency = 19;
            active = 0;
            submissions = 0;
            corrupted = false;
            last_failure = null;
            @memset(&pixels, 0);
            for (&banks) |*bank| @memset(bank, 0);
        }
    };
};

const TestState = Controller(TestPlatform);
const test_diag = TestPlatform.Diagnostics;
const test_index = TestPlatform.Index;

const Fixture = struct {
    pair: *views.Pair,
    cache: *covers.Cache,
    index_state: test_index.State,
    track_memory: [8192]u8 = undefined,

    fn init(self: *Fixture) !void {
        self.pair = try std.testing.allocator.create(views.Pair);
        errdefer std.testing.allocator.destroy(self.pair);
        self.pair.* = .{};
        self.cache = try std.testing.allocator.create(covers.Cache);
        self.cache.* = .{};
        self.index_state = .{ .volume = undefined, .projection = self.pair };
        test_diag.report = .{};
        test_diag.catalog = null;
    }

    fn deinit(self: *Fixture) void {
        std.testing.allocator.destroy(self.cache);
        std.testing.allocator.destroy(self.pair);
    }

    fn state(self: *Fixture) TestState {
        return .{ .index = &self.index_state, .covers = self.cache, .track_store = @import("track_selection.zig").Store.init(&self.track_memory) };
    }
};

test "native album focus and fractional animation phase survive progressive insertions" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    const old = [_]core.Track{.{ .id = 1, .path = "B/1.m4a", .stamp = .{}, .meta = .{ .album = "B", .album_artist = "B" } }};
    const added = [_]core.Track{.{ .id = 2, .path = "A/1.m4a", .stamp = .{}, .meta = .{ .album = "A", .album_artist = "A" } }};
    const baseline = core.Catalog{ .tracks = &old };
    try fixture.pair.publish(&baseline, &old, 42, true);
    state.screen = .albums;
    state.selected_id = state.snapshot().albums[0].id;
    state.flow = 0.25;
    state.reconcile();
    const id = state.selected_id;
    try fixture.pair.publish(&baseline, &added, 42, false);
    state.reconcile();
    try std.testing.expectEqual(id, state.selected_id);
    try std.testing.expectEqual(1, state.selection);
    try std.testing.expectEqual(@as(f32, 1.25), state.flow);
}

test "native timeline volume and restoration change only the shared timeline area" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    const track = core.Track{ .id = 1, .path = "B/1.m4a", .stamp = .{}, .meta = .{ .title = "Title", .artist = "Artist", .album = "Album", .codec = "aac" } };
    try fixture.pair.publish(&.{}, &.{track}, 42, true);
    state.queue(&track);
    state.playing_track = state.track_store.begin().?;
    state.screen = .player;
    state.status = .{
        .phase = .playing,
        .sample_rate = 48000,
        .output_format = .signed_24_in_u32,
        .total_frames = 48000 * 60,
        .played_frames = 48000,
    };
    const before = try std.testing.allocator.create([320 * 240]u16);
    defer std.testing.allocator.destroy(before);
    const after = try std.testing.allocator.create([320 * 240]u16);
    defer std.testing.allocator.destroy(after);
    state.renderInto(before, 10);
    state.animation.request(100, 75);
    state.renderInto(after, 260);
    try std.testing.expectEqualSlices(u16, before[0 .. 188 * 320], after[0 .. 188 * 320]);
    try std.testing.expect(!std.mem.eql(u16, before[188 * 320 ..], after[188 * 320 ..]));
    _ = state.animation.tick(1800);
    state.renderInto(after, 1800);
    try std.testing.expectEqualSlices(u16, before, after);
}

test "all native screens render with empty and progressively populated library" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    try fixture.pair.publish(&.{}, &.{}, 1, true);
    const pixels = try std.testing.allocator.create([320 * 240]u16);
    defer std.testing.allocator.destroy(pixels);
    inline for (comptime std.meta.fieldNames(Screen)) |name| {
        state.screen = @field(Screen, name);
        state.renderInto(pixels, 100);
    }
    const track = core.Track{ .id = 1, .path = "B/1.m4a", .stamp = .{}, .meta = .{ .title = "A long title with accented text café", .artist = "Artist", .album = "Album" } };
    try fixture.pair.publish(&.{}, &.{track}, 1, true);
    state.album_id = state.snapshot().albums[0].id;
    test_diag.report.scan_active = 1;
    test_diag.report.scan_total = 500;
    test_diag.report.scan_visited = 32;
    inline for (comptime std.meta.fieldNames(Screen)) |name| {
        state.screen = @field(Screen, name);
        state.renderInto(pixels, 100);
    }
}

test "partial timeline rendering equals a complete render at every fade and reversal phase" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    const track = core.Track{ .id = 1, .path = "B/1.m4a", .stamp = .{}, .meta = .{ .title = "Title", .artist = "Artist", .album = "Album", .codec = "aac" } };
    try fixture.pair.publish(&.{}, &.{track}, 42, true);
    state.queue(&track);
    state.playing_track = state.track_store.begin().?;
    state.screen = .player;
    state.status = .{ .phase = .playing, .sample_rate = 48000, .output_format = .signed_24_in_u32, .total_frames = 48000 * 60, .played_frames = 48000 };
    const full = try std.testing.allocator.create([320 * 240]u16);
    defer std.testing.allocator.destroy(full);
    const partial = try std.testing.allocator.create([320 * 240]u16);
    defer std.testing.allocator.destroy(partial);
    state.renderInto(partial, 0);
    state.animation.request(100, 75);
    for (0..200) |i| {
        const now = i * 13;
        if (i == 15) state.animation.request(now, 20);
        _ = state.animation.tick(now);
        state.status.played_frames += 480;
        state.renderTimelineInto(partial, now);
        state.renderInto(full, now);
        try std.testing.expectEqualSlices(u16, full, partial);
    }
}

test "retained carousel bands match a fresh render through selection and scan changes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1.m4a", .stamp = .{}, .meta = .{ .title = "One", .album = "First", .album_artist = "Artist" } },
        .{ .id = 2, .path = "B/1.m4a", .stamp = .{}, .meta = .{ .title = "Two", .album = "Second", .album_artist = "Artist" } },
    };
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    state.screen = .albums;
    const fresh = try std.testing.allocator.create([320 * 240]u16);
    defer std.testing.allocator.destroy(fresh);
    const retained = try std.testing.allocator.create([320 * 240]u16);
    defer std.testing.allocator.destroy(retained);
    const old_report = test_diag.report;
    defer test_diag.report = old_report;
    for (0..41) |step| {
        state.selection = if (step < 20) 0 else 1;
        state.flow = @as(f32, @floatFromInt(step)) / 40;
        test_diag.report.scan_active = if (step < 30) 1 else 0;
        test_diag.report.scan_total = 100;
        test_diag.report.scan_visited = @intCast(step);
        state.renderInto(retained, step * 17);
        var reference = state;
        reference.renderInto(fresh, step * 17);
        try std.testing.expectEqualSlices(u16, fresh, retained);
    }
}

test "deterministic controller retains immutable frames during delayed DMA and progressive publications" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .album = "First", .album_artist = "Artist" } },
        .{ .id = 2, .path = "B/1", .stamp = .{}, .meta = .{ .album = "Second", .album_artist = "Artist" } },
        .{ .id = 3, .path = "C/1", .stamp = .{}, .meta = .{ .album = "Third", .album_artist = "Artist" } },
    };
    const Event = Input;
    for ([_]u64{ 1, 14, 19, 43 }) |latency| {
        TestPlatform.Display.reset();
        TestPlatform.Display.latency = latency;
        state = fixture.state();
        state.navigate(.albums);
        try fixture.pair.publish(&.{}, tracks[0..2], 42, false);
        for (0..1200) |now| {
            TestPlatform.milliseconds = now;
            if (now == 100) try fixture.pair.publish(&.{}, &tracks, 42, true);
            if (now < 300 and now % 37 == 0) _ = state.handle(if (now % 2 == 0) Event.down else Event.up, now, true);
            state.frame(now);
            try std.testing.expect(!state.failure);
            try std.testing.expect(!TestPlatform.Display.corrupted);
        }
        try std.testing.expectEqual(@as(f32, @floatFromInt(state.selection)), state.flow);
        try std.testing.expect(!state.pending_frame.ready);
        try std.testing.expect(TestPlatform.Display.submissions > 5);
    }
}

test "album track navigation follows disc and track tags and stops at album boundaries" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    const tracks = [_]core.Track{
        .{ .id = 10, .path = "A/aaa", .stamp = .{}, .meta = .{ .album = "Album", .track = 10 } },
        .{ .id = 2, .path = "A/zzz", .stamp = .{}, .meta = .{ .album = "Album", .track = 2 } },
        .{ .id = 3, .path = "B/next", .stamp = .{}, .meta = .{ .album = "Other", .track = 1 } },
    };
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    state.album_id = state.snapshot().albums[state.snapshot().track_groups[0]].id;
    try std.testing.expectEqual(2, state.trackAt(0).?.id);
    try std.testing.expectEqual(10, state.trackAt(1).?.id);
    state.queue(&tracks[1]);
    state.playing_track = state.track_store.begin();
    try std.testing.expect(state.neighbouringTrack(-1) == null);
    try std.testing.expectEqual(10, state.neighbouringTrack(1).?.id);
    state.queue(&tracks[0]);
    state.playing_track = state.track_store.begin();
    try std.testing.expect(state.neighbouringTrack(1) == null);
}

test "cosmetic header refresh waits for volume movement without waiting through its stable hold" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    state.navigate(.player);
    state.battery_mv = 4100;
    state.animation.request(100, 75);
    state.dirty = false;
    state.major = false;
    state.refreshBattery(4099, 120);
    try std.testing.expectEqual(4100, state.battery_mv);
    try std.testing.expect(!state.major);
    _ = state.animation.tick(240);
    state.refreshBattery(4099, 240);
    try std.testing.expectEqual(4099, state.battery_mv);
    try std.testing.expect(state.major and state.dirty);
}

test "Back from tracks restores the selected album without sweeping from the first cover" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .album = "First" } },
        .{ .id = 2, .path = "B/1", .stamp = .{}, .meta = .{ .album = "Second" } },
    };
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    state.navigate(.albums);
    _ = state.handle(.down, 100, false);
    const id = state.selected_id;
    _ = state.handle(.select, 200, false);
    try std.testing.expectEqual(Screen.tracks, state.screen);
    _ = state.handle(.back, 300, false);
    try std.testing.expectEqual(Screen.albums, state.screen);
    try std.testing.expectEqual(id, state.selected_id);
    try std.testing.expectEqual(1, state.selection);
    try std.testing.expectEqual(@as(f32, 1), state.flow);
}

test "spaced previous and next presses begin animation at the input time after idle" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .album = "First" } },
        .{ .id = 2, .path = "B/1", .stamp = .{}, .meta = .{ .album = "Second" } },
    };
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    for ([_]u64{ 500, 2000, 60000 }) |idle_ms| {
        TestPlatform.Display.reset();
        var state = fixture.state();
        state.navigate(.albums);
        TestPlatform.milliseconds = 100;
        state.frame(100);
        const pressed_at = 100 + idle_ms;
        _ = state.handle(.down, pressed_at, false);
        TestPlatform.milliseconds = pressed_at;
        state.frame(pressed_at);
        try std.testing.expectEqual(@as(f32, 0), state.flow);
        TestPlatform.milliseconds = pressed_at + 20;
        state.frame(pressed_at + 20);
        try std.testing.expect(state.flow > 0 and state.flow < 0.5);
        TestPlatform.milliseconds = pressed_at + 1000;
        state.frame(pressed_at + 1000);
        _ = state.handle(.up, pressed_at + 2000, false);
        TestPlatform.milliseconds = pressed_at + 2000;
        state.frame(pressed_at + 2000);
        try std.testing.expect(state.flow > 0.99);
        TestPlatform.milliseconds += 20;
        state.frame(TestPlatform.milliseconds);
        try std.testing.expect(state.flow > 0.5 and state.flow < 0.99);
    }
}
