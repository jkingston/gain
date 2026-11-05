//! The real player input/view controller, shared with physical qualification.
const controls = @import("playback_controls.zig");
const presenter = @import("player_presenter.zig");
const view = @import("player_view.zig");
const ui = @import("ui.zig");
const media = @import("f20_media.zig");

pub const State = struct {
    controls: controls.State,
    display: presenter.State = .{},
    failed: bool = false,
    text_revision: u32 = 0,

    pub fn init(attenuation: u8) State {
        return .{ .controls = controls.State.init(attenuation) };
    }

    pub fn poll(self: *State, comptime Display: type, buttons: u8, track: view.Track, battery_mv: u32, theme: ui.Theme, status: media.PlaybackStatus) media.PlaybackCommand {
        const command: media.PlaybackCommand = switch (self.controls.update(buttons)) {
            .none => .none,
            .stop => .stop,
            .toggle_pause => .toggle_pause,
            .next => .next,
            .previous => .previous,
            .set_attenuation => |value| .{ .set_attenuation = value },
        };
        if (status.sample_rate == 0) return command;
        const current = view.Status{ .sample_rate = status.sample_rate, .total_frames = status.total_frames, .played_frames = status.played_frames, .bits = if (status.output_format == .signed_24_in_u32) 24 else 16 };
        if (@hasDecl(Display, "text_cache")) if (Display.text_cache) |cache| {
            const revision = cache.revision.load(.acquire);
            if (revision != self.text_revision and !self.display.commit_pending and Display.poll() == .idle) {
                self.text_revision = revision;
                self.display = .{};
            }
        };
        if (!self.display.begun) self.display.begin(Display, track, current, battery_mv, self.controls.attenuation, theme) catch return self.failedDisplay();
        self.display.update(Display, current, status.phase == .playing, self.controls.attenuation, theme) catch return self.failedDisplay();
        return command;
    }

    fn failedDisplay(self: *State) media.PlaybackCommand {
        self.failed = true;
        return .stop;
    }
};

const FailedDisplay = struct {
    var pixels: [ui.pixel_count]u16 = undefined;
    pub const framebuffer = &pixels;

    pub fn prepare(_: @import("display_transfer.zig").Region) !void {
        return error.Transfer;
    }

    pub fn commit() !void {}

    pub fn poll() enum { idle, busy, failed } {
        return .idle;
    }

    pub fn start(_: u16, _: u16, _: u16, _: u16) bool {
        return true;
    }
};

test "real player controller accepts stop before headers and reports display failure after headers" {
    const testing = @import("std").testing;

    var state = State.init(64);
    var status = media.PlaybackStatus{ .phase = .preparing, .sample_rate = 0, .output_format = .signed_24_in_u32, .total_frames = 0, .played_frames = 0 };
    const track = view.Track{ .name = "Track" };
    try testing.expectEqual(media.PlaybackCommand.none, state.poll(FailedDisplay, 0, track, 0, ui.dark_theme, status));
    try testing.expectEqual(media.PlaybackCommand.stop, state.poll(FailedDisplay, controls.Button.back.mask(), track, 0, ui.dark_theme, status));
    try testing.expect(!state.failed);
    status.sample_rate = 44100;
    try testing.expectEqual(media.PlaybackCommand.stop, state.poll(FailedDisplay, 0, track, 0, ui.dark_theme, status));
    try testing.expect(state.failed);
}
