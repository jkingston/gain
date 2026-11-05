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
const navigation = @import("navigation.zig");

const chrome = @import("music_chrome.zig");
const battery_status = @import("battery.zig");
const paper = chrome.paper;
const ink = chrome.ink;
const muted = chrome.muted;
const line = chrome.line;
const accent = chrome.accent;
const selected = chrome.selected;

pub const Input = enum(u3) { select, back, home, up, down, volume_up, volume_down };

pub const Screen = enum { home, albums, tracks, player, library, artists, artist };
pub const TrackScope = enum { album, artist, all };
const HomeItem = struct {
    name: []const u8,
    target: enum { player, albums, artists, songs, library, folders },
};
const home_items = [_]HomeItem{
    .{ .name = "Now Playing", .target = .player },
    .{ .name = "Albums", .target = .albums },
    .{ .name = "Artists", .target = .artists },
    .{ .name = "All Songs", .target = .songs },
    .{ .name = "Library", .target = .library },
    .{ .name = "Folders", .target = .folders },
};
const visible_rows = 5;

const Layout = chrome.Layout;

const CoverModel = struct {
    id: u64,
    texture: ?*const flow_scene.Prepared,
    distance: f32,
};

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
        home_selection: usize = 0,
        home_first: usize = 0,
        album_id: u64 = 0,
        artist_id: u64 = 0,
        album_rank: ?usize = null,
        artist_rank: ?usize = null,
        track_scope: TrackScope = .album,
        tracks_return: Screen = .albums,
        input_policy: navigation.Policy = .{},
        jump_position: ?usize = null,
        selected_id: u64 = 0,
        selected_track_anchor: u64 = 0,
        flow: f32 = 0,
        flow_at: u64 = 0,
        revision: u32 = 0,
        cover_revision: u32 = 0,
        text_cache: ?*@import("text/cache.zig").Cache = null,
        text_revision: u32 = 0,
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
        last_scan_total: u32 = 0,
        last_scan_phase: []const u8 = "",
        last_active: u32 = 0,
        battery_mv: u32 = 0,
        charging: bool = false,
        failure: bool = false,
        rendered_surface: usize = 0,
        rendered_screen: ?Screen = null,
        rendered_selection: usize = 0,
        rendered_revision: u32 = 0,
        rendered_count: usize = 0,
        rendered_battery: u32 = 0,
        rendered_charging: bool = false,
        rendered_scan_active: u32 = 0,
        rendered_scan_width: u16 = 0,
        rendered_flow: f32 = 0,
        rendered_cover_revision: u32 = 0,
        rendered_covers: [7]CoverModel = undefined,
        rendered_cover_count: usize = 0,

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
            self.cancelInput(self.input_policy.held);
            self.jump_position = null;
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
            return switch (self.track_scope) {
                .album => view.albumTrack(self.albumRank() orelse return null, position),
                .artist => view.artistTrack(self.artistRank() orelse return null, position),
                .all => if (position < view.track_count) view.tracks[view.title_order[position]] else null,
            };
        }

        fn albumRank(self: *const State) ?usize {
            return if (self.revision == self.snapshot().revision) self.album_rank else self.snapshot().albumIndex(self.album_id);
        }

        fn artistRank(self: *const State) ?usize {
            return if (self.revision == self.snapshot().revision) self.artist_rank else self.snapshot().artistIndex(self.artist_id);
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

        pub fn rows(self: *const State) usize {
            return switch (self.screen) {
                .home => home_items.len,
                .albums => self.snapshot().album_count,
                .artists => self.snapshot().artist_count,
                .artist => if (self.artistRank()) |i| 1 + @as(usize, self.snapshot().artists[i].album_count) else 0,
                .tracks => switch (self.track_scope) {
                    .album => if (self.albumRank()) |i| self.snapshot().albums[i].count else 0,
                    .artist => if (self.artistRank()) |i| self.snapshot().artists[i].track_count else 0,
                    .all => self.snapshot().track_count,
                },
                .library => 2,
                .player => 0,
            };
        }

        fn inputContext(self: *const State) navigation.Context {
            if (self.jump_position != null) return .list;
            return switch (self.screen) {
                .albums => .covers,
                .player => .transport,
                else => .list,
            };
        }

        fn visibleRows(_: *const State) usize {
            // Reserve the scan footer before laying out full-height rows.
            // Retain this iteration's five-row maximum and large headings.
            const bottom: usize = if (diag.report.scan_active != 0) Layout.footer_top else 240;
            return @min(visible_rows, (bottom - Layout.row_top) / Layout.row_height);
        }

        fn ensureVisible(self: *State) void {
            const count = self.visibleRows();
            if (self.selection < self.first) self.first = self.selection;
            if (self.selection >= self.first + count) self.first = self.selection - (count - 1);
        }

        pub fn cancelInput(self: *State, held: u8) void {
            self.input_policy.cancel(held);
        }

        pub fn button(self: *State, key: navigation.Button, pressed: bool, now: u64, playing: bool) media.PlaybackCommand {
            self.reconcile();
            return self.act(self.input_policy.edge(key, pressed, now, self.inputContext(), if (self.jump_position != null) 21 else self.rows()), now, playing);
        }

        pub fn wheel(self: *State, direction: i2, now: u64, playing: bool) media.PlaybackCommand {
            self.reconcile();
            return self.act(self.input_policy.wheel(direction, now, self.inputContext(), if (self.jump_position != null) 8 else self.rows()), now, playing);
        }

        pub fn repeat(self: *State, now: u64, held: u8, playing: bool) media.PlaybackCommand {
            self.reconcile();
            return self.act(self.input_policy.tick(now, self.inputContext(), if (self.jump_position != null) 8 else self.rows(), held), now, playing);
        }

        fn act(self: *State, action: navigation.Action, now: u64, playing: bool) media.PlaybackCommand {
            if (action == .none) return .none;
            if (self.jump_position) |position| switch (action) {
                .move => |delta| {
                    self.jump_position = navigation.move(position, 21, delta);
                    self.dirty = true;
                    return .none;
                },
                .select, .back, .home => {
                    self.jump_position = null;
                    self.cancelInput(self.input_policy.held);
                    if (action == .select) {
                        const target = (self.rows() -| 1) * position / 20;
                        self.moveBy(@as(i32, @intCast(target)) - @as(i32, @intCast(self.selection)), now);
                    }
                    self.dirty = true;
                    self.major = true;
                    self.rendered_screen = null;
                    return .none;
                },
                else => {},
            };
            switch (action) {
                .none => return .none,
                .move => |delta| {
                    self.moveBy(delta, now);
                    return .none;
                },
                .jump => {
                    self.jump_position = if (self.rows() > 1) self.selection * 20 / (self.rows() - 1) else 0;
                    self.cancelInput(self.input_policy.held);
                    self.dirty = true;
                    self.major = true;
                    return .none;
                },
                .previous => return if (playing) .previous else .none,
                .next => return if (playing) .next else .none,
                else => return self.handle(switch (action) {
                    .select => .select,
                    .back => .back,
                    .home => .home,
                    .volume_up => .volume_up,
                    .volume_down => .volume_down,
                    else => unreachable,
                }, now, playing),
            }
        }

        fn moveBy(self: *State, delta: i32, now: u64) void {
            if (self.screen == .albums) self.advanceFlow(now);
            self.selection = navigation.move(self.selection, self.rows(), delta);
            self.ensureVisible();
            if (self.screen == .albums and self.rows() > 0) {
                self.selected_id = self.snapshot().albums[self.selection].id;
                self.selected_track_anchor = self.snapshot().albums[self.selection].representative.id;
                // Rapid moves land near the current destination; never sweep
                // through hundreds of skipped cards or retain old destinations.
                const target: f32 = @floatFromInt(self.selection);
                if (@abs(target - self.flow) > 3) self.flow = target - std.math.sign(target - self.flow);
            }
            if (self.screen == .artists and self.rows() > 0) self.selected_id = self.snapshot().artistId(self.selection);
            if (self.screen == .artist and self.selection > 0) {
                if (self.artistRank()) |i| self.selected_id = self.snapshot().albums[self.snapshot().artists[i].first_album + self.selection - 1].id;
            } else if (self.screen == .artist) self.selected_id = 0;
            if (self.screen == .tracks) if (self.trackAt(self.selection)) |track| {
                self.selected_id = track.id;
            };
            self.dirty = true;
            self.major = true;
        }

        pub fn handle(self: *State, event: Input, now: u64, playing: bool) media.PlaybackCommand {
            self.reconcile();
            if (self.screen == .player or (event != .volume_up and event != .volume_down)) self.dirty = true;
            switch (event) {
                .volume_up, .volume_down => {
                    self.attenuation = if (event == .volume_up) self.attenuation -| 4 else @min(128, self.attenuation +| 4);
                    self.attenuation = @max(16, self.attenuation);
                    self.animation.request(now, @as(u32, 128 - self.attenuation) * 100 / 112);
                    return .{ .set_attenuation = self.attenuation };
                },
                .home => self.navigate(.home),
                .back => {
                    if (self.screen == .artists or self.screen == .artist or (self.screen == .tracks and self.tracks_return != .albums)) {
                        const destination: Screen = switch (self.screen) {
                            .artists => .home,
                            .artist => .artists,
                            else => self.tracks_return,
                        };
                        const artist = self.snapshot().artistIndex(self.artist_id);
                        self.navigate(destination);
                        if (destination == .home) {
                            self.selection = self.home_selection;
                            self.first = self.home_first;
                        }
                        if (destination == .artists) if (artist) |rank| {
                            self.selection = rank;
                            self.selected_id = self.snapshot().artistId(rank);
                        };
                        if (destination == .artist and self.track_scope == .album) if (artist) |rank| {
                            if (self.snapshot().albumIndex(self.album_id)) |album| {
                                const group = self.snapshot().artists[rank];
                                if (album >= group.first_album and album < group.first_album + group.album_count) {
                                    self.selection = album - group.first_album + 1;
                                    self.selected_id = self.album_id;
                                }
                            }
                        };
                        self.first = self.selection -| (visible_rows - 1);
                        return .none;
                    }
                    const album = if (self.screen == .tracks) self.snapshot().albumIndex(self.album_id) else null;
                    self.navigate(if (self.screen == .tracks) .albums else .home);
                    if (self.screen == .home) {
                        self.selection = self.home_selection;
                        self.first = self.home_first;
                    }
                    if (album) |rank| {
                        self.selection = rank;
                        self.flow = @floatFromInt(rank);
                        self.selected_id = self.snapshot().albums[rank].id;
                        self.selected_track_anchor = self.snapshot().albums[rank].representative.id;
                    }
                },
                .up, .down => {
                    if (self.screen == .player and playing) return if (event == .up) .previous else .next;
                    self.moveBy(if (event == .up) -1 else 1, now);
                },
                .select => switch (self.screen) {
                    .home => {
                        self.home_selection = self.selection;
                        self.home_first = self.first;
                        const target = home_items[self.selection].target;
                        if (target == .folders) {
                            self.requested_folders = true;
                            if (playing) return .stop;
                        } else {
                            self.track_scope = .all;
                            self.tracks_return = .home;
                            self.navigate(switch (target) {
                                .player => .player,
                                .albums => .albums,
                                .artists => .artists,
                                .songs => .tracks,
                                .library => .library,
                                .folders => unreachable,
                            });
                        }
                    },
                    .albums => if (self.snapshot().album_count > 0) {
                        self.album_id = self.snapshot().albums[self.selection].id;
                        self.track_scope = .album;
                        self.tracks_return = .albums;
                        self.navigate(.tracks);
                    },
                    .artists => if (self.rows() > 0) {
                        self.artist_id = self.snapshot().artistId(self.selection);
                        self.navigate(.artist);
                    },
                    .artist => if (self.snapshot().artistIndex(self.artist_id)) |i| {
                        self.track_scope = if (self.selection == 0) .artist else .album;
                        self.tracks_return = .artist;
                        if (self.selection > 0) self.album_id = self.snapshot().albums[self.snapshot().artists[i].first_album + self.selection - 1].id;
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
            self.artist_rank = view.artistIndex(self.artist_id);
            self.album_rank = view.albumIndex(self.album_id);
            self.revision = view.revision;
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
                if (self.track_scope == .album) for (view.tracks[0..view.track_count], 0..) |track, i| {
                    if (self.selected_id != 0 and track.id == self.selected_id) {
                        self.album_id = view.albums[view.track_groups[i]].id;
                        self.album_rank = view.track_groups[i];
                        break;
                    }
                };
                for (0..self.rows()) |rank| {
                    if (self.trackAt(rank)) |track| if (track.id == self.selected_id) {
                        self.selection = rank;
                        break;
                    };
                }
                self.selection = @min(self.selection, self.rows() -| 1);
                self.first = self.selection -| offset;
                if (self.trackAt(self.selection)) |track| self.selected_id = track.id;
            }
            if (self.screen == .artists) {
                const offset = self.selection -| self.first;
                if (view.artistIndex(self.selected_id)) |rank| self.selection = rank;
                self.selection = @min(self.selection, view.artist_count -| 1);
                self.first = self.selection -| offset;
                if (view.artist_count > 0) self.selected_id = view.artistId(self.selection);
            }
            if (self.screen == .artist) {
                const offset = self.selection -| self.first;
                if (view.artistIndex(self.artist_id)) |artist| {
                    const group = view.artists[artist];
                    for (0..group.album_count) |i| {
                        if (view.albums[group.first_album + i].id == self.selected_id) self.selection = i + 1;
                    }
                }
                self.selection = @min(self.selection, self.rows() -| 1);
                self.first = self.selection -| offset;
            }
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
            return (self.screen == .albums and @abs(self.flow - @as(f32, @floatFromInt(self.selection))) > 0.005) or (self.screen == .player and self.animation.isAnimating(now));
        }

        pub fn refreshBattery(self: *State, millivolts: u32, charging: bool, now: u64) void {
            // A header-only change must not replace a region transfer during
            // the short volume fade. A stable volume hold can refresh normally.
            if (self.screen == .player and self.animation.isAnimating(now)) return;
            const previous = battery_status.Status.fromVoltage(self.battery_mv, self.charging);
            self.battery_mv = millivolts;
            self.charging = charging;
            if (std.meta.eql(previous, battery_status.Status.fromVoltage(millivolts, charging))) return;
            self.dirty = true;
            self.major = true;
        }

        pub fn frame(self: *State, now: u64) void {
            if (self.text_cache) |cache| {
                const revision = cache.revision.load(.acquire);
                if (revision != self.text_revision) {
                    self.text_revision = revision;
                    self.dirty = true;
                    self.major = true;
                    self.rendered_screen = null;
                }
            }
            self.reconcile();
            self.ensureVisible();
            const defer_cosmetic = self.screen == .player and self.animation.isAnimating(now);
            if (!defer_cosmetic and self.covers.revision.load(.acquire) != self.cover_revision) {
                self.cover_revision = self.covers.revision.load(.acquire);
                self.dirty = true;
                self.major = true;
            }
            const volume_moving = self.animation.tick(now) and self.screen == .player;
            if (volume_moving) self.dirty = true;
            if (!defer_cosmetic and self.last_active != diag.report.scan_active) {
                self.last_active = diag.report.scan_active;
                self.dirty = true;
                self.major = true;
            }
            if (self.last_visited != diag.report.scan_visited or self.last_scan_total != diag.report.scan_total) {
                self.last_visited = diag.report.scan_visited;
                self.last_scan_total = diag.report.scan_total;
                // Now Playing shows activity, not a visited-track count. The
                // carousel's one-pixel rule changes only at whole pixels.
                if (diag.report.scan_active != 0 and self.screen != .player and (self.screen != .albums or albumProgressWidth() != self.rendered_scan_width)) self.dirty = true;
            }
            if ((self.screen == .library or (diag.report.scan_active != 0 and self.screen != .player and self.screen != .albums)) and !std.mem.eql(u8, self.last_scan_phase, self.index.phase)) {
                self.last_scan_phase = self.index.phase;
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
            if (@hasDecl(lcd, "waitingForLaunch")) if (lcd.waitingForLaunch()) return;
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
            c.centered(@divTrunc(320 - @as(i32, width), 2), y, width, text, role, color);
        }

        fn header(self: *State, c: C, title: []const u8, detail: []const u8) void {
            chrome.header(c, title, detail, battery_status.Status.fromVoltage(self.battery_mv, self.charging));
        }

        fn highlightRow(c: C, top: i32) void {
            c.rounded(Layout.left - 8, top, Layout.width + 16, Layout.row_height, 4, selected);
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
            c.rounded(Layout.left, Layout.timeline_top, Layout.width, 12, 3, line);
            if (volume_width > 0) c.rounded(Layout.left, Layout.timeline_top, volume_width, 12, 3, draw.blend(line, accent, opacity));
            if (progress_width > 0) c.rounded(Layout.left, Layout.timeline_top, progress_width, 12, 3, draw.blend(line, accent, 255 - opacity));
            const overlap = @min(volume_width, progress_width);
            if (overlap > 0) c.rounded(Layout.left, Layout.timeline_top, overlap, 12, 3, accent);
            const caption_top = Layout.capTop(212, .caption);
            if (mix < 0.5) {
                label(c, Layout.left, caption_top, 80, clock(&buf, self.status.played_frames / @max(1, self.status.sample_rate)), .caption, draw.blend(muted, paper, @intFromFloat(mix * 2 * 255)));
                c.right(Layout.right, caption_top, clock(&buf, self.status.total_frames / @max(1, self.status.sample_rate)), .caption, muted);
            } else {
                label(c, Layout.left, caption_top, 80, "Volume", .caption, draw.blend(paper, muted, @intFromFloat((mix - 0.5) * 2 * 255)));
                c.right(Layout.right, caption_top, std.fmt.bufPrint(&buf, "{d}", .{@as(u32, 128 - self.attenuation) * 100 / 112}) catch "", .caption, muted);
            }
        }

        pub fn renderTimelineInto(self: *State, pixels: *[320 * 240]u16, now: u64) void {
            var c = C.init(pixels);
            c.text_cache = self.text_cache;
            if (self.text_cache) |cache| cache.beginFrame();
            c.fill(0, 188, 320, 42, paper);
            if (self.playing_track != null) self.timeline(c, now);
        }

        fn render(self: *State, now: u64) void {
            self.renderInto(lcd.framebuffer, now);
        }

        fn albumProgressWidth() u16 {
            return if (diag.report.scan_active != 0 and diag.report.scan_total > 0) @intCast(@min(Layout.width, @as(u64, diag.report.scan_visited) * Layout.width / diag.report.scan_total)) else 0;
        }

        pub fn renderInto(self: *State, pixels: *[320 * 240]u16, now: u64) void {
            var c = C.init(pixels);
            c.text_cache = self.text_cache;
            if (self.text_cache) |cache| cache.beginFrame();
            const view = self.snapshot();
            const retained = self.screen == .albums and self.rendered_screen == .albums and self.rendered_surface == @intFromPtr(pixels);
            const scan_width = if (self.screen == .albums) albumProgressWidth() else 0;
            const cover_revision = self.covers.revision.load(.acquire);
            var scene_changed = !retained or self.rendered_cover_revision != cover_revision;
            var visible: [7]CoverModel = undefined;
            var visible_count: usize = 0;
            const inspect_scene = self.screen == .albums and (scene_changed or self.rendered_flow != self.flow or self.rendered_revision != view.revision);
            if (inspect_scene) {
                const anchor: i32 = @intFromFloat(@round(self.flow));
                for ([_]i32{ -3, 3, -2, 2, -1, 1, 0 }) |offset| {
                    const i = anchor + offset;
                    if (i < 0 or i >= view.album_count) continue;
                    const album = view.albums[@intCast(i)];
                    const distance = @as(f32, @floatFromInt(i)) - self.flow;
                    if (@abs(distance) > 3.4) continue;
                    const model = CoverModel{ .id = album.id, .texture = self.covers.get(album.id, album.art), .distance = distance };
                    visible[visible_count] = model;
                    if (!scene_changed) {
                        if (visible_count >= self.rendered_cover_count) scene_changed = true else {
                            const previous = self.rendered_covers[visible_count];
                            scene_changed = previous.id != model.id or previous.texture != model.texture or previous.distance != model.distance;
                        }
                    }
                    visible_count += 1;
                }
                scene_changed = scene_changed or visible_count != self.rendered_cover_count;
            }
            const header_changed = !retained or self.rendered_selection != self.selection or self.rendered_count != view.album_count or self.rendered_battery != self.battery_mv or self.rendered_charging != self.charging or self.rendered_scan_active != diag.report.scan_active or self.rendered_scan_width != scan_width;
            const caption_changed = !retained or self.rendered_selection != self.selection or self.rendered_revision != view.revision;
            if (!retained) c.clear(paper) else if (scene_changed) c.fill(0, Layout.row_top, 320, 193 - Layout.row_top, paper);
            var buf: [96]u8 = undefined;
            for (&self.covers.requested) |*request| request.* = .{};
            switch (self.screen) {
                .home => {
                    self.header(c, "Music", std.fmt.bufPrint(&buf, "{d} tracks", .{view.track_count}) catch "");
                    for (self.first..@min(home_items.len, self.first + self.visibleRows())) |i| {
                        const name = home_items[i].name;
                        const y: i32 = Layout.row_top + @as(i32, @intCast(i - self.first)) * Layout.row_height;
                        if (i == self.selection) highlightRow(c, y);
                        label(c, Layout.left, Layout.rowText(y, .reading), 268, name, .reading, if (i == self.selection) accent else ink);
                        c.chevron(Layout.right - 6, y + 12, muted);
                    }
                },
                .library => {
                    self.header(c, "Library", std.fmt.bufPrint(&buf, "{d} albums", .{view.album_count}) catch "");
                    label(c, Layout.left, Layout.rowText(Layout.row_top, .reading), Layout.width, self.index.phase, .reading, ink);
                    for ([_][]const u8{ "Update library", "Verify library" }, 0..) |name, i| {
                        const y: i32 = 112 + @as(i32, @intCast(i)) * Layout.row_height;
                        if (i == self.selection) highlightRow(c, y);
                        label(c, Layout.left, Layout.rowText(y, .body), Layout.width, name, .body, ink);
                    }
                },
                .albums => {
                    const header_started = benchmarkClock();
                    if (header_changed) {
                        c.fill(0, 0, 320, Layout.row_top, paper);
                        self.header(c, "Albums", std.fmt.bufPrint(&buf, "{d} / {d}", .{ if (view.album_count > 0) self.selection + 1 else 0, view.album_count }) catch "");
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
                    if (scene_changed) {
                        var cards: [7]flow_scene.Card = undefined;
                        for (visible[0..visible_count], cards[0..visible_count]) |model, *card| card.* = .{ .texture = model.texture, .quad = flow_scene.project(model.distance) };
                        flow_scene.paintScene(.{ .pixels = pixels[Layout.row_top * 320 .. 193 * 320], .height = 193 - Layout.row_top, .origin_y = Layout.row_top }, cards[0..visible_count]);
                    }
                    if (inspect_scene) {
                        @memcpy(self.rendered_covers[0..visible_count], visible[0..visible_count]);
                        self.rendered_cover_count = visible_count;
                    }
                    const caption_started = benchmarkClock();
                    diag.report.cover_scene_max = @max(diag.report.cover_scene_max, caption_started -% scene_started);
                    if (caption_changed) {
                        c.fill(0, 193, 320, 47, paper);
                        if (view.album_count > 0) {
                            const album = view.albums[self.selection];
                            centered(c, Layout.capTop(200, .reading), Layout.width, album.title, .reading, ink);
                            centered(c, Layout.capBottom(224, .caption), Layout.width, album.artist, .caption, muted);
                        }
                    }
                    if (view.album_count == 0) centered(c, 105, 288, "No albums yet", .reading, muted);
                    diag.report.cover_caption_max = @max(diag.report.cover_caption_max, benchmarkClock() -% caption_started);
                    if (diag.report.scan_active != 0) {
                        c.rounded(Layout.scan_indicator_left, Layout.header_center - 1, 3, 3, 1, accent);
                        if (scan_width > 0) c.fill(Layout.left, 54, scan_width, 1, accent);
                    }
                },
                .artists, .artist, .tracks => {
                    const artist = if (self.artistRank()) |i| view.artists[i] else null;
                    const title = switch (self.screen) {
                        .artists => "Artists",
                        .artist => if (artist) |a| a.name else "Artist",
                        .tracks => switch (self.track_scope) {
                            .all => "All Songs",
                            .artist => if (artist) |a| a.name else "Songs",
                            .album => if (view.albumIndex(self.album_id)) |i| view.albums[i].title else "Tracks",
                        },
                        else => unreachable,
                    };
                    self.header(c, title, "");
                    var i = self.first;
                    while (i < @min(self.rows(), self.first + self.visibleRows())) : (i += 1) {
                        const name = switch (self.screen) {
                            .artists => view.artists[i].name,
                            .artist => if (i == 0) "All Songs" else view.albums[artist.?.first_album + i - 1].title,
                            .tracks => (self.trackAt(i) orelse break).meta.title,
                            else => unreachable,
                        };
                        const y: i32 = Layout.row_top + @as(i32, @intCast(i - self.first)) * Layout.row_height;
                        if (i == self.selection) highlightRow(c, y);
                        label(c, Layout.left, Layout.rowText(y, .reading), Layout.width, name, .reading, if (i == self.selection) accent else ink);
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
                        self.image(c, album, Layout.left, Layout.row_top, 112, 112, 0);
                        label(c, 144, Layout.capTop(Layout.row_top, .title), 160, track.meta.title, .title, ink);
                        label(c, 144, Layout.capTop(100, .body), 160, track.meta.artist, .body, ink);
                        label(c, 144, Layout.capTop(124, .caption), 160, track.meta.album, .caption, muted);
                        label(c, 144, Layout.capBottom(176, .caption), 160, track.meta.codec, .caption, muted);
                        self.timeline(c, now);
                    } else label(c, 16, 100, 288, "Choose a track", .title, ink);
                },
            }
            if (self.screen != .player and self.screen != .albums and diag.report.scan_active != 0) {
                c.fill(0, Layout.footer_top, 320, 240 - Layout.footer_top, paper);
                c.fill(Layout.left, Layout.footer_top, Layout.width, 1, line);
                label(c, Layout.left, Layout.capTop(224, .caption), 175, self.index.phase, .caption, muted);
                c.right(Layout.right, Layout.capTop(224, .caption), std.fmt.bufPrint(&buf, "{d} / {d}", .{ diag.report.scan_visited, diag.report.scan_total }) catch "", .caption, muted);
                if (diag.report.scan_total > 0) c.fill(Layout.left, 238, @intCast(@min(Layout.width, @as(u64, diag.report.scan_visited) * Layout.width / diag.report.scan_total)), 2, accent);
            }
            if (self.screen == .player and diag.report.scan_active != 0) c.rounded(266, 22, 4, 4, 2, accent);
            if (self.jump_position) |position| {
                c.clear(paper);
                self.header(c, "Jump", "");
                centered(c, 86, 288, std.fmt.bufPrint(&buf, "{d}%", .{position * 5}) catch "", .serif, ink);
                c.rounded(16, 139, 288, 8, 3, line);
                const width: u16 = @intCast(position * 288 / 20);
                if (width > 0) c.rounded(16, 139, width, 8, 3, accent);
                const target = (self.rows() -| 1) * position / 20;
                const text = switch (self.screen) {
                    .albums => if (self.rows() > 0) view.albums[target].title else "",
                    .artists => if (self.rows() > 0) view.artists[target].name else "",
                    .tracks => if (self.trackAt(target)) |track| track.meta.title else "",
                    else => "",
                };
                centered(c, 167, 288, text, .reading, muted);
            }
            self.covers.publishRequests();
            self.rendered_surface = @intFromPtr(pixels);
            self.rendered_screen = if (self.jump_position != null) null else self.screen;
            self.rendered_selection = self.selection;
            self.rendered_revision = view.revision;
            self.rendered_count = view.album_count;
            self.rendered_battery = self.battery_mv;
            self.rendered_charging = self.charging;
            self.rendered_scan_active = diag.report.scan_active;
            self.rendered_scan_width = scan_width;
            self.rendered_flow = self.flow;
            self.rendered_cover_revision = cover_revision;
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
        var waiting_launch: bool = false;
        pub fn waitingForLaunch() bool {
            return waiting_launch;
        }
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
            waiting_launch = false;
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

test "device samples drive accelerated lists and release cancels repeats" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const tracks = try std.testing.allocator.alloc(core.Track, 4096);
    defer std.testing.allocator.free(tracks);
    for (tracks, 0..) |*track, i| track.* = .{ .id = i + 1, .path = "Synthetic/track.flac", .stamp = .{}, .meta = .{ .title = "Synthetic", .album = "Album", .track = @intCast(i + 1) } };
    try fixture.pair.publish(&.{}, tracks, 1, true);
    var state = fixture.state();
    state.navigate(.tracks);
    state.track_scope = .all;
    const capture = @import("input_capture.zig");
    var stream = @import("music_input.zig").Stream.init(.{ .at = 0, .buttons = 0, .wheel = 0 }, 6);
    stream.observe(.{ .at = 10, .buttons = capture.Button.next.mask(), .wheel = 0 });
    _ = stream.dispatch(&state, 16, 16, 1, false);
    try std.testing.expectEqual(1, state.selection);
    for (17..6000) |now| _ = stream.dispatch(&state, @intCast(now), now, 1, false);
    try std.testing.expectEqual(tracks.len - 1, state.selection);
    stream.observe(.{ .at = 6000, .buttons = 0, .wheel = 0 });
    _ = stream.dispatch(&state, 6000, 6000, 1, false);
    _ = stream.dispatch(&state, 6006, 6006, 1, false);
    _ = stream.dispatch(&state, 16006, 16006, 1, false);
    try std.testing.expectEqual(tracks.len - 1, state.selection);
    stream.observe(.{ .at = 16007, .buttons = capture.Button.previous.mask(), .wheel = 0 });
    _ = stream.dispatch(&state, 16013, 16013, 1, false);
    try std.testing.expectEqual(tracks.len - 2, state.selection);
}

test "device wheel capture accelerates through the controller without button repeats" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const tracks = try std.testing.allocator.alloc(core.Track, 100);
    defer std.testing.allocator.free(tracks);
    for (tracks, 0..) |*track, i| track.* = .{ .id = i + 1, .path = "Synthetic/track.flac", .stamp = .{}, .meta = .{ .title = "Synthetic", .album = "Album", .track = @intCast(i + 1) } };
    try fixture.pair.publish(&.{}, tracks, 1, true);
    var state = fixture.state();
    state.navigate(.tracks);
    state.track_scope = .all;
    var stream = @import("music_input.zig").Stream.init(.{ .at = 0, .buttons = 0, .wheel = 0 }, 6);
    for (0..12) |detent| {
        for ([_]u2{ 2, 3, 1, 0 }, 0..) |phase, edge| {
            const now: u32 = @intCast(1 + detent * 20 + edge * 5);
            stream.observe(.{ .at = now, .buttons = 0, .wheel = phase });
            _ = stream.dispatch(&state, now, now, 1, false);
        }
    }
    try std.testing.expect(state.selection > 12);
    const stopped = state.selection;
    _ = stream.dispatch(&state, 10000, 10000, 1, false);
    try std.testing.expectEqual(stopped, state.selection);
}

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
        state.charging = step % 2 != 0;
        state.battery_mv = if (step < 10) 0 else if (step < 20) 3300 else if (step < 30) 3800 else 4200;
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

test "artist focus and its selected album survive progressive insertions" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    TestPlatform.Display.reset();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .title = "First", .album = "A Album", .album_artist = "Alpha" } },
        .{ .id = 2, .path = "B/1", .stamp = .{}, .meta = .{ .title = "Second", .album = "B Album", .album_artist = "Beta" } },
        .{ .id = 3, .path = "C/1", .stamp = .{}, .meta = .{ .title = "Third", .album = "C Album", .album_artist = "Beta" } },
    };
    try fixture.pair.publish(&.{}, tracks[2..], 42, true);
    var state = fixture.state();
    state.navigate(.artists);
    state.frame(0);
    const artist = state.selected_id;
    try fixture.pair.publish(&.{}, tracks[0..1] ++ tracks[2..], 42, true);
    state.frame(33);
    try std.testing.expectEqual(artist, state.snapshot().artistId(state.selection));
    _ = state.handle(.select, 34, false);
    _ = state.handle(.down, 35, false);
    const album = state.selected_id;
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    state.frame(66);
    const group = state.snapshot().artists[state.artistRank().?];
    try std.testing.expectEqual(album, state.snapshot().albums[group.first_album + state.selection - 1].id);
    try std.testing.expectEqual(2, state.selection);
    _ = state.handle(.select, 67, false);
    _ = state.handle(.back, 68, false);
    try std.testing.expectEqual(album, state.selected_id);
    _ = state.handle(.up, 69, false);
    _ = state.handle(.up, 70, false);
    try fixture.pair.publish(&.{}, tracks[2..], 42, true);
    state.frame(99);
    try std.testing.expectEqual(0, state.selection);
}

test "artist song selection retains track identity and filters out compilation performers" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    TestPlatform.Display.reset();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .title = "A song", .album = "Album", .album_artist = "Test Ensemble" } },
        .{ .id = 2, .path = "A/2", .stamp = .{}, .meta = .{ .title = "B song", .album = "Album", .album_artist = "Test Ensemble" } },
        .{ .id = 3, .path = "A/3", .stamp = .{}, .meta = .{ .title = "C song", .album = "Album", .album_artist = "Test Ensemble" } },
        .{ .id = 4, .path = "B/1", .stamp = .{}, .meta = .{ .title = "Other", .album = "Compilation", .album_artist = "Various Artists", .artist = "Test Ensemble" } },
    };
    try fixture.pair.publish(&.{}, tracks[1..], 42, true);
    var state = fixture.state();
    state.artist_id = state.snapshot().artistId(state.snapshot().albums[state.snapshot().track_groups[0]].artist_index);
    state.track_scope = .artist;
    state.navigate(.tracks);
    state.frame(0);
    try std.testing.expectEqual(2, state.rows());
    _ = state.handle(.down, 1, false);
    try std.testing.expectEqual(3, state.selected_id);
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    state.frame(33);
    try std.testing.expectEqual(3, state.rows());
    try std.testing.expectEqual(3, state.trackAt(state.selection).?.id);
    try std.testing.expectEqual(2, state.selection);
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
    state.refreshBattery(3799, false, 120);
    try std.testing.expectEqual(4100, state.battery_mv);
    try std.testing.expect(!state.major);
    _ = state.animation.tick(240);
    state.refreshBattery(3799, false, 240);
    try std.testing.expectEqual(3799, state.battery_mv);
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

test "stationary carousel retains its scene through scan updates, cover replacement and jump dismissal" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .title = "One", .album = "First", .album_artist = "Artist" } },
        .{ .id = 2, .path = "B/1", .stamp = .{}, .meta = .{ .title = "Two", .album = "Second", .album_artist = "Artist" } },
    };
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    state.navigate(.albums);
    const fresh = try std.testing.allocator.create([320 * 240]u16);
    defer std.testing.allocator.destroy(fresh);
    const retained = try std.testing.allocator.create([320 * 240]u16);
    defer std.testing.allocator.destroy(retained);
    for (0..80) |step| {
        test_diag.report.scan_active = if (step < 60) 1 else 0;
        test_diag.report.scan_total = 8192;
        test_diag.report.scan_visited = @intCast(step * 64);
        if (step == 15) {
            const album = state.snapshot().albums[0];
            const load = covers.Cache.Load{ .slot = 0, .request = .{ .id = album.id, .art = album.art } };
            fixture.cache.begin(load);
            fixture.cache.tiles[0] = .{ .width = 128, .height = 128, .pixels = @splat(0x1234) };
            fixture.cache.publish(load);
        }
        if (step == 30) try fixture.pair.publish(&.{}, tracks[0..1], 42, true);
        if (step == 40) state.jump_position = 10;
        if (step == 45) state.jump_position = null;
        state.renderInto(retained, step * 17);
        var reference = state;
        reference.rendered_screen = null;
        reference.renderInto(fresh, step * 17);
        try std.testing.expectEqualSlices(u16, fresh, retained);
    }
}

test "scan counters schedule frames only for visible changes and phase transitions" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    TestPlatform.Display.reset();
    TestPlatform.Display.latency = 0;
    var state = fixture.state();
    state.navigate(.player);
    test_diag.report.scan_active = 1;
    test_diag.report.scan_total = 8192;
    for (0..1000) |now| {
        TestPlatform.milliseconds = now;
        test_diag.report.scan_visited = @intCast(now);
        state.frame(now);
    }
    try std.testing.expectEqual(1, TestPlatform.Display.submissions);
    test_diag.report.scan_active = 0;
    TestPlatform.milliseconds = 1000;
    state.frame(1000);
    try std.testing.expectEqual(2, TestPlatform.Display.submissions);
    state.navigate(.albums);
    test_diag.report.scan_active = 1;
    test_diag.report.scan_visited = 0;
    for (1001..1400) |now| {
        TestPlatform.milliseconds = now;
        test_diag.report.scan_visited = @intCast((now - 1001) % 20);
        state.frame(now);
    }
    // These small count changes never advance the one-pixel progress rule.
    try std.testing.expectEqual(3, TestPlatform.Display.submissions);
    state.navigate(.library);
    TestPlatform.milliseconds = 1500;
    state.frame(1500);
    const before = TestPlatform.Display.submissions;
    fixture.index_state.phase = "Preparing covers";
    TestPlatform.milliseconds = 1600;
    state.frame(1600);
    try std.testing.expectEqual(before + 1, TestPlatform.Display.submissions);
}

test "cooperative indexing services animated UI and PCM while retaining immutable DMA frames" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    TestPlatform.Display.reset();
    TestPlatform.Display.latency = 19;
    const tracks = try std.testing.allocator.alloc(core.Track, views.max_tracks);
    defer std.testing.allocator.free(tracks);
    for (tracks, 0..) |*track, i| track.* = .{ .id = i + 1, .path = "Album/track.flac", .stamp = .{}, .meta = .{ .title = "Synthetic", .album = "Album", .track = @intCast(views.max_tracks - i) } };
    for ([_]Screen{ .player, .albums }) |screen| {
        TestPlatform.Display.reset();
        TestPlatform.Display.latency = 19;
        try fixture.pair.publish(&.{}, tracks[0..1], 42, true);
        var state = fixture.state();
        state.navigate(screen);
        if (screen == .albums) state.flow = -0.8;
        state.queue(&tracks[0]);
        state.playing_track = state.track_store.begin().?;
        state.requested_track = null;
        state.status = .{ .phase = .playing, .sample_rate = 192000, .output_format = .signed_24_in_u32, .total_frames = 192000 * 60, .played_frames = 0 };
        state.animation.request(0, 75);
        test_diag.report.scan_active = 1;
        test_diag.report.scan_total = views.max_tracks;
        const reservoir = @import("pcm_reservoir.zig");
        const output = @import("audio_output.zig");
        const Audio = struct {
            storage: [4096]reservoir.StereoFrame = undefined,
            supply: [1920]reservoir.StereoFrame = @splat(.{ .left = 0x12340000, .right = -0x12340000 }),
            bytes: [1920 * 8]u8 align(4) = undefined,
        };
        const audio = try std.testing.allocator.create(Audio);
        defer std.testing.allocator.destroy(audio);
        audio.* = .{};
        @memset(&audio.storage, audio.supply[0]);
        const Observer = struct {
            state: *TestState,
            audio: *Audio,
            ring: reservoir.Ring,
            plan: output.Plan,
            now: u64 = 0,
            periods: u32 = 0,
            okay: bool = true,

            pub fn cancelled(self: *@This()) bool {
                self.now += 1;
                TestPlatform.milliseconds = self.now;
                if (self.now % 10 == 0) {
                    const rendered = output.renderPeriod(&self.ring, &self.audio.bytes, self.plan, output.unity_gain_q24) catch unreachable;
                    self.okay = self.okay and !rendered.underrun and rendered.frames == 1920;
                    self.okay = self.okay and std.mem.readInt(u32, self.audio.bytes[0..4], .little) == 0x123400;
                    self.okay = self.okay and std.mem.readInt(u32, self.audio.bytes[4..8], .little) == 0xedcc00;
                    self.okay = self.okay and self.ring.write(&self.audio.supply) == 1920;
                    self.periods += 1;
                    self.state.status.played_frames += 1920;
                }
                test_diag.report.scan_visited = @intCast(@min(views.max_tracks, self.now * 32));
                self.state.frame(self.now);
                self.okay = self.okay and !self.state.failure and !TestPlatform.Display.corrupted;
                return false;
            }
        };
        var observer = Observer{ .state = &state, .audio = audio, .ring = try reservoir.Ring.initFilled(&audio.storage, audio.storage.len), .plan = try output.Plan.init(192000, .signed_24_in_u32) };
        const old = fixture.pair.current();
        const revision = try fixture.pair.prepareCooperative(&.{}, tracks, 42, true, &observer);
        try std.testing.expect(fixture.pair.current() == old);
        try std.testing.expect(observer.okay);
        try std.testing.expect(observer.periods > 0);
        try std.testing.expect(TestPlatform.Display.submissions > 1);
        fixture.pair.commit(revision);
        try std.testing.expectEqual(views.max_tracks, fixture.pair.current().track_count);
    }
}

test "stationary flow still prefetches a newly selected destination before motion advances" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .album = "A" } },
        .{ .id = 2, .path = "B/1", .stamp = .{}, .meta = .{ .album = "B" } },
        .{ .id = 3, .path = "C/1", .stamp = .{}, .meta = .{ .album = "C" } },
        .{ .id = 4, .path = "D/1", .stamp = .{}, .meta = .{ .album = "D" } },
        .{ .id = 5, .path = "E/1", .stamp = .{}, .meta = .{ .album = "E" } },
    };
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    var state = fixture.state();
    state.navigate(.albums);
    const pixels = try std.testing.allocator.create([320 * 240]u16);
    defer std.testing.allocator.destroy(pixels);
    state.renderInto(pixels, 100);
    const revision = fixture.cache.request_revision.load(.acquire);
    state.selection = 3;
    // The event has retargeted movement, but elapsed animation time is zero.
    state.renderInto(pixels, 100);
    const destination_neighbour = state.snapshot().albums[4].id;
    var found = false;
    for (fixture.cache.requested) |request| if (request.id == destination_neighbour) {
        found = true;
    };
    try std.testing.expect(found);
    try std.testing.expect(fixture.cache.request_revision.load(.acquire) != revision);
}

test "volume commands apply immediately without animating hidden controls" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    TestPlatform.Display.reset();
    TestPlatform.Display.latency = 0;
    const track = core.Track{ .id = 1, .path = "Album/1", .stamp = .{}, .meta = .{ .title = "Synthetic", .album = "Album" } };
    try fixture.pair.publish(&.{}, &.{track}, 42, true);
    var state = fixture.state();
    state.queue(&track);
    state.playing_track = state.track_store.begin().?;
    state.requested_track = null;
    state.navigate(.albums);
    for (0..50) |now| {
        TestPlatform.milliseconds = now;
        state.frame(now);
    }
    const before = TestPlatform.Display.submissions;
    const old_volume = state.attenuation;
    const command = state.handle(.volume_up, 50, true);
    try std.testing.expectEqual(state.attenuation, command.set_attenuation);
    try std.testing.expect(state.attenuation < old_volume);
    for (50..110) |now| {
        TestPlatform.milliseconds = now;
        state.frame(now);
        try std.testing.expect(!state.isAnimating(now));
    }
    try std.testing.expectEqual(before, TestPlatform.Display.submissions);
    // Entering Now Playing during the same gesture shows its current phase.
    state.navigate(.player);
    try std.testing.expect(state.isAnimating(110));
    try std.testing.expect(state.animation.mix(110) > 0);
    for (110..300) |now| {
        TestPlatform.milliseconds = now;
        state.frame(now);
    }
    try std.testing.expect(TestPlatform.Display.submissions > before + 1);
    try std.testing.expect(!state.failure);
}

test "a scheduled display launch cannot be delayed by painting the next canvas" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.pair.publish(&.{}, &.{}, 1, true);
    TestPlatform.Display.reset();
    defer TestPlatform.Display.reset();
    TestPlatform.Display.latency = 0;
    var state = fixture.state();
    TestPlatform.milliseconds = 17;
    state.frame(17);
    const rendered_at = state.pending_frame.last_render;
    const submissions = TestPlatform.Display.submissions;
    state.dirty = true;
    TestPlatform.Display.waiting_launch = true;
    TestPlatform.milliseconds = 34;
    state.frame(34);
    try std.testing.expectEqual(rendered_at, state.pending_frame.last_render);
    try std.testing.expectEqual(submissions, TestPlatform.Display.submissions);
    TestPlatform.Display.waiting_launch = false;
    TestPlatform.milliseconds = 40;
    state.frame(40);
    try std.testing.expectEqual(@as(u64, 40), state.pending_frame.last_render);
    try std.testing.expectEqual(submissions + 1, TestPlatform.Display.submissions);
}
