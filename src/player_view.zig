//! Product view declarations. No MMIO, storage I/O, clocks or allocation.
const std = @import("std");
const ui = @import("ui.zig");
pub const visible_rows = 6;
pub const audio_extensions = [_][]const u8{ ".flac", ".fla", ".wav", ".aif", ".aiff", ".aifc", ".mp3", ".mp2", ".mp1", ".m4a", ".mp4", ".ogg", ".oga", ".opus" };
pub const volume_region = @import("display_transfer.zig").Region{ .x = 275, .y = 7, .width = 18, .height = 7 };
pub const progress_region = @import("display_transfer.zig").Region{ .x = 0, .y = 180, .width = 320, .height = 42 };
pub const Status = struct { sample_rate: u32, total_frames: u64, played_frames: u64, bits: u8 };
pub const Track = struct { name: []const u8, artist: []const u8 = "", album: []const u8 = "" };
pub const BrowserState = struct {
    directory: u32,
    first: usize,
    selected: usize,
    attenuation: u8,
};
pub const BrowserDamage = struct { full: bool = false, regions: [3]@import("display_transfer.zig").Region = undefined, count: usize = 0 };
pub fn browserDamage(previous: ?BrowserState, next: BrowserState) BrowserDamage {
    const old = previous orelse return .{ .full = true };
    if (old.directory != next.directory or old.first != next.first) return .{ .full = true };
    var result = BrowserDamage{};
    if (old.attenuation != next.attenuation) {
        result.regions[result.count] = volume_region;
        result.count += 1;
    }
    if (old.selected != next.selected) {
        for ([_]usize{ old.selected, next.selected }) |selected| {
            if (selected < next.first or selected - next.first >= visible_rows) return .{ .full = true };
            result.regions[result.count] = .{ .x = 7, .y = @intCast(59 + (selected - next.first) * 27), .width = 306, .height = 23 };
            result.count += 1;
        }
    }
    return result;
}

const whole = ui.Rect{ .x = 0, .y = 0, .width = ui.screen_width, .height = ui.screen_height };

fn label(scene: *ui.Ui, x: i32, y: i32, width: u16, height: u16, value: []const u8, color: ui.Color, scale: u2) ui.Error!void {
    try scene.text(.{ .x = x, .y = y, .width = width, .height = height }, value, .{ .color = color, .scale = scale });
}
fn decimal3(initial: u8) [3]u8 {
    var value = initial;
    var output: [3]u8 = undefined;
    output[2] = '0' + value % 10;
    value /= 10;
    output[1] = if (value != 0 or initial == 100) '0' + value % 10 else ' ';
    value /= 10;
    output[0] = if (value != 0) '0' + value else ' ';
    return output;
}
pub fn volume(scene: *ui.Ui, attenuation: u8, theme: ui.Theme) ui.Error!void {
    try scene.fill(.{ .x = volume_region.x, .y = volume_region.y, .width = volume_region.width, .height = volume_region.height }, theme.surface);
    const bounded = std.math.clamp(attenuation, 16, 128);
    const percent: u8 = @intCast(@as(u16, 128 - bounded) * 100 / 112);
    try label(scene, 275, 7, 18, 7, &decimal3(percent), theme.accent, 1);
}
fn header(scene: *ui.Ui, battery_mv: u32, attenuation: u8, theme: ui.Theme) ui.Error!void {
    try scene.fill(.{ .x = 0, .y = 0, .width = 320, .height = 30 }, theme.surface);
    try label(scene, 10, 7, 100, 16, "GAIN", theme.text, 2);
    const percent: u8 = if (battery_mv <= 3300) 0 else if (battery_mv >= 4200) 100 else @intCast((battery_mv - 3300) * 100 / 900);
    try label(scene, 242, 7, 18, 7, if (battery_mv == 0) "---" else &decimal3(percent), theme.text, 1);
    try label(scene, 261, 7, 6, 7, "%", theme.text, 1);
    try volume(scene, attenuation, theme);
}
pub fn browser(scene: *ui.Ui, title: []const u8, empty: bool, battery_mv: u32, attenuation: u8, theme: ui.Theme) ui.Error!void {
    try scene.fill(whole, theme.background);
    try header(scene, battery_mv, attenuation, theme);
    try label(scene, 10, 40, 300, 7, title[0..@min(title.len, 48)], theme.accent, 1);
    if (empty) try label(scene, 82, 112, 228, 14, "NO AUDIO FILES", theme.text, 2);
    try label(scene, 10, 225, 180, 7, "PLAY SELECT", theme.muted, 1);
    try label(scene, 226, 225, 84, 7, "BACK", theme.muted, 1);
}
pub fn browserRow(scene: *ui.Ui, row: usize, name: []const u8, directory: bool, active: bool, theme: ui.Theme) ui.Error!void {
    if (row >= visible_rows) return;
    const y: i32 = @intCast(59 + row * 27);
    if (active) try scene.fill(.{ .x = 7, .y = y, .width = 306, .height = 23 }, theme.accent);
    try label(scene, 14, y + 8, 278, 7, name[0..@min(name.len, 45)], if (active) theme.accent_text else theme.text, 1);
    if (directory) try label(scene, 298, y + 8, 8, 7, ">", if (active) theme.accent_text else theme.accent, 1);
}
pub fn cleanTrackName(raw: []const u8) []const u8 {
    var end = raw.len;
    for (audio_extensions) |extension| {
        if (raw.len >= extension.len and std.ascii.eqlIgnoreCase(raw[raw.len - extension.len ..], extension)) {
            end -= extension.len;
            break;
        }
    }
    var start: usize = 0;
    while (start < end and raw[start] >= '0' and raw[start] <= '9') start += 1;
    if (start != 0) {
        while (start < end and raw[start] == ' ') start += 1;
        if (start < end and raw[start] == '-') start += 1;
        while (start < end and raw[start] == ' ') start += 1;
    }
    return raw[start..end];
}

fn firstLineLength(value: []const u8, maximum: usize) usize {
    if (value.len <= maximum) return value.len;
    var split = maximum;
    while (split != 0 and value[split] != ' ') split -= 1;
    return if (split == 0) maximum else split;
}

fn timeText(seconds_initial: u64, output: *[5]u8) void {
    const seconds = @min(seconds_initial, 99 * 60 + 59);
    const minutes = seconds / 60;
    const remainder = seconds % 60;
    output[0] = '0' + @as(u8, @intCast(minutes / 10));
    output[1] = '0' + @as(u8, @intCast(minutes % 10));
    output[2] = ':';
    output[3] = '0' + @as(u8, @intCast(remainder / 10));
    output[4] = '0' + @as(u8, @intCast(remainder % 10));
}

fn sampleRateText(rate: u32) []const u8 {
    return switch (rate) {
        8000 => "8 KHZ",
        11025 => "11.025 KHZ",
        12000 => "12 KHZ",
        16000 => "16 KHZ",
        22050 => "22.05 KHZ",
        24000 => "24 KHZ",
        32000 => "32 KHZ",
        64000 => "64 KHZ",
        44_100 => "44.1 KHZ",
        48_000 => "48 KHZ",
        88_200 => "88.2 KHZ",
        96_000 => "96 KHZ",
        176_400 => "176.4 KHZ",
        192_000 => "192 KHZ",
        else => "FLAC",
    };
}

pub fn progress(scene: *ui.Ui, status: Status, theme: ui.Theme) ui.Error!void {
    try scene.fill(.{ .x = 0, .y = 180, .width = 320, .height = 42 }, theme.background);
    // Widen before multiplying; corrupt/very long durations cannot wrap.
    const width: u16 = if (status.total_frames == 0) 0 else @intCast(@min(@as(u128, status.played_frames) * 300 / status.total_frames, 300));
    try scene.fill(.{ .x = 10, .y = 186, .width = 300, .height = 5 }, theme.surface_raised);
    try scene.fill(.{ .x = 10, .y = 186, .width = width, .height = 5 }, theme.accent);
    var elapsed: [5]u8 = undefined;
    var total: [5]u8 = undefined;
    const rate = @max(status.sample_rate, 1);
    timeText(status.played_frames / rate, &elapsed);
    timeText(status.total_frames / rate, &total);
    try label(scene, 10, 201, 30, 7, &elapsed, theme.text, 1);
    try label(scene, 280, 201, 30, 7, &total, theme.text, 1);
}
pub fn player(scene: *ui.Ui, track: Track, status: Status, battery_mv: u32, attenuation: u8, theme: ui.Theme) ui.Error!void {
    try scene.fill(whole, theme.background);
    try header(scene, battery_mv, attenuation, theme);
    try label(scene, 10, 42, 300, 7, track.artist[0..@min(track.artist.len, 48)], theme.accent, 1);
    const name = cleanTrackName(track.name);
    const first = firstLineLength(name, 24);
    try label(scene, 10, 66, 300, 14, name[0..first], theme.text, 2);
    if (first < name.len) {
        const start = first + @as(usize, @intFromBool(name[first] == ' '));
        const second = name[start..];
        try label(scene, 10, 88, 300, 14, second[0..@min(second.len, 24)], theme.text, 2);
    }
    try label(scene, 10, 124, 300, 7, track.album[0..@min(track.album.len, 48)], theme.muted, 1);
    try label(scene, 10, 151, 48, 7, if (status.bits == 24) "24 BIT" else "16 BIT", theme.accent, 1);
    try label(scene, 64, 151, 246, 7, sampleRateText(status.sample_rate), theme.accent, 1);
    try progress(scene, status, theme);
    try label(scene, 10, 228, 300, 7, "PLAY / BACK", theme.muted, 1);
}

test "regional progress and volume equal a fresh complete player render" {
    var actual: [ui.pixel_count]u16 = undefined;
    var expected: [ui.pixel_count]u16 = undefined;
    const track = Track{ .name = "01 - A very long name that wraps across two lines.FLAC", .artist = "Artist", .album = "Album" };
    for ([_]ui.Theme{ ui.dark_theme, ui.light_theme }) |theme| {
        for ([_]u8{ 0, 16, 64, 128, 255 }) |attenuation| {
            var old = ui.Ui.init(.{ .pixels = &actual });
            try player(&old, track, .{ .sample_rate = 192000, .total_frames = 192000 * 20, .played_frames = 0, .bits = 24 }, 4000, 64, theme);
            old.finish();
            var change = ui.Ui.init(.{ .pixels = &actual });
            const status = Status{ .sample_rate = 192000, .total_frames = 192000 * 20, .played_frames = 192000 * 19, .bits = 24 };
            try progress(&change, status, theme);
            try volume(&change, attenuation, theme);
            change.finish();
            var fresh = ui.Ui.init(.{ .pixels = &expected });
            try player(&fresh, track, status, 4000, attenuation, theme);
            fresh.finish();
            try std.testing.expectEqualSlices(u16, &expected, &actual);
        }
    }
}

test "actual browser to player transition matches independent pixel translation at every offset" {
    var browser_pixels: [ui.pixel_count]u16 = undefined;
    var player_pixels: [ui.pixel_count]u16 = undefined;
    var actual: [ui.pixel_count]u16 = undefined;
    var before = ui.Ui.init(.{ .pixels = &browser_pixels });
    try browser(&before, "MUSIC", false, 4100, 64, ui.dark_theme);
    for (0..visible_rows) |row| try browserRow(&before, row, "01 - Sample.FLAC", row == 0, row == 2, ui.dark_theme);
    before.render(.{ .pixels = &browser_pixels });
    var after = ui.Ui.init(.{ .pixels = &player_pixels });
    try player(&after, .{ .name = "01 - Sample.FLAC", .artist = "Artist", .album = "Album" }, .{ .sample_rate = 44100, .total_frames = 44100 * 60, .played_frames = 44100 * 30, .bits = 16 }, 4100, 64, ui.light_theme);
    after.render(.{ .pixels = &player_pixels });
    for (0..321) |offset| {
        ui.slide(&before, &after, &actual, @intCast(offset));
        for (actual, 0..) |pixel, index| {
            const x = index % 320;
            const y = index / 320;
            const want = if (x + offset < 320) browser_pixels[y * 320 + x + offset] else player_pixels[y * 320 + x + offset - 320];
            try std.testing.expectEqual(want, pixel);
        }
    }
}

test "maximum names rows formats and invalid durations fit fixed declaration budgets" {
    const name: [512]u8 = @splat('W');
    var pixels: [ui.pixel_count]u16 = undefined;
    for ([_]ui.Theme{ ui.dark_theme, ui.light_theme }) |theme| {
        var scene = ui.Ui.init(.{ .pixels = &pixels });
        try browser(&scene, &name, false, 0xffffffff, 255, theme);
        for (0..visible_rows + 1) |row| try browserRow(&scene, row, &name, true, true, theme);
        scene.finish();
        for ([_]u32{ 0, 44100, 48000, 88200, 96000, 176400, 192000 }) |rate| {
            try player(&scene, .{ .name = &name, .artist = &name, .album = &name }, .{ .sample_rate = rate, .played_frames = std.math.maxInt(u64), .total_frames = 0, .bits = 24 }, 0, 0, theme);
            scene.finish();
            try progress(&scene, .{ .sample_rate = rate, .played_frames = std.math.maxInt(u64), .total_frames = 1, .bits = 16 }, theme);
            scene.finish();
        }
    }
    try std.testing.expectEqualStrings("Track", cleanTrackName("01 - Track.FLAC"));
}

test "hybrid browser presentation uses two rows for selection and full frames for new viewports" {
    const state = BrowserState{ .directory = 2, .first = 0, .selected = 0, .attenuation = 64 };
    var next = state;
    next.selected = 1;
    const damage = browserDamage(state, next);
    try std.testing.expect(!damage.full and damage.count == 2);
    for (damage.regions[0..damage.count]) |region| try std.testing.expect(region.pixels() <= 320 * 42);
    next.attenuation = 60;
    try std.testing.expectEqual(@as(usize, 3), browserDamage(state, next).count);
    next.first = 1;
    try std.testing.expect(browserDamage(state, next).full);
    next = state;
    next.directory = 3;
    try std.testing.expect(browserDamage(state, next).full);
    try std.testing.expect(browserDamage(null, state).full);
    try std.testing.expectEqual(@as(usize, 0), browserDamage(state, state).count);
}

test "hybrid selection regions reconstruct the entire next browser exactly" {
    var previous: [ui.pixel_count]u16 = undefined;
    var next: [ui.pixel_count]u16 = undefined;
    for (0..visible_rows) |old| for (0..visible_rows) |selected| {
        var a = ui.Ui.init(.{ .pixels = &previous });
        var b = ui.Ui.init(.{ .pixels = &next });
        try browser(&a, "MUSIC", false, 4100, 64, ui.dark_theme);
        try browser(&b, "MUSIC", false, 4100, 60, ui.dark_theme);
        for (0..visible_rows) |row| {
            try browserRow(&a, row, "Track", false, row == old, ui.dark_theme);
            try browserRow(&b, row, "Track", false, row == selected, ui.dark_theme);
        }
        a.finish();
        b.finish();
        const damage = browserDamage(.{ .directory = 2, .first = 0, .selected = old, .attenuation = 64 }, .{ .directory = 2, .first = 0, .selected = selected, .attenuation = 60 });
        try std.testing.expect(!damage.full);
        for (damage.regions[0..damage.count]) |region| for (region.y..region.y + region.height) |y| {
            const offset = y * 320 + region.x;
            @memcpy(previous[offset..][0..region.width], next[offset..][0..region.width]);
        };
        try std.testing.expectEqualSlices(u16, &next, &previous);
    };
}

test "all advertised audio containers remove their extension from track titles" {
    for (audio_extensions) |extension| {
        var name: [32]u8 = undefined;
        const prefix = "01 - Track";
        @memcpy(name[0..prefix.len], prefix);
        @memcpy(name[prefix.len..][0..extension.len], extension);
        try std.testing.expectEqualStrings("Track", cleanTrackName(name[0 .. prefix.len + extension.len]));
        for (name[prefix.len..][0..extension.len]) |*character| character.* = std.ascii.toUpper(character.*);
        try std.testing.expectEqualStrings("Track", cleanTrackName(name[0 .. prefix.len + extension.len]));
    }
}
