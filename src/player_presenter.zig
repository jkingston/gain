//! Portable playback display coordinator. Backend is selected at compile time;
//! views never see MMIO, while tests drive the same prepare/commit/pump path.
const ui = @import("ui.zig");
const view = @import("player_view.zig");
const transfer = @import("display_transfer.zig");
pub const State = struct {
    begun: bool = false,
    commit_pending: bool = false,
    displayed_second: u64 = 0,
    attenuation: u8 = 64,
    pending: transfer.Scheduler = .{},

    pub fn begin(self: *State, comptime Backend: type, track: view.Track, status: view.Status, battery_mv: u32, attenuation: u8, theme: ui.Theme) !void {
        if (self.begun) return error.AlreadyBegun;
        var scene = ui.Ui.init(.{ .pixels = Backend.framebuffer });
        try view.player(&scene, track, status, battery_mv, attenuation, theme);
        scene.finish();
        // The full snapshot is prepared before the media engine starts.
        try Backend.prepare(.{ .x = 0, .y = 0, .width = ui.screen_width, .height = ui.screen_height });
        self.begun = true;
        self.commit_pending = true;
        self.attenuation = attenuation;
        self.displayed_second = second(status);
    }

    pub fn update(self: *State, comptime Backend: type, status: view.Status, playing: bool, attenuation: u8, theme: ui.Theme) !void {
        if (!self.begun) return error.NotBegun;
        if (self.commit_pending and playing) {
            try Backend.commit();
            self.commit_pending = false;
        }
        var scene = ui.Ui.init(.{ .pixels = Backend.framebuffer });
        const current_second = second(status);
        if (current_second != self.displayed_second) {
            try view.progress(&scene, status, theme);
            self.displayed_second = current_second;
            self.pending.request(view.progress_region, .normal);
        }
        if (attenuation != self.attenuation) {
            try view.volume(&scene, attenuation, theme);
            self.attenuation = attenuation;
            self.pending.request(view.volume_region, .urgent);
        }
        scene.finish();
        if (self.commit_pending) return;
        switch (Backend.poll()) {
            .failed => return error.DisplayFailure,
            .busy => return,
            .idle => {},
        }
        if (self.pending.take()) |region| {
            if (!Backend.start(region.x, region.y, region.width, region.height)) return error.DisplayFailure;
        }
    }
    fn second(status: view.Status) u64 {
        return status.played_frames / @max(status.sample_rate, 1);
    }
};

const Fake = struct {
    const presentation = @import("presentation.zig");
    var canvas: [ui.pixel_count]u16 = undefined;
    pub const framebuffer = &canvas;
    var source: [ui.pixel_count]u16 = undefined;
    var frozen: [ui.pixel_count]u16 = undefined;
    var panel: [ui.pixel_count]u16 = undefined;
    var ownership = presentation.State{};
    var region: transfer.Region = undefined;
    var now: u32 = 0;
    var pixels_sent: usize = 0;
    var disabled: bool = false;
    var releases: u32 = 0;
    var started: [64]transfer.Region = undefined;
    var start_count: usize = 0;
    var injected_fault = false;
    var integrity_failure = false;
    fn reset() void {
        ownership = .{};
        now = 0xffff0000;
        releases = 0;
        disabled = false;
        start_count = 0;
        injected_fault = false;
        integrity_failure = false;
        @memset(&canvas, 0);
        @memset(&panel, 0);
    }
    pub fn prepare(request: transfer.Region) !void {
        if (ownership.owned()) return error.Owned;
        region = try presentation.alignedRegion(request, 320, 240);
        try presentation.pack(&canvas, 320, 240, region, &source);
        @memcpy(frozen[0..region.pixels()], source[0..region.pixels()]);
        try ownership.prepare();
        pixels_sent = 0;
        disabled = false;
        if (start_count < started.len) {
            started[start_count] = region;
            start_count += 1;
        }
    }
    pub fn commit() !void {
        try ownership.commit(now);
    }
    pub fn start(x: usize, y: usize, width: usize, height: usize) bool {
        prepare(.{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(width), .height = @intCast(height) }) catch return false;
        commit() catch return false;
        return true;
    }
    pub fn poll() enum { idle, busy, failed } {
        now +%= 1;
        if (!ownership.owned()) return .idle;
        if (ownership.phase == .prepared) return .busy;
        if (!@import("std").mem.eql(u16, frozen[0..region.pixels()], source[0..region.pixels()])) integrity_failure = true;
        const end = @min(region.pixels(), pixels_sent + 317);
        for (pixels_sent..end) |index| panel[(@as(usize, region.y) + index / region.width) * 320 + region.x + index % region.width] = source[index];
        pixels_sent = end;
        // EOF precedes the final bus writes. QD is observed only on a later poll.
        const action = ownership.observe(now, 10000, .{ .eof = pixels_sent >= region.pixels() / 2, .bus_busy = pixels_sent < region.pixels(), .disable_done = disabled, .fault = injected_fault }) catch return .failed;
        switch (action) {
            .none => {},
            .disable => disabled = true,
            .release => {
                releases += 1;
                return .idle;
            },
        }
        return .busy;
    }
};

test "actual presenter coalesces volume and progress while delayed DMA owns the old screen" {
    const t = @import("std").testing;
    Fake.reset();
    var state = State{};
    const track = view.Track{ .name = "Track", .artist = "Artist", .album = "Album" };
    var status = view.Status{ .sample_rate = 48000, .total_frames = 48000 * 60, .played_frames = 0, .bits = 24 };
    try t.expectError(error.NotBegun, state.update(Fake, status, false, 64, ui.dark_theme));
    try state.begin(Fake, track, status, 4100, 64, ui.dark_theme);
    try t.expectError(error.AlreadyBegun, state.begin(Fake, track, status, 4100, 64, ui.dark_theme));
    try state.update(Fake, status, false, 60, ui.dark_theme);
    try t.expectEqual(@import("presentation.zig").Phase.prepared, Fake.ownership.phase);
    for (0..1500) |tick| {
        if (tick < 600 and tick % 7 == 0) status.played_frames = @as(u64, @intCast(tick / 7)) * 48000;
        const attenuation: u8 = if (tick < 600) @intCast(16 + (tick / 3 % 29) * 4) else 64;
        try state.update(Fake, status, true, attenuation, ui.dark_theme);
    }
    try t.expect(!Fake.integrity_failure and !Fake.ownership.owned());
    try t.expect(Fake.releases > 3);
    try t.expectEqual(view.volume_region, Fake.started[1]);
    var expected: [ui.pixel_count]u16 = undefined;
    var fresh = ui.Ui.init(.{ .pixels = &expected });
    try view.player(&fresh, track, status, 4100, 64, ui.dark_theme);
    fresh.finish();
    try t.expectEqualSlices(u16, &expected, &Fake.panel);
}

test "device failure is returned through the actual presenter" {
    Fake.reset();
    var state = State{};
    const status = view.Status{ .sample_rate = 44100, .total_frames = 44100, .played_frames = 0, .bits = 16 };
    try state.begin(Fake, .{ .name = "Track" }, status, 4100, 64, ui.dark_theme);
    Fake.injected_fault = true;
    try @import("std").testing.expectError(error.DisplayFailure, state.update(Fake, status, true, 64, ui.dark_theme));
    try @import("std").testing.expect(Fake.ownership.owned());
}
