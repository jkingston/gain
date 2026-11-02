//! Native module fixture for simulator lifecycle and pixel qualification.
const std = @import("std");
const api = @import("gain_simulator");
const options = @import("sim_fixture");

const State = extern struct { press: u32 = 0, release: u32 = 0, repeat: u32 = 0, last: u32 = 0, held: u32 = 0 };
var state = State{};
var dirty = true;
var last_time: u64 = 0;

fn init(at: u64) callconv(.c) void {
    last_time = at;
    state = .{};
    dirty = true;
}

fn input(event: api.Event, at: u64) callconv(.c) void {
    std.debug.assert(at >= last_time);
    last_time = at;
    state.last = @backingInt(event.input);
    const mask = @as(u32, 1) << @intCast(state.last);
    switch (event.phase) {
        .press => {
            state.press += 1;
            state.held |= mask;
        },
        .release => {
            state.release += 1;
            state.held &= ~mask;
        },
        .repeat => state.repeat += 1,
    }
    dirty = true;
}

fn frame(pixels: *api.Pixels, at: u64) callconv(.c) bool {
    std.debug.assert(at >= last_time);
    last_time = at;
    if (!dirty) return false;
    for (pixels, 0..) |*pixel, i| pixel.* = switch ((i + i / api.width) % 3) {
        0 => 0xf800,
        1 => 0x07e0,
        else => 0x001f,
    };
    pixels[5] = if (options.variant == .changed) 0xBEEF else 0x1234;
    pixels[0] = @truncate(state.press);
    pixels[1] = @truncate(state.release);
    pixels[2] = @truncate(state.repeat);
    pixels[3] = @truncate(state.last);
    pixels[4] = @truncate(state.held);
    dirty = false;
    return true;
}

fn save(out: [*]u8, capacity: usize) callconv(.c) usize {
    if (options.variant == .oversized) return capacity + 1;
    if (capacity < @sizeOf(State)) return 0;
    @memcpy(out[0..@sizeOf(State)], std.mem.asBytes(&state));
    return @sizeOf(State);
}

fn restore(bytes: [*]const u8, length: usize, at: u64) callconv(.c) bool {
    std.debug.assert(at >= last_time);
    last_time = at;
    if (options.variant == .reject or length != @sizeOf(State)) return false;
    @memcpy(std.mem.asBytes(&state), bytes[0..length]);
    dirty = true;
    return true;
}
const interface = api.Api{ .version = if (options.variant == .bad_version) 99 else api.abi_version, .init = init, .input = input, .frame = frame, .save = save, .restore = restore, .deinit = deinit };

fn entry() callconv(.c) *const api.Api {
    return &interface;
}

comptime {
    @export(&entry, .{ .name = if (options.variant == .missing) "missing_entry" else "gain_app_api" });
}

// Test-only lifecycle evidence across dlclose: the host must call cleanup on
// initialized candidates too, including when restore rejects their snapshots.
extern fn getenv([*:0]const u8) ?[*:0]const u8;

extern fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;

extern fn fputc(c_int, *anyopaque) c_int;

extern fn fclose(*anyopaque) c_int;

fn deinit() callconv(.c) void {
    const path = getenv("GAIN_SIM_CLEANUP_LOG") orelse return;
    const file = fopen(path, "ab") orelse return;
    _ = fputc('A' + @as(c_int, @intCast(@backingInt(options.variant))), file);
    _ = fclose(file);
}
