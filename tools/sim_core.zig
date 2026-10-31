//! SDL-independent simulator policies, exercised by the ordinary host test suite.
const std = @import("std");
pub const api = @import("gain_simulator");
pub const max_request_bytes = 16 * 1024;
pub const max_dimension = 16_384;
pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Viewport = struct { rect: Rect, scale: i32 };

/// Compute in physical renderer pixels, including fractional desktop DPI scales.
pub fn viewport(width: i32, height: i32) !Viewport {
    if (width < api.width or height < api.height or width > max_dimension or height > max_dimension) return error.InvalidWindowSize;
    const scale = @min(@divTrunc(width, api.width), @divTrunc(height, api.height));
    return .{ .scale = scale, .rect = .{
        .x = @divTrunc(width - api.width * scale, 2),
        .y = @divTrunc(height - api.height * scale, 2),
        .width = api.width * scale,
        .height = api.height * scale,
    } };
}
pub const Buttons = struct {
    held: u16 = 0,
    pub fn apply(self: *Buttons, event: api.Event) bool {
        const mask = @as(u16, 1) << @intCast(@backingInt(event.input));
        switch (event.phase) {
            .press => {
                if (self.held & mask != 0) return false;
                self.held |= mask;
            },
            .release => {
                if (self.held & mask == 0) return false;
                self.held &= ~mask;
            },
            .repeat => if (self.held & mask == 0) return false,
        }
        return true;
    }
};
pub const Wheel = struct {
    remainder: f64 = 0,
    /// Preserve fractional scroll instead of turning each trackpad sample into a detent.
    pub fn add(self: *Wheel, delta: f64) i16 {
        if (!std.math.isFinite(delta)) return 0;
        self.remainder = std.math.clamp(self.remainder + delta, -128, 128);
        const steps: i16 = @intFromFloat(self.remainder);
        self.remainder -= @floatFromInt(steps);
        return steps;
    }
};
pub const Operation = enum { input, resize, reload, load, capture, state, quit };
pub const InputPhase = enum { tap, press, release, repeat };
pub const Request = struct {
    id: u64,
    op: Operation,
    button: ?api.Input = null,
    phase: InputPhase = .tap,
    path: ?[]const u8 = null,
    native: bool = true,
    width: ?i32 = null,
    height: ?i32 = null,

    pub fn validate(self: Request) !void {
        if (self.id == 0) return error.InvalidRequestId;
        switch (self.op) {
            .input => if (self.button == null) return error.MissingButton,
            .resize => {
                _ = try viewport(self.width orelse return error.MissingWidth, self.height orelse return error.MissingHeight);
            },
            .load, .capture => {
                const path = self.path orelse return error.MissingPath;
                if (path.len == 0 or path.len >= 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
            },
            else => {},
        }
    }
};
pub fn parseRequest(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Request) {
    if (bytes.len > max_request_bytes) return error.RequestTooLarge;
    const parsed = try std.json.parseFromSlice(Request, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const Stamp = struct { size: u64, modified: i64 };
pub const Watch = struct {
    seen: ?Stamp = null,
    changed_at: ?u64 = null,
    pub fn observe(self: *Watch, stamp: ?Stamp, now: u64) bool {
        if (!std.meta.eql(self.seen, stamp)) {
            self.seen = stamp;
            self.changed_at = now;
            return false;
        }
        if (stamp == null) return false;
        if (self.changed_at) |at| {
            if (now - at < 100) return false;
            self.changed_at = null;
            return true;
        }
        return false;
    }
};

test "physical pixels remain square, integer scaled and centred" {
    for ([_][2]i32{ .{ 320, 240 }, .{ 641, 481 }, .{ 960, 720 }, .{ 1600, 1200 }, .{ 1333, 999 }, .{ 16384, 16384 } }) |size| {
        const v = try viewport(size[0], size[1]);
        try std.testing.expectEqual(v.rect.width * 3, v.rect.height * 4);
        try std.testing.expectEqual(api.width * v.scale, v.rect.width);
        try std.testing.expect(v.rect.x >= 0 and v.rect.y >= 0 and v.rect.x + v.rect.width <= size[0] and v.rect.y + v.rect.height <= size[1]);
        try std.testing.expect(@abs(v.rect.x * 2 + v.rect.width - size[0]) <= 1);
    }
    try std.testing.expectError(error.InvalidWindowSize, viewport(319, 240));
    try std.testing.expectError(error.InvalidWindowSize, viewport(320, 100000));
}
test "press repeat release and focus loss do not leave duplicate or stuck buttons" {
    var buttons = Buttons{};
    for (std.enums.values(api.Input)) |input| {
        try std.testing.expect(buttons.apply(.{ .input = input }));
        try std.testing.expect(!buttons.apply(.{ .input = input }));
        try std.testing.expect(buttons.apply(.{ .input = input, .phase = .repeat }));
        try std.testing.expect(buttons.apply(.{ .input = input, .phase = .release }));
        try std.testing.expect(!buttons.apply(.{ .input = input, .phase = .release }));
        try std.testing.expect(!buttons.apply(.{ .input = input, .phase = .repeat }));
    }
    try std.testing.expectEqual(0, buttons.held);
}
test "wheel conserves fractional detents reverses direction and rejects nonfinite input" {
    var wheel = Wheel{};
    for (0..3) |_| try std.testing.expectEqual(0, wheel.add(0.25));
    try std.testing.expectEqual(1, wheel.add(0.25));
    try std.testing.expectEqual(0, wheel.add(-0.5));
    try std.testing.expectEqual(-2, wheel.add(-1.5));
    try std.testing.expectEqual(0, wheel.add(std.math.nan(f64)));
    try std.testing.expectEqual(0, wheel.add(std.math.inf(f64)));
    try std.testing.expectEqual(128, wheel.add(1e30));
}
test "JSON commands preserve spaces Unicode and reject malformed or incomplete requests" {
    const parsed = try parseRequest(std.testing.allocator, "{\"id\":1,\"op\":\"load\",\"path\":\"/tmp/Anaïs music/app.dylib\"}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/tmp/Anaïs music/app.dylib", parsed.value.path.?);
    try std.testing.expectError(error.MissingButton, parseRequest(std.testing.allocator, "{\"id\":1,\"op\":\"input\"}"));
    try std.testing.expectError(error.InvalidPath, parseRequest(std.testing.allocator, "{\"id\":1,\"op\":\"load\",\"path\":\"x\\u0000y\"}"));
    try std.testing.expectError(error.InvalidRequestId, parseRequest(std.testing.allocator, "{\"id\":0,\"op\":\"quit\"}"));
    var huge: [max_request_bytes + 1]u8 = @splat(' ');
    try std.testing.expectError(error.RequestTooLarge, parseRequest(std.testing.allocator, &huge));
}
test "watch waits for stable output and does not retry a failed build forever" {
    var watch = Watch{ .seen = .{ .size = 1, .modified = 1 } };
    try std.testing.expect(!watch.observe(.{ .size = 2, .modified = 2 }, 0));
    try std.testing.expect(!watch.observe(.{ .size = 3, .modified = 3 }, 90));
    try std.testing.expect(!watch.observe(.{ .size = 3, .modified = 3 }, 189));
    try std.testing.expect(watch.observe(.{ .size = 3, .modified = 3 }, 190));
    try std.testing.expect(!watch.observe(.{ .size = 3, .modified = 3 }, 1000));
    try std.testing.expect(!watch.observe(null, 1001));
}

test "ABI rejects incompatible versions layout format and incomplete callbacks" {
    var interface = api.Api{};
    interface.version = 999;
    try std.testing.expectError(error.IncompatibleAppVersion, interface.validate());
    interface.version = api.abi_version;
    interface.size = 0;
    try std.testing.expectError(error.IncompatibleAppLayout, interface.validate());
    interface.size = @sizeOf(api.Api);
    interface.width = 999;
    try std.testing.expectError(error.IncompatibleDisplay, interface.validate());
    interface.width = api.width;
    try std.testing.expectError(error.MissingAppCallback, interface.validate());
}
test "fuzz bounded JSON requests without leaking parser allocations" {
    try std.testing.fuzz({}, fuzzRequest, .{ .corpus = &.{ "{\"id\":1,\"op\":\"state\"}", "{\"id\":2,\"op\":\"input\",\"button\":\"power\"}", "{}", "" } });
}
fn fuzzRequest(_: void, smith: *std.testing.Smith) !void {
    var buffer: [2048]u8 = undefined;
    const length = smith.slice(&buffer);
    const parsed = parseRequest(std.testing.allocator, buffer[0..length]) catch return;
    defer parsed.deinit();
    try parsed.value.validate();
}

/// Key aliases are separate sources for one physical button: releasing Space
/// must not release Select while Enter is still held.
pub const KeySources = struct {
    keys: [512]?api.Input = @splat(null),
    pub fn press(self: *KeySources, index: usize, input: api.Input) bool {
        if (index >= self.keys.len or self.keys[index] != null) return false;
        const already_held = self.contains(input);
        self.keys[index] = input;
        return !already_held;
    }
    pub fn release(self: *KeySources, index: usize) ?api.Input {
        if (index >= self.keys.len) return null;
        const input = self.keys[index] orelse return null;
        self.keys[index] = null;
        return if (self.contains(input)) null else input;
    }
    fn contains(self: *const KeySources, input: api.Input) bool {
        for (self.keys) |value| if (value == input) return true;
        return false;
    }
};
test "keyboard aliases release only after the last source and ignore stray keyups" {
    var sources = KeySources{};
    try std.testing.expect(sources.press(10, .select));
    try std.testing.expect(!sources.press(11, .select));
    try std.testing.expectEqual(null, sources.release(10));
    try std.testing.expectEqual(api.Input.select, sources.release(11).?);
    try std.testing.expectEqual(null, sources.release(11));
    try std.testing.expect(!sources.press(999, .menu));
}

test "snapshot callback pair is either complete or absent" {
    const Callbacks = struct {
        fn init(_: u64) callconv(.c) void {}
        fn input(_: api.Event, _: u64) callconv(.c) void {}
        fn frame(_: *api.Pixels, _: u64) callconv(.c) bool {
            return false;
        }
        fn save(_: [*]u8, _: usize) callconv(.c) usize {
            return 0;
        }
    };
    var interface = api.Api{ .init = Callbacks.init, .input = Callbacks.input, .frame = Callbacks.frame };
    try interface.validate();
    interface.save = Callbacks.save;
    try std.testing.expectError(error.IncompleteSnapshotCallbacks, interface.validate());
}
