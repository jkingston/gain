//! Compile/link qualification only; never installed or executed. Keeps every
//! shared decoder reachable in a freestanding MIPS build, including its C ABI,
//! memory primitives and libm dependencies. Hardware startup is intentionally
//! absent: physical qualification uses the separate RAM benchmark harness.
const gain = @import("gain");
const Frame = gain.pcm_reservoir.StereoFrame;
const memory = gain.memory;
const packet: *[65536 + 64]u8 = @ptrFromInt(memory.compressed_ring.cached());
const page: *[65025]u8 = @ptrFromInt(memory.compressed_ring.cached() + 0x20000);
const floats: *[16384]f32 = @ptrFromInt(memory.compressed_ring.cached() + 0x30000);
const frames: *[8192]Frame = @ptrFromInt(memory.decoded_frames.cached());
const cache: *[65536]u8 = @ptrFromInt(memory.read_ahead.cached());
const compressed: *[256 * 1024]u8 = @ptrFromInt(memory.flac_compressed.cached());
const left: *[65535]i32 = @ptrFromInt(memory.flac_left.cached());
const right: *[65535]i32 = @ptrFromInt(memory.flac_right.cached());
const report: *volatile [3]u32 = @ptrFromInt(0xa0700000);
const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    pub fn seekTo(self: *Reader, target: u32) !void {
        if (target > self.bytes.len) return error.SeekBounds;
        self.position = target;
    }
    pub fn read(self: *Reader, out: []u8) !usize {
        const count = @min(out.len, self.bytes.len - self.position);
        @memcpy(out[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};
const Sink = struct {
    pub fn configure(_: *Sink, info: gain.media_info.Information) !void {
        report[1] = info.sample_rate;
    }
    pub fn push(_: *Sink, input: []const Frame) !void {
        for (input) |frame| report[2] = report[2] +% @as(u32, @bitCast(frame.left)) +% @as(u32, @bitCast(frame.right));
    }
};
export fn _start() callconv(.c) noreturn {
    const length = report[0];
    var reader = Reader{ .bytes = @as([*]const u8, @ptrFromInt(memory.compressed_ring.uncached() + 0x40000))[0..@min(length, 1024 * 1024)] };
    var pool = gain.codec_pool.Pool.init(@as(*align(16) [2 * 1024 * 1024]u8, @ptrFromInt(memory.decoder_arena.cached()))) catch unreachable;
    var sink = Sink{};
    _ = gain.media_decoder.run(&reader, reader.bytes.len, Sink, &sink, .{
        .packet = .{ .packet = packet, .page = page, .pcm = floats, .frames = frames, .pool = &pool },
        .cache = cache,
        .compressed = compressed,
        .left = left,
        .right = right,
    }, 0) catch {};
    while (true) asm volatile ("wait" ::: .{ .memory = true });
}
