//! Shared music interaction, animation and rasterization. Platform supplies
//! presentation, indexing and diagnostics; rendering performs no storage I/O.
const std = @import("std");
const core = @import("library.zig");
const views = @import("progressive_view.zig");
const covers = @import("cover_cache.zig");
const media = @import("f20_media.zig");
const flow_scene = @import("cover_flow.zig");
const navigation = @import("navigation.zig");
const folders = @import("folder_view.zig");
const cover_loading = @import("cover_loading.zig");

const chrome = @import("music_chrome.zig");
const battery_status = @import("battery.zig");

pub const Input = enum(u3) { select, back, home, up, down, volume_up, volume_down, menu };

pub const Screen = enum { home, albums, tracks, player, library, artists, artist, settings, music, folders, themes, display };
pub const TrackScope = enum { album, artist, all, queue, folder };
const MusicItem = enum { albums, artists, songs, shuffle_all };
const music_items = [_]MusicItem{ .albums, .artists, .songs, .shuffle_all };
const Collection = struct { scope: TrackScope, album: u64 = 0, artist: u64 = 0, directory: []const u8 = "" };
const ContextMenu = struct {
    kind: enum { collection, player },
    collection: Collection = .{ .scope = .all },
    selection: usize = 0,
    jump: bool = false,
    empty: bool = false,

    fn count(self: ContextMenu) usize {
        return if (self.empty) 0 else if (self.kind == .player) 3 else if (self.jump) 3 else 2;
    }
};
const Location = struct {
    screen: Screen,
    selection: usize,
    first: usize,
    album: u64,
    artist: u64,
    scope: TrackScope,
    selected_id: u64,
    track_anchor: u64,
};
const theme = @import("runtime_theme.zig");
const builtin_theme_count = @import("builtin_themes.zig").names.len;

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
        menu: ?ContextMenu = null,
        menu_directory: [4096]u8 = undefined,
        history: [8]Location = undefined,
        history_count: usize = 0,
        appearance: chrome.Appearance = .light,
        theme_store: @import("runtime_theme.zig").Store = .{},
        rendered_theme_revision: u32 = 0,
        rendered_track_id: u64 = 0,
        rendered_phase: media.PlaybackPhase = .preparing,
        rendered_scan_phase: []const u8 = "",
        theme_family: @import("preferences.zig").Theme = .classic,
        display_timeout: @import("preferences.zig").Timeout = .seconds30,
        display_asleep: bool = false,
        last_activity: ?u64 = null,
        power_wake_only: bool = false,
        locked: bool = false,
        power_at: ?u64 = null,
        seek_frame: ?u64 = null,
        shuffle_seed: u64 = 0x4741494e,

        album_id: u64 = 0,
        artist_id: u64 = 0,
        album_rank: ?usize = null,
        artist_rank: ?usize = null,
        track_scope: TrackScope = .album,
        tracks_return: Screen = .albums,
        input_policy: navigation.Policy = .{},
        raw_held: u8 = 0,
        cover_plan: ?cover_loading.Plan = null,
        cover_plan_revision: u32 = 0,
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
        requested_start_frame: u64 = 0,
        resume_paused: bool = false,
        last_playback_phase: media.PlaybackPhase = .preparing,
        folder_view: folders.View = .{},
        folder_path: [4096]u8 = undefined,
        folder_path_len: usize = 0,
        folder_revision: u32 = std.math.maxInt(u32),
        folder_entries_address: usize = 0,
        folder_entries_count: usize = 0,
        folder_selections: [16]usize = @splat(0),
        folder_depth: usize = 0,
        folder_error: bool = false,
        playing_track: ?*const core.Track = null,
        attenuation: u8 = 64,
        replay_gain: @import("replay_gain.zig").Settings = .{},
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
        external_power: bool = false,
        failure: bool = false,
        rendered_surface: usize = 0,
        rendered_screen: ?Screen = null,
        rendered_selection: usize = 0,
        rendered_revision: u32 = 0,
        rendered_count: usize = 0,
        rendered_battery: u32 = 0,
        rendered_charging: bool = false,
        rendered_external_power: bool = false,
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
            self.cancelInput(self.input_policy.held);
            self.requested_start_frame = 0;
            self.resume_paused = false;
            self.requested_track = self.track_store.queue(track) catch |failure| {
                self.fail(failure);
                return;
            };
        }

        pub fn navigate(self: *State, screen: Screen) void {
            self.cancelInput(self.input_policy.held);
            self.jump_position = null;
            self.menu = null;
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
                .queue => view.trackById(self.track_store.order.at(position) orelse return null),
                .folder => self.collectionTrack(.{ .scope = .folder, .directory = self.folderPath() }, position),
            };
        }

        fn albumRank(self: *const State) ?usize {
            return if (self.revision == self.snapshot().revision) self.album_rank else self.snapshot().albumIndex(self.album_id);
        }

        fn artistRank(self: *const State) ?usize {
            return if (self.revision == self.snapshot().revision) self.artist_rank else self.snapshot().artistIndex(self.artist_id);
        }

        fn folderPath(self: *const State) []const u8 {
            return self.folder_path[0..self.folder_path_len];
        }

        fn folderSource(self: *const State) folders.Source {
            return .{ .entries = if (diag.catalog) |catalog| catalog.value.entries else &.{}, .tracks = self.snapshot().tracks[0..self.snapshot().track_count] };
        }

        fn refreshFolder(self: *State) void {
            self.folder_error = false;
            const source = self.folderSource();
            self.folder_entries_address = @intFromPtr(source.entries.ptr);
            self.folder_entries_count = source.entries.len;
            self.folder_view.build(source, self.folderPath()) catch {
                self.folder_error = true;
                self.folder_view.count = 0;
            };
            self.folder_revision = self.snapshot().revision;
            if (self.selected_id != 0) for (0..self.folder_view.count) |i| {
                if (core.hash(self.folderRow(i).?.path) == self.selected_id) {
                    self.selection = i;
                    break;
                }
            };
            self.selection = @min(self.selection, self.folder_view.count -| 1);
            if (self.folderRow(self.selection)) |row| self.selected_id = core.hash(row.path);
            self.dirty = true;
            self.major = true;
            self.pending_frame.ready = false;
            self.rendered_screen = null;
        }

        fn folderRow(self: *const State, position: usize) ?folders.Row {
            return self.folder_view.row(self.folderSource(), self.folderPath(), position);
        }

        fn enterFolder(self: *State, path: []const u8) void {
            if (path.len > self.folder_path.len or self.folder_depth == self.folder_selections.len) return;
            self.folder_selections[self.folder_depth] = self.selection;
            self.folder_depth += 1;
            @memmove(self.folder_path[0..path.len], path);
            self.folder_path_len = path.len;
            self.selection = 0;
            self.selected_id = 0;
            self.first = 0;
            self.refreshFolder();
            self.rendered_screen = null;
            self.major = true;
            self.dirty = true;
        }

        fn location(self: *const State) Location {
            return .{ .screen = self.screen, .selection = self.selection, .first = self.first, .album = self.album_id, .artist = self.artist_id, .scope = self.track_scope, .selected_id = self.selected_id, .track_anchor = self.selected_track_anchor };
        }

        fn push(self: *State, screen: Screen) void {
            if (self.history_count == self.history.len) {
                @memmove(self.history[0 .. self.history.len - 1], self.history[1..]);
                self.history_count -= 1;
            }
            self.history[self.history_count] = self.location();
            self.history_count += 1;
            self.navigate(screen);
        }

        fn goBack(self: *State) void {
            if (self.screen == .folders and self.folder_path_len != 0) {
                self.selected_id = core.hash(self.folderPath());
                const parent = std.fs.path.dirname(self.folderPath()) orelse "";
                self.folder_path_len = parent.len;
                self.folder_depth -|= 1;
                self.selection = self.folder_selections[self.folder_depth];
                self.first = 0;
                self.refreshFolder();
                self.selection = @min(self.selection, self.rows() -| 1);
                self.ensureVisible();
                self.rendered_screen = null;
                self.major = true;
                self.dirty = true;
                return;
            }
            if (self.history_count == 0) {
                self.navigate(if (self.screen == .home or self.screen == .music) .home else .music);
                return;
            }
            self.history_count -= 1;
            const previous = self.history[self.history_count];
            self.navigate(previous.screen);
            self.album_id = previous.album;
            self.artist_id = previous.artist;
            self.track_scope = previous.scope;
            self.selected_id = previous.selected_id;
            self.selected_track_anchor = previous.track_anchor;
            self.selection = previous.selection;
            self.first = previous.first;
            self.flow = @floatFromInt(self.selection);
            self.reconcile();
            self.ensureVisible();
        }

        fn collectionCount(self: *const State, collection: Collection) usize {
            const view = self.snapshot();
            return switch (collection.scope) {
                .all => view.track_count,
                .album => if (view.albumIndex(collection.album)) |i| view.albums[i].count else 0,
                .artist => if (view.artistIndex(collection.artist)) |i| view.artists[i].track_count else 0,
                .queue => self.track_store.order.count,
                .folder => count: {
                    Platform.trace(.library_work, benchmarkClock(), @intCast(view.track_count));
                    var count: usize = 0;
                    for (view.tracks[0..view.track_count]) |track| if (std.mem.eql(u8, std.fs.path.dirname(track.path) orelse "", collection.directory)) {
                        count += 1;
                    };
                    break :count count;
                },
            };
        }

        fn collectionTrack(self: *const State, collection: Collection, position: usize) ?*const core.Track {
            const view = self.snapshot();
            return switch (collection.scope) {
                .all => if (position < view.track_count) view.tracks[view.title_order[position]] else null,
                .album => view.albumTrack(view.albumIndex(collection.album) orelse return null, position),
                .artist => view.artistTrack(view.artistIndex(collection.artist) orelse return null, position),
                .queue => view.trackById(self.track_store.order.at(position) orelse return null),
                .folder => match: {
                    var rank: usize = 0;
                    for (view.tracks[0..view.track_count]) |track| {
                        if (!std.mem.eql(u8, std.fs.path.dirname(track.path) orelse "", collection.directory)) continue;
                        if (rank == position) break :match track;
                        rank += 1;
                    }
                    break :match null;
                },
            };
        }

        fn currentCollection(self: *const State) ?Collection {
            const view = self.snapshot();
            return switch (self.screen) {
                .home, .music => .{ .scope = .all },
                .albums => if (self.selection < view.album_count) .{ .scope = .album, .album = view.albums[self.selection].id } else null,
                .artists => if (self.selection < view.artist_count) .{ .scope = .artist, .artist = view.artistId(self.selection) } else null,
                .artist => if (view.artistIndex(self.artist_id)) |i| if (self.selection == 0) .{ .scope = .artist, .artist = self.artist_id } else .{ .scope = .album, .album = view.albums[view.artists[i].first_album + self.selection - 1].id } else null,
                .tracks => .{ .scope = self.track_scope, .album = self.album_id, .artist = self.artist_id, .directory = self.folderPath() },
                .folders => .{ .scope = .folder, .directory = if (self.folderRow(self.selection)) |row| if (row.directory) row.path else self.folderPath() else self.folderPath() },
                else => null,
            };
        }

        fn nextSeed(self: *State, now: u64) u64 {
            self.shuffle_seed +%= now +% 0x9e3779b97f4a7c15;
            return self.shuffle_seed;
        }

        fn startCollection(self: *State, source: Collection, selected_track: ?u64, shuffled: bool, now: u64) void {
            const count = self.collectionCount(source);
            if (count == 0) return;
            if (source.scope == .queue) {
                // The queue already owns its membership; do not clear it while
                // resolving itself or replace it from the latest catalogue.
                if (selected_track) |id| _ = self.track_store.order.select(id);
            } else {
                if (count > self.track_store.order.capacity()) {
                    self.fail(error.QueueFull);
                    return;
                }
                self.track_store.order.clear();
                if (source.scope == .folder) {
                    const view = self.snapshot();
                    for (view.tracks[0..view.track_count]) |track| {
                        if (!std.mem.eql(u8, std.fs.path.dirname(track.path) orelse "", source.directory)) continue;
                        self.track_store.order.append(track.id) catch unreachable;
                    }
                    const Sort = struct {
                        view: *const views.Snapshot,
                        pub fn less(ctx: @This(), left: u64, right: u64) bool {
                            return core.lessText(ctx.view.trackById(left).?.path, ctx.view.trackById(right).?.path);
                        }
                    };
                    self.track_store.order.sortCanonical(Sort{ .view = view });
                } else for (0..count) |i| {
                    const item = self.collectionTrack(source, i) orelse {
                        self.fail(error.InvalidSelection);
                        return;
                    };
                    self.track_store.order.append(item.id) catch |failure| {
                        self.fail(failure);
                        return;
                    };
                }
                if (selected_track) |id| _ = self.track_store.order.select(id);
                if (shuffled) self.track_store.order.shuffle(self.nextSeed(now), false);
            }
            if (self.track_store.order.at(self.track_store.order.cursor)) |id| {
                if (self.snapshot().trackById(id)) |track| self.queue(track);
            }
        }

        fn startContext(self: *State, track: *const core.Track) void {
            self.startCollection(.{ .scope = self.track_scope, .album = self.album_id, .artist = self.artist_id, .directory = self.folderPath() }, track.id, false, 0);
        }

        fn openMenu(self: *State) void {
            if (self.menu != null) {
                self.menu = null;
            } else if (self.screen == .player or (self.screen == .tracks and self.track_scope == .queue)) {
                if (self.playing_track == null) return;
                self.menu = .{ .kind = .player };
            } else if (self.currentCollection()) |source| {
                if (self.screen == .home and self.selection != 0) return;
                const count = self.collectionCount(source);
                if (count == 0 and self.screen != .folders) return;
                var captured = source;
                if (source.scope == .folder) {
                    if (source.directory.len > self.menu_directory.len) return;
                    @memcpy(self.menu_directory[0..source.directory.len], source.directory);
                    captured.directory = self.menu_directory[0..source.directory.len];
                }
                self.menu = .{ .kind = .collection, .collection = captured, .jump = self.rows() > 8, .empty = count == 0 };
            } else return;
            self.cancelInput(self.input_policy.held);
            if (self.menu != null) self.covers.clearRequests();
            self.rendered_screen = null;
            self.pending_frame.ready = false;
            self.dirty = true;
            self.major = true;
        }

        fn menuSelect(self: *State, now: u64, playing: bool) media.PlaybackCommand {
            const menu = self.menu.?;
            if (menu.empty) return .none;
            if (menu.kind == .player) switch (menu.selection) {
                0 => {
                    self.menu = null;
                    if (self.screen != .tracks or self.track_scope != .queue) self.push(.tracks);
                    self.track_scope = .queue;
                    self.selection = self.track_store.order.cursor;
                    self.ensureVisible();
                },
                1 => {
                    const selected_track = if (self.screen == .tracks and self.track_scope == .queue) self.trackAt(self.selection) else null;
                    if (self.track_store.order.shuffled) self.track_store.order.unshuffle() else self.track_store.order.shuffle(self.nextSeed(now), true);
                    if (selected_track) |track| for (0..self.track_store.order.count) |i| {
                        if (self.track_store.order.at(i).? == track.id) {
                            self.selection = i;
                            break;
                        }
                    };
                    self.ensureVisible();
                },
                2 => self.track_store.order.repeat = switch (self.track_store.order.repeat) {
                    .off => .all,
                    .all => .one,
                    .one => .off,
                },
                else => unreachable,
            } else if (menu.selection == 2) {
                self.menu = null;
                return self.act(.jump, now, playing);
            } else {
                self.menu = null;
                self.startCollection(menu.collection, null, menu.selection == 1, now);
                if (self.requested_track != null) self.push(.player);
                if (playing and self.requested_track != null) return .stop;
            }
            self.rendered_screen = null;
            self.pending_frame.ready = false;
            self.dirty = true;
            self.major = true;
            return .none;
        }

        /// A newer explicit choice wins over a retiring worker's skip/seek.
        /// Faults never masquerade as EOF and advance through the queue.
        pub fn playbackFinished(self: *State, result: media.Result, failed: bool) void {
            if (self.requested_track != null or failed) return;
            switch (result.exit) {
                .stopped => {},
                .seek => if (self.playing_track) |track| {
                    const paused = self.status.phase == .paused;
                    self.queue(track);
                    self.requested_start_frame = result.seek_frame;
                    self.resume_paused = paused;
                },
                .next, .previous, .completed => {
                    if (result.exit == .completed and result.frames == 0) return;
                    const next = if (result.exit == .completed) self.finishedTrack() else self.neighbouringTrack(if (result.exit == .previous) -1 else 1);
                    if (next) |track| self.queue(track);
                },
            }
        }

        pub fn finishedTrack(self: *State) ?*const core.Track {
            if (self.playing_track) |track| {
                if (self.track_store.order.repeat == .one and self.snapshot().trackById(track.id) != null) return track;
            }
            return self.neighbouringTrack(1);
        }

        pub fn neighbouringTrack(self: *State, direction: i2) ?*const core.Track {
            const current = self.playing_track orelse return null;
            const view = self.snapshot();
            const Resolver = struct {
                view: *const views.Snapshot,
                pub fn contains(resolver: @This(), id: u64) bool {
                    return resolver.view.trackById(id) != null;
                }
            };
            if (self.track_store.order.select(current.id)) {
                const id = self.track_store.order.adjacent(direction, Resolver{ .view = view }) orelse return null;
                return view.trackById(id);
            }
            // Direct maintenance/folder selections have no captured list.
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
                .home => 2 + @as(usize, if (self.playing_track != null) 1 else 0),
                .music => music_items.len,
                .albums => self.snapshot().album_count,
                .artists => self.snapshot().artist_count,
                .artist => if (self.artistRank()) |i| 1 + @as(usize, self.snapshot().artists[i].album_count) else 0,
                .tracks => switch (self.track_scope) {
                    .album => if (self.albumRank()) |i| self.snapshot().albums[i].count else 0,
                    .artist => if (self.artistRank()) |i| self.snapshot().artists[i].track_count else 0,
                    .all => self.snapshot().track_count,
                    .queue => self.track_store.order.count,
                    .folder => self.collectionCount(.{ .scope = .folder, .directory = self.folderPath() }),
                },
                .library => 2,
                .settings => 4,
                .display => 4,
                .themes => builtin_theme_count + 2,
                .folders => self.folder_view.count,
                .player => 0,
            };
        }

        fn inputContext(self: *const State) navigation.Context {
            if (self.jump_position != null or self.menu != null) return .list;
            return switch (self.screen) {
                .albums => .covers,
                .player => .transport,
                else => .list,
            };
        }

        fn visibleRows(self: *const State) usize {
            return @max(1, self.theme_store.current().pages[@backingInt(self.page())].capacity);
        }

        fn ensureVisible(self: *State) void {
            if (self.menu != null) return;
            const span = self.theme_store.current().pages[@backingInt(self.page())];
            self.first = navigation.firstVisible(self.selection, self.first, self.visibleRows(), span.columns);
        }

        pub fn cancelInput(self: *State, held: u8) void {
            self.seek_frame = null;
            self.input_policy.cancel(held);
            self.raw_held = held;
        }

        pub fn preferences(self: *const State) @import("preferences.zig").Options {
            return .{ .theme = self.theme_family, .appearance = self.appearance, .attenuation = self.attenuation, .replay_gain = self.replay_gain.mode, .timeout = self.display_timeout };
        }

        pub fn applyPreferences(self: *State, options: @import("preferences.zig").Options) void {
            self.theme_family = options.theme;
            self.appearance = options.appearance;
            self.theme_store.select(options.theme, options.appearance);
            self.attenuation = options.attenuation;
            self.replay_gain.mode = options.replay_gain;
            self.display_timeout = options.timeout;
            self.dirty = true;
            self.major = true;
            self.rendered_screen = null;
            self.pending_frame.ready = false;
        }

        fn activity(self: *State, now: u64) void {
            self.last_activity = now;
            if (!self.display_asleep) return;
            self.display_asleep = false;
            self.rendered_screen = null;
            self.pending_frame.ready = false;
            self.dirty = true;
            self.major = true;
        }

        pub fn toggleLock(self: *State) void {
            self.locked = !self.locked;
            self.display_asleep = false;
            self.last_activity = null;
            self.cancelInput(self.raw_held);
            self.rendered_screen = null;
            self.pending_frame.ready = false;
            self.dirty = true;
            self.major = true;
        }

        pub fn button(self: *State, key: navigation.Button, pressed: bool, now: u64, playing: bool) media.PlaybackCommand {
            self.reconcile();
            if (pressed) self.raw_held |= key.mask() else self.raw_held &= ~key.mask();
            if (key == .power) {
                if (pressed) {
                    self.power_at = now;
                    self.power_wake_only = self.display_asleep;
                    if (!self.locked) self.activity(now);
                } else if (self.power_at) |at| {
                    self.power_at = null;
                    // The hardware session owns long-Power shutdown. A short
                    // release exclusively toggles the pocket lock.
                    if (now -| at < 1500 and !self.power_wake_only) {
                        self.toggleLock();
                    }
                }
                return .none;
            }
            if (self.locked) return .none;
            if (pressed) self.activity(now);
            return self.act(self.input_policy.edge(key, pressed, now, self.inputContext(), if (self.menu != null) self.menu.?.count() else if (self.jump_position != null or (self.screen == .player and self.status.total_frames != 0)) 21 else self.rows()), now, playing);
        }

        pub fn wheel(self: *State, direction: i2, now: u64, playing: bool) media.PlaybackCommand {
            if (self.locked) return .none;
            self.activity(now);
            self.reconcile();
            return self.act(self.input_policy.wheel(direction, now, self.inputContext(), if (self.menu != null) self.menu.?.count() else if (self.jump_position != null) 8 else if (self.screen == .player and self.status.total_frames != 0) 21 else self.rows()), now, playing);
        }

        pub fn repeat(self: *State, now: u64, held: u8, playing: bool) media.PlaybackCommand {
            self.reconcile();
            self.raw_held = held;
            if (self.locked) return .none;
            if (held != 0) self.activity(now);
            return self.act(self.input_policy.tick(now, self.inputContext(), if (self.menu != null) self.menu.?.count() else if (self.jump_position != null) 8 else if (self.screen == .player and self.status.total_frames != 0) 21 else self.rows(), held), now, playing);
        }

        fn act(self: *State, action: navigation.Action, now: u64, playing: bool) media.PlaybackCommand {
            if (action == .none) return .none;
            if (action == .home) return self.handle(.home, now, playing);
            if (self.jump_position) |position| switch (action) {
                .move => |delta| {
                    self.jump_position = navigation.move(position, 21, delta);
                    self.dirty = true;
                    return .none;
                },
                .select, .back, .home, .menu => {
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
                .queue => {
                    if (self.playing_track == null or self.track_store.order.count == 0) return .none;
                    self.menu = null;
                    if (self.screen != .tracks or self.track_scope != .queue) self.push(.tracks);
                    self.track_scope = .queue;
                    self.selection = self.track_store.order.cursor;
                    self.ensureVisible();
                    self.dirty = true;
                    self.major = true;
                    return .none;
                },
                .move => |delta| {
                    if (self.menu) |*menu| {
                        menu.selection = navigation.move(menu.selection, menu.count(), delta);
                        self.dirty = true;
                        self.major = true;
                        self.pending_frame.ready = false;
                        return .none;
                    }
                    self.moveBy(delta, now);
                    return .none;
                },
                .jump => {
                    if (self.screen == .player) return .none;
                    self.jump_position = if (self.rows() > 1) self.selection * 20 / (self.rows() - 1) else 0;
                    self.cancelInput(self.input_policy.held);
                    self.dirty = true;
                    self.major = true;
                    return .none;
                },
                .scrub => |seconds| {
                    if (!playing or self.status.total_frames == 0) return .none;
                    const current = self.seek_frame orelse self.status.played_frames;
                    const frames = @as(u64, @intCast(@abs(seconds))) * self.status.sample_rate;
                    const target = @min(self.status.total_frames - 1, if (seconds < 0) current -| frames else current +| frames);
                    if (target == current) return .none;
                    self.seek_frame = target;
                    self.dirty = true;
                    return .none;
                },
                .adjust_volume => |delta| return self.changeVolume(delta, now),
                .commit_seek => {
                    const target = self.seek_frame orelse return .none;
                    self.seek_frame = null;
                    self.dirty = true;
                    return if (playing) .{ .seek_to = target } else .none;
                },
                .previous => return if (playing) .previous else .none,
                .next => return if (playing) .next else .none,
                else => return self.handle(switch (action) {
                    .select => .select,
                    .back => .back,
                    .home => .home,
                    .menu => .menu,
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
            if (self.screen == .folders) if (self.folderRow(self.selection)) |row| {
                self.selected_id = core.hash(row.path);
            };
            if (self.screen == .tracks) if (self.trackAt(self.selection)) |track| {
                self.selected_id = track.id;
            };
            self.dirty = true;
            self.major = true;
        }

        fn changeVolume(self: *State, steps: i8, now: u64) media.PlaybackCommand {
            // ES9018K2M volume codes are half-decibel attenuation. Preserve
            // the established -64..-8 dB range; every isolated tap is one code.
            const minimum_attenuation = 16;
            const maximum_attenuation = 128;
            const next: u8 = @intCast(std.math.clamp(@as(i16, self.attenuation) - steps, minimum_attenuation, maximum_attenuation));
            const changed = next != self.attenuation;
            const level = @as(f32, @floatFromInt(maximum_attenuation - next)) * 100 / (maximum_attenuation - minimum_attenuation);
            self.animation.request(now, level);
            if (!changed) return .none;
            self.attenuation = next;
            if (self.screen == .player) self.dirty = true;
            return .{ .set_attenuation = next };
        }

        pub fn handle(self: *State, event: Input, now: u64, playing: bool) media.PlaybackCommand {
            self.activity(now);
            self.reconcile();
            if (event != .volume_up and event != .volume_down) self.dirty = true;
            if (event == .menu) {
                self.openMenu();
                return .none;
            }
            if (self.menu != null and event != .volume_up and event != .volume_down and event != .home) {
                switch (event) {
                    .up, .down => self.menu.?.selection = navigation.move(self.menu.?.selection, self.menu.?.count(), if (event == .up) -1 else 1),
                    .select => return self.menuSelect(now, playing),
                    .back => self.menu = null,
                    else => {},
                }
                self.rendered_screen = null;
                self.pending_frame.ready = false;
                self.major = true;
                return .none;
            }
            switch (event) {
                .menu => unreachable,
                .volume_up, .volume_down => return self.changeVolume(if (event == .volume_up) 1 else -1, now),
                .home => {
                    self.history_count = 0;
                    self.navigate(.home);
                },
                .back => self.goBack(),
                .up, .down => {
                    if (self.screen == .player and playing) return if (event == .up) .previous else .next;
                    self.moveBy(if (event == .up) -1 else 1, now);
                },
                .select => switch (self.screen) {
                    .home => self.push(switch (self.selection) {
                        0 => .music,
                        1 => .settings,
                        else => .player,
                    }),
                    .music => switch (music_items[self.selection]) {
                        .albums => self.push(.albums),
                        .artists => self.push(.artists),
                        .songs => {
                            self.push(.tracks);
                            self.track_scope = .all;
                        },
                        .shuffle_all => {
                            self.startCollection(.{ .scope = .all }, null, true, now);
                            if (self.requested_track != null) self.push(.player);
                            if (playing and self.requested_track != null) return .stop;
                        },
                    },
                    .albums => if (self.snapshot().album_count > 0) {
                        self.album_id = self.snapshot().albums[self.selection].id;
                        self.track_scope = .album;
                        self.tracks_return = .albums;
                        self.push(.tracks);
                    },
                    .artists => if (self.rows() > 0) {
                        self.artist_id = self.snapshot().artistId(self.selection);
                        self.push(.artist);
                    },
                    .artist => if (self.snapshot().artistIndex(self.artist_id)) |i| {
                        self.track_scope = if (self.selection == 0) .artist else .album;
                        self.tracks_return = .artist;
                        if (self.selection > 0) self.album_id = self.snapshot().albums[self.snapshot().artists[i].first_album + self.selection - 1].id;
                        self.push(.tracks);
                    },
                    .tracks => if (self.trackAt(self.selection)) |track| {
                        self.startContext(track);
                        if (self.track_scope == .queue and self.history_count != 0 and self.history[self.history_count - 1].screen == .player) self.goBack() else self.push(.player);
                        if (playing) return .stop;
                    },
                    .player => if (playing) {
                        return .toggle_pause;
                    } else if (self.playing_track) |track| {
                        self.queue(track);
                    },
                    .folders => if (self.folderRow(self.selection)) |row| {
                        if (row.directory) {
                            self.enterFolder(row.path);
                        } else if (self.snapshot().trackByPath(row.path)) |track| {
                            self.startCollection(.{ .scope = .folder, .directory = self.folderPath() }, track.id, false, now);
                            self.push(.player);
                            if (playing) return .stop;
                        }
                    },
                    .library => self.index.request(self.selection == 1),
                    .themes => {
                        if (self.selection < builtin_theme_count) self.theme_family = @fromBackingInt(@intCast(self.selection)) else if (self.selection == builtin_theme_count) {
                            if (self.theme_family != .custom) self.appearance = if (self.appearance == .light) .dark else .light;
                        } else if (self.theme_store.has_custom) self.theme_family = .custom;
                        self.theme_store.select(self.theme_family, self.appearance);
                        self.themeChanged();
                    },
                    .display => {
                        self.display_timeout = @fromBackingInt(@intCast(self.selection));
                    },
                    .settings => if (self.selection == 3) {
                        self.push(.display);
                        self.selection = @backingInt(self.display_timeout);
                    } else if (self.selection == 2) {
                        self.push(.themes);
                        self.selection = if (self.theme_family == .custom) builtin_theme_count + 1 else @backingInt(self.theme_family);
                    } else if (self.selection == 1) {
                        self.push(.library);
                    } else {
                        self.replay_gain.mode = switch (self.replay_gain.mode) {
                            .off => .track,
                            .track => .album,
                            .album => .off,
                        };
                    },
                },
            }
            return .none;
        }

        fn reconcile(self: *State) void {
            const view = self.snapshot();
            if (self.screen == .folders) {
                const source = self.folderSource();
                if (self.folder_revision != view.revision or self.folder_entries_address != @intFromPtr(source.entries.ptr) or self.folder_entries_count != source.entries.len) self.refreshFolder();
            }
            if (view.revision == self.revision) return;
            if (self.menu) |*menu| if (menu.kind == .collection) {
                const empty = self.collectionCount(menu.collection) == 0;
                if (empty != menu.empty) {
                    menu.empty = empty;
                    self.major = true;
                    self.dirty = true;
                }
            };
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
            return self.menu == null and ((self.screen == .albums and @abs(self.flow - @as(f32, @floatFromInt(self.selection))) > 0.005) or (self.screen == .player and self.animation.isAnimating(now)));
        }

        pub fn refreshBattery(self: *State, millivolts: u32, charging: bool, external_power: bool, now: u64) void {
            // A header-only change must not replace a region transfer during
            // the short volume fade. A stable volume hold can refresh normally.
            if (self.screen == .player and self.animation.isAnimating(now)) return;
            const previous = battery_status.Status.fromPower(self.battery_mv, self.charging, self.external_power);
            self.battery_mv = millivolts;
            self.charging = charging;
            self.external_power = external_power;
            if (std.meta.eql(previous, battery_status.Status.fromPower(millivolts, charging, external_power))) return;
            self.dirty = true;
            self.major = true;
        }

        pub fn frame(self: *State, now: u64) void {
            if (self.last_activity == null) self.last_activity = now;
            const timeout = self.display_timeout.milliseconds();
            if (!self.locked and !self.display_asleep and self.raw_held == 0 and timeout != 0 and now -| self.last_activity.? >= timeout) {
                self.display_asleep = true;
                self.cancelInput(0);
                self.pending_frame.ready = false;
            }
            if (@hasDecl(lcd, "setAwake")) lcd.setAwake(!self.locked and !self.display_asleep);
            if (self.locked or self.display_asleep) {
                // Drain an already-owned transfer, but submit no new frames.
                // The audio/storage executive keeps running independently.
                if (lcd.poll() == .failed) self.fail(lcd.last_failure orelse error.DisplayBusy);
                return;
            }
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
            const dependencies = self.theme_store.current().pages[@backingInt(self.page())];
            if (dependencies.flags & theme.Flags.track_metadata != 0 and self.rendered_track_id != if (self.playing_track) |track| track.id else @as(u64, 0)) {
                self.dirty = true;
                self.major = true;
            }
            const defer_cosmetic = self.screen == .player and self.animation.isAnimating(now);
            if (!defer_cosmetic and self.covers.revision.load(.acquire) != self.cover_revision) {
                self.cover_revision = self.covers.revision.load(.acquire);
                self.dirty = true;
                self.major = true;
            }
            const modal = self.menu != null or self.jump_position != null;
            const volume_moving = self.animation.tick(now) and self.screen == .player and !modal;
            if (volume_moving) self.dirty = true;
            if (!defer_cosmetic and self.last_active != diag.report.scan_active) {
                self.last_active = diag.report.scan_active;
                self.dirty = true;
                self.major = true;
            }
            if (self.last_visited != diag.report.scan_visited or self.last_scan_total != diag.report.scan_total) {
                self.last_visited = diag.report.scan_visited;
                self.last_scan_total = diag.report.scan_total;
                if (self.screen == .player and dependencies.scan_widgets != 0) {
                    self.dirty = true;
                    self.major = true;
                }
                // Now Playing shows activity, not a visited-track count. The
                // carousel's one-pixel rule changes only at whole pixels.
                if (diag.report.scan_active != 0 and self.screen != .player and (self.screen != .albums or self.albumProgressWidth() != self.rendered_scan_width)) self.dirty = true;
            }
            if ((dependencies.flags & theme.Flags.scan_phase != 0) and !std.mem.eql(u8, self.last_scan_phase, self.index.phase)) {
                self.last_scan_phase = self.index.phase;
                self.dirty = true;
            }
            if ((self.screen == .player or dependencies.flags & theme.Flags.playback_phase != 0) and self.last_playback_phase != self.status.phase) {
                self.last_playback_phase = self.status.phase;
                self.major = true;
                self.dirty = true;
            }
            if (self.screen == .player and !modal and self.last_second != self.status.played_frames / @max(1, self.status.sample_rate)) {
                self.last_second = self.status.played_frames / @max(1, self.status.sample_rate);
                self.dirty = true;
            }
            // Prefetch deadlines and releases can change without a repaint.
            // Numeric plans are cheap; hash/publish only a changed request set.
            if (self.screen == .albums and !modal) self.requestCovers(now);
            const moving = !modal and self.screen == .albums and @abs(self.flow - @as(f32, @floatFromInt(self.selection))) > 0.005;
            const motion_flags = @as(u32, @intFromBool(moving)) | (@as(u32, @intFromBool(volume_moving)) << 1);
            if (motion_flags != self.motion_flags) {
                self.motion_flags = motion_flags;
                Platform.trace(.motion, Platform.now(), motion_flags);
            }
            if (!moving and !modal and self.screen == .albums and self.flow != @as(f32, @floatFromInt(self.selection))) {
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
            Platform.trace(.model_v2, draw_started, @bitCast(@import("display_trace.zig").Model{
                .rows = @intCast(@min(2047, self.rows())),
                .selection = @intCast(self.selection),
                .screen = @intCast(@backingInt(self.screen)),
                .volume_moving = volume_moving,
                .moving = moving,
            }));
            Platform.trace(.flow, draw_started, @bitCast(self.flow));
            if (!self.major and !modal and self.screen == .player) self.renderTimelineInto(lcd.framebuffer, now) else self.render(now);
            const draw_ticks = Platform.now() -% draw_started;
            Platform.trace(.render, Platform.now(), draw_ticks);
            diag.report.ui_draw_max = @max(diag.report.ui_draw_max, draw_ticks);
            const full = self.major or self.screen != .player or modal;
            self.frozen = lcd.freeze(if (full) .{ .x = 0, .y = 0, .width = 320, .height = 240 } else .{ .x = 0, .y = @intCast(self.theme_store.current().transport.y), .width = 320, .height = self.theme_store.current().transport.h }) catch |failure| {
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

        fn requestCovers(self: *State, now: u64) void {
            const view = self.snapshot();
            const plan = cover_loading.plan(.{
                .now_ms = now,
                .position = self.flow,
                .selected = self.selection,
                .count = view.album_count,
                .latency_ms = self.covers.load_estimate_ms,
                .next = if (self.jump_position == null) cover_loading.repeatIntent(self.input_policy, self.selection, view.album_count, self.raw_held, now) else null,
            });
            if (self.cover_plan) |previous| {
                if (self.cover_plan_revision == view.revision and previous.count == plan.count and previous.eligible == plan.eligible and
                    std.mem.eql(usize, previous.ranks[0..previous.count], plan.ranks[0..plan.count])) return;
            }
            self.covers.requested = @splat(.{});
            for (plan.ranks[0..plan.count], 0..) |rank, i| {
                const album = view.albums[rank];
                self.covers.requested[i] = .{ .id = album.id, .art = album.art, .eligible = plan.eligible & (@as(u10, 1) << @intCast(i)) != 0 };
            }
            self.covers.publishRequests();
            self.cover_plan = plan;
            self.cover_plan_revision = view.revision;
        }

        fn page(self: *const State) @import("runtime_theme.zig").Page {
            if (self.menu != null) return .menu;
            if (self.jump_position != null) return .jump;
            return switch (self.screen) {
                .home => .home,
                .albums => .albums,
                .tracks, .folders => .tracks,
                .player => .player,
                .library => .library,
                .artists => .artists,
                .artist => .artist,
                .music, .settings, .themes, .display => .menu,
            };
        }

        pub fn palette(self: *const State) chrome.Palette {
            const plan = self.theme_store.current();
            return .{ .paper = plan.paper, .ink = plan.ink, .muted = plan.muted, .line = plan.line, .accent = plan.accent, .selected = plan.selected };
        }

        fn themeChanged(self: *State) void {
            self.cancelInput(self.input_policy.held);
            self.rendered_screen = null;
            self.pending_frame.ready = false;
            self.ensureVisible();
            self.dirty = true;
            self.major = true;
        }

        pub fn loadCustomTheme(self: *State, source: []const u8, scratch: []u8) !void {
            try self.theme_store.load(source, scratch);
            self.theme_store.select(self.theme_family, self.appearance);
            self.themeChanged();
        }

        fn context(self: *State, now: u64, items: *[12]@import("music_widgets.zig").Item, detail_buffer: []u8, want_art: bool) @import("music_widgets.zig").Context {
            const view = self.snapshot();
            const artist = if (self.artistRank()) |rank| view.artists[rank] else null;
            const menu = self.menu;
            const title: []const u8 = if (menu) |actions| if (actions.kind == .player) "Playback" else switch (actions.collection.scope) {
                .album => if (view.albumIndex(actions.collection.album)) |rank| view.albums[rank].title else "Album",
                .artist => if (view.artistIndex(actions.collection.artist)) |rank| view.artists[rank].name else "Artist",
                .folder => if (actions.collection.directory.len == 0) "Folders" else std.fs.path.basename(actions.collection.directory),
                else => "Music",
            } else if (self.jump_position != null) "Jump" else switch (self.screen) {
                .home => "Home",
                .music => "Music",
                .albums => "Albums",
                .artists => "Artists",
                .artist => if (artist) |value| value.name else "Artist",
                .tracks => switch (self.track_scope) {
                    .all => "All Songs",
                    .queue => "Queue",
                    .artist => if (artist) |value| value.name else "Songs",
                    .album => if (self.albumRank()) |rank| view.albums[rank].title else "Songs",
                    .folder => "Songs",
                },
                .player => if (self.status.phase == .paused) "Paused" else "Now Playing",
                .library => "Library",
                .settings => "Settings",
                .themes => "Themes",
                .display => "Display timeout",
                .folders => if (self.folder_path_len == 0) "Folders" else std.fs.path.basename(self.folderPath()),
            };
            const detail: []const u8 = if (menu == null and self.jump_position == null and self.screen == .albums) std.fmt.bufPrint(detail_buffer, "{d} / {d}", .{ if (view.album_count == 0) 0 else self.selection + 1, view.album_count }) catch "" else "";
            const selection = if (menu) |actions| actions.selection else self.selection;
            const first = if (menu != null) navigation.firstVisible(selection, 0, self.visibleRows(), self.theme_store.current().pages[@backingInt(self.page())].columns) else self.first;
            const count = if (menu) |actions| actions.count() else self.rows();
            var length: usize = 0;
            if (self.page() != .player and self.page() != .albums and self.page() != .jump) {
                const limit = @min(count, first + self.visibleRows());
                for (first..limit) |position| {
                    var item: @import("music_widgets.zig").Item = .{};
                    if (menu) |actions| {
                        if (actions.kind == .player) switch (position) {
                            0 => item = .{ .name = "Queue", .chevron = true },
                            1 => item = .{ .name = "Shuffle", .detail = if (self.track_store.order.shuffled) "On" else "Off" },
                            2 => item = .{ .name = "Repeat", .detail = switch (self.track_store.order.repeat) {
                                .off => "Off",
                                .all => "All",
                                .one => "One",
                            } },
                            else => unreachable,
                        } else item.name = switch (position) {
                            0 => "Play All",
                            1 => "Shuffle",
                            else => "Jump",
                        };
                    } else switch (self.screen) {
                        .home => item = .{ .name = switch (position) {
                            0 => "Music",
                            1 => "Settings",
                            else => "Now Playing",
                        }, .chevron = true },
                        .music => item = .{ .name = switch (music_items[position]) {
                            .albums => "Albums",
                            .artists => "Artists",
                            .songs => "Songs",
                            .shuffle_all => "Shuffle All",
                        }, .chevron = music_items[position] != .shuffle_all },
                        .artists => item.name = view.artists[position].name,
                        .artist => item.name = if (position == 0) "All Songs" else view.albums[artist.?.first_album + position - 1].title,
                        .tracks => if (self.trackAt(position)) |track| {
                            item.name = track.meta.title;
                            if (self.track_scope == .queue) item.secondary = track.meta.artist;
                        } else {
                            item.name = "Unavailable track";
                        },
                        .folders => if (self.folderRow(position)) |row| {
                            item.name = std.fs.path.basename(row.path);
                            item.chevron = row.directory;
                            if (!row.directory and self.snapshot().trackByPath(row.path) == null) item.detail = "Pending";
                        },
                        .library => item.name = if (position == 0) "Update library" else "Verify library",
                        .settings => item = switch (position) {
                            0 => .{ .name = "ReplayGain", .detail = switch (self.replay_gain.mode) {
                                .off => "Off",
                                .track => "Track",
                                .album => "Album",
                            } },
                            1 => .{ .name = "Library", .chevron = true },
                            2 => .{ .name = "Themes", .chevron = true },
                            else => .{ .name = "Display", .chevron = true },
                        },
                        .themes => {
                            if (position < builtin_theme_count) item = .{ .name = @import("builtin_themes.zig").names[position], .detail = if (position == @backingInt(self.theme_family)) "Active" else "" } else if (position == builtin_theme_count) item = .{ .name = "Appearance", .detail = if (self.theme_family == .custom) "Theme" else if (self.appearance == .light) "Light" else "Dark" } else item = .{ .name = "Custom", .detail = if (!self.theme_store.has_custom) "Unavailable" else if (self.theme_family == .custom) "Active" else "" };
                        },
                        .display => item = .{ .name = ([_][]const u8{ "15 seconds", "30 seconds", "60 seconds", "Always on" })[position], .detail = if (position == @backingInt(self.display_timeout)) "Active" else "" },
                        .albums, .player => unreachable,
                    }
                    items[length] = item;
                    length += 1;
                }
            }
            var artwork: core.Artwork = .{};
            var artwork_id: u64 = 0;
            if (want_art and self.theme_store.current().pages[@backingInt(self.page())].flags & theme.Flags.artwork != 0 and self.menu == null) if (self.playing_track) |track| {
                if (view.albumForTrack(track.id)) |album| {
                    artwork = album.art;
                    artwork_id = album.id;
                }
                self.covers.request(0, artwork_id, artwork);
            };
            const jump_rank = (self.rows() -| 1) * (self.jump_position orelse 0) / 20;
            const jump_title = if (self.jump_position == null) "" else switch (self.screen) {
                .albums => if (view.album_count > 0) view.albums[jump_rank].title else "",
                .artists => if (view.artist_count > 0) view.artists[jump_rank].name else "",
                .tracks => if (self.trackAt(jump_rank)) |track| track.meta.title else "",
                else => "",
            };
            return .{
                .page = self.page(),
                .jump_title = jump_title,
                .title = title,
                .empty_message = if (self.screen == .albums) "No albums yet" else if (self.screen == .artists) "No artists yet" else if (self.menu != null) "No songs here" else if (self.screen == .folders) (if (self.folder_error) "Folder too large" else "Empty folder") else "No songs yet",
                .detail = detail,
                .phase = self.index.phase,
                .snapshot = view,
                .cache = self.covers,
                .items = items[0..length],
                .first = first,
                .selection = selection,
                .total = count,
                .track = self.playing_track,
                .artwork = artwork,
                .artwork_id = artwork_id,
                .power = battery_status.Status.fromPower(self.battery_mv, self.charging, self.external_power),
                .flow_position = self.flow,
                .scanning = diag.report.scan_active != 0,
                .scan_visited = diag.report.scan_visited,
                .scan_total = diag.report.scan_total,
                .elapsed = self.seek_frame orelse self.status.played_frames,
                .duration = self.status.total_frames,
                .sample_rate = self.status.sample_rate,
                .volume_mix = if (self.seek_frame != null) 0 else self.animation.mix(now),
                .volume_value = self.animation.value(now),
                .playing = self.status.phase == .playing,
                .jump = self.jump_position orelse 0,
                .shuffled = self.track_store.order.shuffled,
                .repeat = self.track_store.order.repeat,
            };
        }

        pub fn renderTimelineInto(self: *State, pixels: *[320 * 240]u16, now: u64) void {
            var items: [12]@import("music_widgets.zig").Item = undefined;
            var detail: [96]u8 = undefined;
            const plan = self.theme_store.current();
            const artwork = plan.pages[@backingInt(self.page())].flags & theme.Flags.transport_artwork != 0;
            @import("music_widgets.zig").render(plan, pixels, self.context(now, &items, &detail, artwork), self.text_cache, true, false);
        }

        fn render(self: *State, now: u64) void {
            self.renderInto(lcd.framebuffer, now);
        }

        fn albumProgressWidth(self: *const State) u16 {
            return self.theme_store.current().scanProgress(.albums, diag.report.scan_visited, diag.report.scan_total);
        }

        pub fn renderInto(self: *State, pixels: *[320 * 240]u16, now: u64) void {
            const plan = self.theme_store.current();
            const view = self.snapshot();
            const retained = self.screen == .albums and self.menu == null and self.jump_position == null and self.rendered_screen == .albums and self.rendered_surface == @intFromPtr(pixels) and self.rendered_theme_revision == self.theme_store.revision;
            const scan_width = self.albumProgressWidth();
            const cover_revision = self.covers.revision.load(.acquire);
            var scene_changed = !retained or self.rendered_cover_revision != cover_revision;
            var visible: [7]CoverModel = undefined;
            var visible_count: usize = 0;
            var cards: [7]flow_scene.Card = undefined;
            const is_album = self.page() == .albums;
            if (is_album) {
                self.requestCovers(now);
                const span = plan.pages[@backingInt(@import("runtime_theme.zig").Page.albums)];
                const op = &plan.ops[span.covers];
                const anchor: i32 = @intFromFloat(@round(self.flow));
                var coverage = @import("display_trace.zig").Covers{};
                for ([_]i32{ -3, 3, -2, 2, -1, 1, 0 }) |offset| {
                    const rank = anchor + offset;
                    if (rank < 0 or rank >= view.album_count) continue;
                    const album = view.albums[@intCast(rank)];
                    const distance = @as(f32, @floatFromInt(rank)) - self.flow;
                    if (@abs(distance) > 3.4) continue;
                    const model = CoverModel{ .id = album.id, .texture = self.covers.get(album.id, album.art), .distance = distance };
                    const bit = @as(u7, 1) << @as(u3, @intCast(visible_count));
                    coverage.present |= bit;
                    const ready = if (model.texture) |tile| tile.width != 0 and tile.height != 0 else false;
                    if (ready) coverage.ready |= bit else if (model.texture != null) coverage.missing |= bit;
                    if (rank == anchor) {
                        coverage.center_present = true;
                        coverage.center_ready = ready;
                    }
                    if (rank == self.selection) coverage.destination_ready = ready;
                    if (!scene_changed) {
                        if (visible_count >= self.rendered_cover_count) scene_changed = true else {
                            const previous = self.rendered_covers[visible_count];
                            scene_changed = previous.id != model.id or previous.texture != model.texture or previous.distance != model.distance;
                        }
                    }
                    visible[visible_count] = model;
                    cards[visible_count] = .{ .texture = model.texture, .quad = flow_scene.projectThemed(distance, op.rect.x + @as(i32, @intCast(op.rect.w / 2)), op.rect.y + @as(i32, @intCast(op.edge / 2)), op.edge, op.reflection) };
                    visible_count += 1;
                }
                scene_changed = scene_changed or visible_count != self.rendered_cover_count;
                Platform.trace(.covers, Platform.now(), @bitCast(coverage));
            } else {
                self.covers.requested = @splat(.{});
                self.cover_plan = null;
            }
            var items: [12]@import("music_widgets.zig").Item = undefined;
            var detail: [96]u8 = undefined;
            var model = self.context(now, &items, &detail, true);
            model.cards = cards[0..visible_count];
            const span = plan.pages[@backingInt(self.page())];
            const data_changed = (span.flags & theme.Flags.track_metadata != 0 and self.rendered_track_id != if (self.playing_track) |track| track.id else @as(u64, 0)) or (span.flags & theme.Flags.playback_phase != 0 and self.rendered_phase != self.status.phase) or (span.flags & theme.Flags.scan_phase != 0 and !std.mem.eql(u8, self.rendered_scan_phase, self.index.phase));
            const header_changed = data_changed or !retained or self.rendered_selection != self.selection or self.rendered_count != view.album_count or self.rendered_battery != self.battery_mv or self.rendered_charging != self.charging or self.rendered_external_power != self.external_power;
            const caption_changed = !retained or self.rendered_selection != self.selection or self.rendered_revision != view.revision;
            const widgets = @import("music_widgets.zig");
            if (retained and !header_changed and !caption_changed) {
                if (scene_changed) widgets.render(plan, pixels, model, self.text_cache, false, true);
                if (self.rendered_scan_active != diag.report.scan_active or self.rendered_scan_width != scan_width) _ = widgets.renderScanUpdate(plan, pixels, model, self.text_cache, self.rendered_scan_active != diag.report.scan_active);
            } else widgets.render(plan, pixels, model, self.text_cache, false, false);
            if (is_album) {
                @memcpy(self.rendered_covers[0..visible_count], visible[0..visible_count]);
                self.rendered_cover_count = visible_count;
            }
            self.covers.publishRequests();
            self.rendered_surface = @intFromPtr(pixels);
            self.rendered_screen = if (self.menu != null or self.jump_position != null) null else self.screen;
            self.rendered_selection = self.selection;
            self.rendered_revision = view.revision;
            self.rendered_count = view.album_count;
            self.rendered_battery = self.battery_mv;
            self.rendered_charging = self.charging;
            self.rendered_external_power = self.external_power;
            self.rendered_scan_active = diag.report.scan_active;
            self.rendered_scan_width = scan_width;
            self.rendered_flow = self.flow;
            self.rendered_cover_revision = cover_revision;
            self.rendered_theme_revision = self.theme_store.revision;
            self.rendered_track_id = if (self.playing_track) |track| track.id else 0;
            self.rendered_phase = self.status.phase;
            self.rendered_scan_phase = self.index.phase;
        }
    };
}

// The host fixture provides no MMIO, filesystem or wall clock. It exercises
// the same controller with a deterministic DMA completion schedule.
const TestPlatform = struct {
    var milliseconds: u64 = 0;
    var library_work: u64 = 0;
    pub fn now() u32 {
        return @truncate(milliseconds * 6000);
    }
    pub fn trace(kind: @import("display_trace.zig").Kind, _: u32, value: u32) void {
        if (kind == .library_work) library_work += value;
    }
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
        state.charging = step % 3 == 1;
        state.external_power = step % 3 != 0;
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
    state.refreshBattery(3799, false, false, 120);
    try std.testing.expectEqual(4100, state.battery_mv);
    try std.testing.expect(!state.major);
    _ = state.animation.tick(240);
    state.refreshBattery(3799, false, false, 240);
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

test "prefetch admission and raw release update while presentation waits" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tracks = try a.alloc(core.Track, 128);
    for (tracks, 0..) |*track, i| track.* = .{
        .id = i + 1,
        .path = try std.fmt.allocPrint(a, "Synthetic/{d:0>3}/1.flac", .{i}),
        .stamp = .{},
        .meta = .{ .album = try std.fmt.allocPrint(a, "Album {d:0>3}", .{i}) },
    };
    try fixture.pair.publish(&.{}, tracks, 42, true);
    var state = fixture.state();
    state.navigate(.albums);
    state.reconcile();
    state.selection = 24;
    state.flow = 23;
    const mask = navigation.Button.next.mask();
    state.raw_held = mask;
    state.input_policy = .{ .held = mask, .direction = 1, .started_at = 0, .repeat_at = 3070, .gesture_count = 1024, .gesture_context = .covers };
    TestPlatform.Display.reset();
    TestPlatform.Display.waiting_launch = true;
    defer TestPlatform.Display.waiting_launch = false;
    TestPlatform.milliseconds = 3000;
    state.frame(3000);
    const destination = state.snapshot().albums[24].id;
    const predicted = state.snapshot().albums[48].id;
    try std.testing.expectEqual(destination, fixture.cache.requested[0].id);
    try std.testing.expectEqual(predicted, fixture.cache.requested[1].id);
    try std.testing.expect(fixture.cache.requested[0].eligible);
    const early_revision = fixture.cache.request_revision.load(.acquire);
    TestPlatform.milliseconds = 3050;
    state.frame(3050);
    try std.testing.expect(!fixture.cache.requested[0].eligible);
    try std.testing.expect(fixture.cache.request_revision.load(.acquire) != early_revision);
    // The raw release arrives before its debounced edge. Speculation must stop
    // now even though the display has not accepted a single new frame.
    _ = state.repeat(3051, 0, false);
    TestPlatform.milliseconds = 3051;
    state.frame(3051);
    for (fixture.cache.requested) |request| try std.testing.expect(request.id != predicted);
    try std.testing.expectEqual(0, TestPlatform.Display.submissions);
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

test "chosen all-song order survives browsing another album and progressive insertions" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1", .stamp = .{}, .meta = .{ .title = "Alpha", .album = "First" } },
        .{ .id = 2, .path = "B/1", .stamp = .{}, .meta = .{ .title = "Beta", .album = "Second" } },
        .{ .id = 3, .path = "C/1", .stamp = .{}, .meta = .{ .title = "Gamma", .album = "Third" } },
        .{ .id = 4, .path = "D/1", .stamp = .{}, .meta = .{ .title = "Delta", .album = "Fourth" } },
    };
    try fixture.pair.publish(&.{}, tracks[0..3], 42, true);
    state.navigate(.tracks);
    state.track_scope = .all;
    state.selection = 1;
    _ = state.handle(.select, 0, false);
    state.playing_track = state.track_store.begin();
    state.requested_track = null;
    try std.testing.expectEqual(2, state.playing_track.?.id);
    state.navigate(.albums);
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    const next = state.neighbouringTrack(1).?;
    try std.testing.expectEqual(3, next.id);
    state.queue(next);
    state.playing_track = state.track_store.begin();
    try std.testing.expectEqual(null, state.neighbouringTrack(1));
    try std.testing.expectEqual(2, state.neighbouringTrack(-1).?.id);
}

test "queue browsing resolves current metadata and selecting a row preserves its order" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    const tracks = [_]core.Track{
        .{ .id = 11, .path = "A/1", .stamp = .{}, .meta = .{ .title = "Zulu", .album = "First" } },
        .{ .id = 42, .path = "B/1", .stamp = .{}, .meta = .{ .title = "Alpha", .album = "Second" } },
        .{ .id = 7, .path = "C/1", .stamp = .{}, .meta = .{ .title = "Beta", .album = "Third" } },
    };
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    for ([_]u64{ 11, 7, 42 }) |id| try state.track_store.order.append(id);
    state.track_scope = .queue;
    state.navigate(.tracks);
    state.selection = 1;
    _ = state.handle(.select, 0, false);
    state.playing_track = state.track_store.begin();
    try std.testing.expectEqual(7, state.playing_track.?.id);
    try std.testing.expectEqual(3, state.track_store.order.count);
    try std.testing.expectEqual(11, state.track_store.order.at(0).?);
    try std.testing.expectEqual(1, state.track_store.order.cursor);
    try fixture.pair.publish(&.{}, tracks[1..], 42, true);
    state.track_scope = .queue;
    state.navigate(.tracks);
    try std.testing.expectEqual(null, state.trackAt(0));
    const next = state.neighbouringTrack(1).?;
    try std.testing.expectEqual(42, next.id);
    state.queue(next);
    state.playing_track = state.track_store.begin();
    try std.testing.expectEqual(7, state.neighbouringTrack(-1).?.id);
}

test "physical Menu opens playback actions and hold goes Home without an accidental menu" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const track = core.Track{ .id = 1, .path = "A/1.flac", .stamp = .{}, .meta = .{} };
    try fixture.pair.publish(&.{}, &.{track}, 1, true);
    var state = fixture.state();
    state.queue(&track);
    state.playing_track = state.track_store.begin().?;
    state.navigate(.player);
    state.status.total_frames = 1000;
    state.status.played_frames = 200;
    _ = state.button(.menu, true, 0, true);
    _ = state.button(.menu, false, 100, true);
    try std.testing.expect(state.menu != null);
    _ = state.handle(.back, 101, true);
    _ = state.button(.menu, true, 200, true);
    _ = state.repeat(700, navigation.Button.menu.mask(), true);
    try std.testing.expectEqual(Screen.home, state.screen);
    try std.testing.expect(state.jump_position == null and state.menu == null);
    _ = state.button(.menu, false, 701, true);
    try std.testing.expect(state.menu == null);
}

test "collection actions capture scope, preserve playback when toggling modes and honour repeat" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "Music/A/01.flac", .stamp = .{}, .meta = .{ .title = "First", .album = "A", .artist = "Artist", .track = 1 } },
        .{ .id = 2, .path = "Music/A/02.flac", .stamp = .{}, .meta = .{ .title = "Second", .album = "A", .artist = "Artist", .track = 2 } },
        .{ .id = 3, .path = "Music/A/03.flac", .stamp = .{}, .meta = .{ .title = "Third", .album = "A", .artist = "Artist", .track = 3 } },
        .{ .id = 4, .path = "Music/B/01.flac", .stamp = .{}, .meta = .{ .title = "Elsewhere", .album = "B", .artist = "Other" } },
    };
    try fixture.pair.publish(&.{}, &tracks, 42, true);
    var state = fixture.state();
    state.navigate(.albums);
    state.reconcile();
    _ = state.handle(.menu, 1, false);
    const selected_album = state.menu.?.collection.album;
    // A publication between opening and activating the menu cannot change its
    // captured collection or silently substitute an album at the same rank.
    const added = core.Track{ .id = 5, .path = "Z/01.flac", .stamp = .{}, .meta = .{ .title = "New", .album = "0", .artist = "Other" } };
    const changed = tracks ++ .{added};
    try fixture.pair.publish(&.{}, &changed, 42, true);
    _ = state.handle(.select, 2, false);
    try std.testing.expectEqual(3, state.track_store.order.count);
    try std.testing.expectEqual(1, state.requested_track.?.id);
    try std.testing.expectEqual(selected_album, state.snapshot().albums[state.snapshot().albumIndex(selected_album).?].id);
    state.playing_track = state.track_store.begin().?;
    state.requested_track = null;
    state.status.played_frames = 1234;
    state.status.phase = .paused;
    _ = state.handle(.menu, 10, true);
    state.menu.?.selection = 1;
    try std.testing.expectEqual(.none, std.meta.activeTag(state.handle(.select, 11, true)));
    try std.testing.expect(state.track_store.order.shuffled);
    try std.testing.expect(state.requested_track == null);
    try std.testing.expectEqual(1234, state.status.played_frames);
    try std.testing.expectEqual(media.PlaybackPhase.paused, state.status.phase);
    state.menu.?.selection = 2;
    _ = state.handle(.select, 12, true);
    try std.testing.expectEqual(@import("play_queue.zig").Repeat.all, state.track_store.order.repeat);
    _ = state.handle(.select, 13, true);
    try std.testing.expectEqual(state.playing_track.?.id, state.finishedTrack().?.id);
    try std.testing.expect(state.neighbouringTrack(1).?.id != state.playing_track.?.id);
    _ = state.handle(.select, 14, true);
    try std.testing.expectEqual(@import("play_queue.zig").Repeat.off, state.track_store.order.repeat);
}

test "folder playback is naturally ordered, nonrecursive and shares the retained queue" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const tracks = [_]core.Track{
        .{ .id = 10, .path = "Music/A/10.flac", .stamp = .{}, .meta = .{ .title = "Ten", .album = "A" } },
        .{ .id = 2, .path = "Music/A/2.flac", .stamp = .{}, .meta = .{ .title = "Two", .album = "A" } },
        .{ .id = 3, .path = "Music/A/Sub/3.flac", .stamp = .{}, .meta = .{ .title = "Nested", .album = "B" } },
        .{ .id = 4, .path = "Music/B/1.flac", .stamp = .{}, .meta = .{ .title = "Other", .album = "C" } },
    };
    try fixture.pair.publish(&.{}, &tracks, 1, true);
    var state = fixture.state();
    state.navigate(.folders);
    state.reconcile();
    _ = state.handle(.select, 1, false); // Music
    _ = state.handle(.select, 2, false); // A
    try std.testing.expectEqualStrings("Music/A", state.folderPath());
    try std.testing.expectEqual(3, state.rows()); // Sub, 2.flac, 10.flac
    _ = state.handle(.down, 2, false);
    _ = state.handle(.menu, 3, false);
    _ = state.handle(.select, 4, false);
    try std.testing.expectEqual(2, state.track_store.order.count);
    try std.testing.expectEqual(2, state.track_store.order.at(0).?);
    try std.testing.expectEqual(10, state.track_store.order.at(1).?);
    state.playing_track = state.track_store.begin().?;
    state.requested_track = null;
    _ = state.handle(.menu, 5, true);
    _ = state.handle(.select, 6, true); // Queue
    try std.testing.expectEqual(TrackScope.queue, state.track_scope);
    _ = state.handle(.down, 7, true);
    _ = state.handle(.select, 8, true);
    try std.testing.expectEqual(10, state.requested_track.?.id);
    try std.testing.expectEqual(2, state.track_store.order.count);
    try std.testing.expectEqual(Screen.player, state.screen);
    _ = state.handle(.back, 9, false);
    try std.testing.expectEqual(Screen.folders, state.screen);
    _ = state.handle(.back, 10, false);
    try std.testing.expectEqualStrings("Music", state.folderPath());
}

test "context selection and dismissals retain immutable presentation through delayed DMA" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const track = core.Track{ .id = 1, .path = "A/1.flac", .stamp = .{}, .meta = .{} };
    try fixture.pair.publish(&.{}, &.{track}, 1, true);
    var state = fixture.state();
    state.queue(&track);
    state.playing_track = state.track_store.begin().?;
    state.requested_track = null;
    state.navigate(.player);
    state.status.sample_rate = 48000;
    state.status.total_frames = 480000;
    TestPlatform.Display.reset();
    TestPlatform.Display.latency = 37;
    defer TestPlatform.Display.reset();
    for (0..400) |now| {
        if (now == 40 or now == 160 or now == 280) _ = state.button(.menu, true, now, true);
        if (now == 60 or now == 180 or now == 300) _ = state.button(.menu, false, now, true);
        if (now == 100 or now == 110) _ = state.handle(.down, now, true);
        if (now == 120) _ = state.handle(.select, now, true);
        if (now == 220 or now == 330) _ = state.handle(.back, now, true);
        state.status.played_frames += 48;
        TestPlatform.milliseconds = now;
        state.frame(now);
        try std.testing.expect(!state.failure);
        try std.testing.expect(!TestPlatform.Display.corrupted);
    }
    try std.testing.expect(state.requested_track == null);
    try std.testing.expectEqual(19200, state.status.played_frames);
}

test "folder focus follows paths when authoritative directory entries replace a preview" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const old_entries = [_]core.Entry{ .{ .path = "B", .kind = .directory }, .{ .path = "C", .kind = .directory } };
    const new_entries = [_]core.Entry{ .{ .path = "A", .kind = .directory }, .{ .path = "B", .kind = .directory }, .{ .path = "C", .kind = .directory } };
    try fixture.pair.publish(&.{}, &.{}, 1, true);
    test_diag.catalog = .{ .arena = .init(std.testing.allocator), .value = .{ .entries = &old_entries } };
    defer test_diag.catalog = null;
    var state = fixture.state();
    state.navigate(.folders);
    state.reconcile();
    try std.testing.expectEqualStrings("B", state.folderRow(state.selection).?.name);
    // Final persistence can replace raw entries without another view commit.
    test_diag.catalog = .{ .arena = .init(std.testing.allocator), .value = .{ .entries = &new_entries } };
    state.reconcile();
    try std.testing.expectEqualStrings("B", state.folderRow(state.selection).?.name);
    try std.testing.expectEqual(1, state.selection);
}

test "open folder actions own their path across source mutation and reclamation" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var path = [_]u8{'A'};
    const entries = [_]core.Entry{.{ .path = &path, .kind = .directory }};
    test_diag.catalog = .{ .arena = .init(std.testing.allocator), .value = .{ .entries = &entries } };
    defer test_diag.catalog = null;
    try fixture.pair.publish(&.{}, &.{}, 1, true);
    var state = fixture.state();
    state.navigate(.folders);
    state.reconcile();
    _ = state.handle(.menu, 1, false);
    path[0] = 'B';
    try std.testing.expectEqualStrings("A", state.menu.?.collection.directory);
    _ = state.handle(.select, 2, false);
    try std.testing.expect(state.requested_track == null);
    _ = state.handle(.back, 3, false);
    try std.testing.expect(state.menu == null);
}

test "unchanged folder actions leave decoder CPU available across repeated UI polls" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tracks = try arena.allocator().alloc(core.Track, 4096);
    for (tracks, 0..) |*track, i| track.* = .{ .id = i + 1, .path = try std.fmt.allocPrint(arena.allocator(), "Music/A/{d:0>4}.flac", .{i}), .stamp = .{}, .meta = .{ .title = "Synthetic", .album = "A" } };
    try fixture.pair.publish(&.{}, tracks, 1, true);
    var state = fixture.state();
    state.navigate(.folders);
    state.reconcile();
    state.enterFolder("Music/A");
    state.reconcile();
    _ = state.handle(.menu, 0, true);
    try std.testing.expect(state.menu != null);
    TestPlatform.Display.reset();
    defer TestPlatform.Display.reset();
    const reservoir = @import("pcm_reservoir.zig");
    const output = @import("audio_output.zig");
    var samples: [8192]reservoir.StereoFrame = @splat(.{ .left = 0, .right = 0 });
    var ring = try reservoir.Ring.initFilled(&samples, samples.len);
    const plan = try output.Plan.init(48000, .signed_24_in_u32);
    var bytes: [3840]u8 align(4) = undefined;
    var produced: [144]reservoir.StereoFrame = @splat(.{ .left = 1, .right = 1 });
    var elapsed_us: u64 = 0;
    var output_at: u64 = 10000;
    for (0..1000) |step| {
        if (step == 300 or step == 600) try fixture.pair.publish(&.{}, tracks, 1, true);
        const before = TestPlatform.library_work;
        const now = elapsed_us / 1000;
        _ = state.repeat(now, 0, true);
        TestPlatform.milliseconds = now;
        state.frame(now);
        // Synthetic scheduling budget, not MIPS timing: catalogue visits use
        // foreground CPU; a 1 ms decoder slice produces 3 ms of stereo PCM.
        elapsed_us += 1000 + (TestPlatform.library_work - before) * 3;
        _ = ring.write(&produced);
        while (output_at <= elapsed_us) : (output_at += 10000) {
            const rendered = try output.renderPeriod(&ring, &bytes, plan, output.unity_gain_q24);
            try std.testing.expect(!rendered.underrun);
        }
        try std.testing.expect(!state.failure and !TestPlatform.Display.corrupted);
    }
    try std.testing.expect(state.menu != null);
}

test "retiring workers cannot override newer selections and faults cannot auto-advance" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "A/1.flac", .stamp = .{}, .meta = .{} },
        .{ .id = 2, .path = "A/2.flac", .stamp = .{}, .meta = .{} },
        .{ .id = 3, .path = "A/3.flac", .stamp = .{}, .meta = .{} },
    };
    try fixture.pair.publish(&.{}, &tracks, 1, true);
    var state = fixture.state();
    for (&tracks) |track| try state.track_store.order.append(track.id);
    state.queue(&tracks[0]);
    state.playing_track = state.track_store.begin().?;
    state.requested_track = null;
    for ([_]media.PlaybackExit{ .next, .previous, .seek, .completed }) |exit| {
        state.queue(&tracks[2]);
        state.playbackFinished(.{ .sample_rate = 48000, .output_format = .signed_24_in_u32, .frames = 1000, .chunks = 3, .underruns = 0, .minimum_fifo_level = 32, .exit = exit, .seek_frame = 900 }, false);
        try std.testing.expectEqual(3, state.requested_track.?.id);
        try std.testing.expectEqual(0, state.requested_start_frame);
    }
    state.requested_track = null;
    state.playbackFinished(.{ .sample_rate = 48000, .output_format = .signed_24_in_u32, .frames = 1000, .chunks = 3, .underruns = 0, .minimum_fifo_level = 32 }, true);
    try std.testing.expect(state.requested_track == null);
    try std.testing.expectEqual(0, state.track_store.order.cursor);
}

test "held transport previews one bounded seek and commits on release while paused" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    state.navigate(.player);
    state.status = .{ .phase = .paused, .sample_rate = 48000, .output_format = .signed_24_in_u32, .total_frames = 48000 * 100, .played_frames = 48000 * 20 };
    try std.testing.expectEqual(media.PlaybackCommand.toggle_pause, state.handle(.select, 0, true));
    try std.testing.expectEqual(media.PlaybackCommand.none, state.button(.next, true, 0, true));
    try std.testing.expectEqual(media.PlaybackCommand.none, state.repeat(400, navigation.Button.next.mask(), true));
    try std.testing.expectEqual(48000 * 22, state.seek_frame.?);
    try std.testing.expectEqual(48000 * 20, state.status.played_frames);
    _ = state.repeat(520, navigation.Button.next.mask(), true);
    try std.testing.expectEqual(media.PlaybackCommand{ .seek_to = 48000 * 24 }, state.button(.next, false, 600, true));
    try std.testing.expectEqual(null, state.seek_frame);
    _ = state.button(.previous, true, 700, true);
    _ = state.repeat(6000, navigation.Button.previous.mask(), true);
    _ = state.repeat(6120, navigation.Button.previous.mask(), true);
    try std.testing.expectEqual(0, state.seek_frame.?);
    state.cancelInput(navigation.Button.previous.mask());
    try std.testing.expectEqual(null, state.seek_frame);
    try std.testing.expectEqual(media.PlaybackCommand.none, state.button(.previous, false, 6200, true));
}

test "held Back opens the captured queue and short Back returns to the player" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const track = core.Track{ .id = 1, .path = "Music/one.flac", .stamp = .{}, .meta = .{ .title = "A title", .artist = "An artist" } };
    try fixture.pair.publish(&.{}, &.{track}, 1, true);
    var state = fixture.state();
    try state.track_store.order.append(track.id);
    state.queue(&track);
    state.playing_track = state.track_store.begin().?;
    state.navigate(.player);
    _ = state.button(.back, true, 0, true);
    _ = state.repeat(500, navigation.Button.back.mask(), true);
    _ = state.button(.back, false, 501, true);
    try std.testing.expectEqual(Screen.tracks, state.screen);
    try std.testing.expectEqual(TrackScope.queue, state.track_scope);
    _ = state.button(.back, true, 600, true);
    _ = state.button(.back, false, 700, true);
    try std.testing.expectEqual(Screen.player, state.screen);
    try std.testing.expectEqual(1, state.track_store.order.count);
}

test "light and dark selection invalidates retained screens and region rendering matches a full repaint" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    state.navigate(.themes);
    state.selection = 5;
    _ = state.handle(.select, 0, false);
    try std.testing.expectEqual(chrome.Appearance.dark, state.appearance);
    var pixels: [320 * 240]u16 = undefined;
    state.renderInto(&pixels, 0);
    try std.testing.expectEqual(chrome.dark.paper, pixels[0]);
    state.navigate(.player);
    const track = core.Track{ .id = 1, .path = "Music/one.flac", .stamp = .{}, .meta = .{ .title = "A title", .artist = "An artist" } };
    state.playing_track = &track;
    state.status = .{ .phase = .playing, .sample_rate = 48000, .output_format = .signed_24_in_u32, .total_frames = 48000 * 100, .played_frames = 48000 * 20 };
    // Compare just the timeline's owned region, including every antialiased edge.
    for ([_]chrome.Appearance{ .light, .dark }) |appearance| {
        state.appearance = appearance;
        state.theme_store.select(state.theme_family, appearance);
        @memset(&pixels, appearance.palette().paper);
        state.renderTimelineInto(&pixels, 0);
        var fresh: [320 * 240]u16 = @splat(appearance.palette().paper);
        state.rendered_screen = null;
        state.renderInto(&fresh, 0);
        try std.testing.expectEqualSlices(u16, fresh[188 * 320 .. 230 * 320], pixels[188 * 320 .. 230 * 320]);
    }
}

test "pocket lock suppresses controls and frames, consumes unlock, and preserves long Power shutdown" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    state.navigate(.player);
    const old_volume = state.attenuation;
    _ = state.button(.power, true, 0, true);
    _ = state.button(.power, false, 100, true);
    try std.testing.expect(state.locked);
    const before = TestPlatform.Display.submissions;
    for (0..100) |i| {
        _ = state.button(.volume_up, true, 101 + i * 100, true);
        _ = state.repeat(102 + i * 100, navigation.Button.volume_up.mask(), true);
        _ = state.wheel(1, 103 + i * 100, true);
        state.frame(104 + i * 100);
    }
    try std.testing.expectEqual(old_volume, state.attenuation);
    try std.testing.expectEqual(before, TestPlatform.Display.submissions);
    _ = state.button(.power, true, 11000, true);
    _ = state.button(.power, false, 11100, true);
    try std.testing.expect(!state.locked);
    try std.testing.expectEqual(media.PlaybackCommand.none, state.repeat(12000, navigation.Button.volume_up.mask(), true));
    _ = state.button(.volume_up, false, 12001, true);
    _ = state.button(.power, true, 13000, true);
    _ = state.button(.power, false, 15000, true);
    try std.testing.expect(!state.locked);
}

test "fine volume steps reach all 113 positions with distinct bar targets and bounded endpoints" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    state.attenuation = 128;
    state.animation.reduced_motion = true;
    var last_width: u16 = 0;
    for (0..112) |i| {
        const command = state.handle(.volume_up, i * 500, true);
        try std.testing.expectEqual(media.PlaybackCommand{ .set_attenuation = @intCast(127 - i) }, command);
        const width: u16 = @intFromFloat(state.animation.value(i * 500) * 288 / 100);
        try std.testing.expect(width > last_width);
        last_width = width;
    }
    try std.testing.expectEqual(288, last_width);
    try std.testing.expectEqual(media.PlaybackCommand.none, state.handle(.volume_up, 60000, true));
    try std.testing.expectEqual(media.PlaybackCommand{ .set_attenuation = 17 }, state.handle(.volume_down, 60500, true));
    state.attenuation = 127;
    try std.testing.expectEqual(media.PlaybackCommand{ .set_attenuation = 128 }, state.act(.{ .adjust_volume = -4 }, 61000, true));
    try std.testing.expectEqual(media.PlaybackCommand.none, state.handle(.volume_down, 61500, true));
}

test "display timeout wakes through ordinary input without locking or changing the queue" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    state.display_timeout = .seconds15;
    state.frame(0);
    state.frame(14999);
    try std.testing.expect(!state.display_asleep);
    state.frame(15000);
    try std.testing.expect(state.display_asleep and !state.locked);
    _ = state.button(.volume_down, true, 16000, true);
    try std.testing.expect(!state.display_asleep);
    try std.testing.expectEqual(@as(u8, 65), state.attenuation);
    _ = state.button(.volume_down, false, 16100, true);
    state.frame(32000);
    try std.testing.expect(state.display_asleep);
    _ = state.button(.power, true, 33000, true);
    _ = state.button(.power, false, 33100, true);
    try std.testing.expect(!state.display_asleep and !state.locked);
    state.display_timeout = .never;
    state.frame(10000000);
    try std.testing.expect(!state.display_asleep);
}

test "pressing or holding volume at either endpoint keeps its cue alive without DAC commands" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    for ([_]u8{ 16, 128 }) |attenuation| {
        state.attenuation = attenuation;
        const event: Input = if (attenuation == 16) .volume_up else .volume_down;
        for (0..80) |i| {
            const now = i * 50;
            try std.testing.expectEqual(media.PlaybackCommand.none, state.handle(event, now, true));
            _ = state.animation.tick(now);
        }
        try std.testing.expectEqual(@as(f32, 1), state.animation.mix(4000));
        _ = state.animation.tick(5500);
        try std.testing.expectEqual(@as(f32, 0), state.animation.mix(5500));
    }
}

test "every bundled theme preserves transport damage and retained Cover Flow across scan changes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const tracks = [_]core.Track{
        .{ .id = 1, .path = "One/1.flac", .stamp = .{}, .meta = .{ .title = "A deliberately long title for wrapping and clipping", .artist = "Test artist", .album = "One", .codec = "flac" } },
        .{ .id = 2, .path = "Two/1.flac", .stamp = .{}, .meta = .{ .title = "Second", .artist = "Test artist", .album = "Two", .codec = "flac" } },
    };
    try fixture.pair.publish(&.{}, &tracks, 1, true);
    var state = fixture.state();
    state.playing_track = &tracks[0];
    state.status = .{ .phase = .playing, .sample_rate = 48000, .output_format = .signed_24_in_u32, .total_frames = 48000 * 100, .played_frames = 48000 * 20 };
    var retained: [320 * 240]u16 = undefined;
    var fresh: [320 * 240]u16 = undefined;
    for (0..5) |family| for ([_]chrome.Appearance{ .light, .dark }) |appearance| {
        state.theme_family = @fromBackingInt(@intCast(family));
        state.appearance = appearance;
        state.theme_store.select(state.theme_family, appearance);
        state.navigate(.player);
        state.animation = .{};
        state.renderInto(&retained, 0);
        state.animation.request(0, 90.5);
        for ([_]u64{ 0, 40, 80, 140, 500, 1450, 1540, 1900 }) |now| {
            _ = state.animation.tick(now);
            state.status.played_frames += 197;
            state.renderTimelineInto(&retained, now);
            var reference = state;
            reference.rendered_screen = null;
            reference.renderInto(&fresh, now);
            try std.testing.expectEqualSlices(u16, &fresh, &retained);
        }
        state.navigate(.albums);
        state.renderInto(&retained, 0);
        for (0..24) |step| {
            state.flow = @as(f32, @floatFromInt(step % 9)) / 10;
            test_diag.report.scan_active = if (step % 5 < 3) 1 else 0;
            test_diag.report.scan_total = 100;
            test_diag.report.scan_visited = @intCast(step * 4);
            state.renderInto(&retained, step * 17);
            var reference = state;
            reference.rendered_screen = null;
            reference.renderInto(&fresh, step * 17);
            try std.testing.expectEqualSlices(u16, &fresh, &retained);
        }
    };
}

test "custom overlapping layers survive transport and Cover Flow partial redraws" {
    const parsed = try std.json.parseFromSlice(theme.Document, std.testing.allocator, @embedFile("themes/classic-light.json"), .{});
    defer parsed.deinit();
    var document = parsed.value;
    const overlay = theme.Node{ .kind = .text, .rect = .{ .x = 10, .y = 195, .w = 100, .h = 20 }, .value = "Overlay", .color = .accent };
    const player = try std.testing.allocator.alloc(theme.Node, document.screens.player.len + 2);
    defer std.testing.allocator.free(player);
    @memcpy(player[0 .. player.len - 2], document.screens.player);
    player[player.len - 2] = overlay;
    player[player.len - 1] = .{ .kind = .artwork, .rect = .{ .x = 125, .y = 194, .w = 24, .h = 24 } };
    document.screens.player = player;
    const albums = try std.testing.allocator.alloc(theme.Node, document.screens.albums.len + 1);
    defer std.testing.allocator.free(albums);
    @memcpy(albums[0 .. albums.len - 1], document.screens.albums);
    albums[albums.len - 1] = overlay;
    document.screens.albums = albums;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var state = fixture.state();
    try theme.compile(document, &state.theme_store.banks[0]);
    state.theme_store.has_custom = true;
    state.theme_store.using_custom = true;
    const tracks = [_]core.Track{.{ .id = 1, .path = "Album/one.flac", .stamp = .{}, .meta = .{ .title = "One", .album = "Album", .artist = "Artist" } }};
    try fixture.pair.publish(&.{}, &tracks, 1, true);
    const album = state.snapshot().albums[0];
    const load = covers.Cache.Load{ .slot = 0, .request = .{ .id = album.id, .art = album.art } };
    fixture.cache.begin(load);
    fixture.cache.tiles[0] = .{ .width = 128, .height = 128, .pixels = @splat(0x07e0) };
    fixture.cache.publish(load);
    state.playing_track = &tracks[0];
    state.status = .{ .phase = .playing, .sample_rate = 48000, .output_format = .signed_24_in_u32, .total_frames = 480000, .played_frames = 48000 };
    var retained: [320 * 240]u16 = undefined;
    var fresh: [320 * 240]u16 = undefined;
    for ([_]Screen{ .player, .albums }) |screen| {
        state.navigate(screen);
        state.renderInto(&retained, 0);
        state.animation.request(0, 80);
        for (0..20) |step| {
            const now = step * 17;
            _ = state.animation.tick(now);
            state.flow = @as(f32, @floatFromInt(step)) / 30;
            if (screen == .player) state.renderTimelineInto(&retained, now) else state.renderInto(&retained, now);
            var reference = state;
            reference.rendered_screen = null;
            reference.renderInto(&fresh, now);
            try std.testing.expectEqualSlices(u16, &fresh, &retained);
        }
    }
}
