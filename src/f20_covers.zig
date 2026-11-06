//! F20 storage adapter. Prepared artwork is published only after a complete tile.
const std = @import("std");
const art = @import("artwork_tile.zig");
const memory = @import("f20_memory.zig");
const library = @import("f20_library.zig");
const x = @import("x1000.zig");
const diag = @import("f20_diagnostics.zig");
pub const Cache = @import("cover_cache.zig").Cache;

pub const Loader = struct {
    pub const IdleYield = struct { context: *anyopaque, poll: *const fn (*anyopaque) bool };
    cache: Cache = .{},
    file: ?@import("fat32.zig").File = null,
    seeks: @import("file_seek_index.zig").Index = .{},
    unavailable: bool = false,
    work: Cache.WorkQueue = .{},
    idle_yield: ?IdleYield = null,
    active_load: ?struct { id: u64, artwork: u64 } = null,
    load_attempts: u32 = 0,
    read_calls: u32 = 0,
    read_bytes: u32 = 0,
    cancelled_loads: u32 = 0,
    load_ticks_max: u32 = 0,
    prepare_ticks_max: u32 = 0,

    pub fn init() *Loader {
        comptime {
            if (@sizeOf(Loader) > memory.cover_cache.bytes) @compileError("cover cache too large");
        }
        const loader: *Loader = @ptrFromInt(memory.cover_cache.cached());
        loader.reset();
        return loader;
    }

    /// No tile or FAT checkpoint is readable until its metadata is published.
    /// Initialize that metadata explicitly rather than copying unused planes.
    pub fn reset(self: *Loader) void {
        self.cache.reset();
        self.file = null;
        self.seeks.reset();
        self.unavailable = false;
        self.work = .{};
        self.idle_yield = null;
        self.active_load = null;
        self.load_attempts = 0;
        self.read_calls = 0;
        self.read_bytes = 0;
        self.cancelled_loads = 0;
        self.load_ticks_max = 0;
        self.prepare_ticks_max = 0;
    }

    pub fn cancelled(self: *Loader) bool {
        if (self.idle_yield) |hook| if (hook.poll(hook.context)) return true;
        if (self.active_load) |job| {
            const status = x.Interrupts.disableCpu();
            const wanted = self.cache.wants(job.id, job.artwork);
            x.Interrupts.restoreCpu(status);
            if (!wanted) return true;
        }
        return false;
    }

    pub fn service(self: *Loader, volume: *library.Volume) void {
        if (self.active_load != null) return;
        const cache = &self.cache;
        if (!self.work.pending(cache.request_revision.load(.acquire))) return;
        // UI may preempt this task. Snapshot only these small descriptors with
        // CPU interrupts masked; all FAT/card operations run after restoring.
        const status = x.Interrupts.disableCpu();

        const requests = cache.requested;
        const revision = cache.request_revision.load(.monotonic);
        x.Interrupts.restoreCpu(status);
        const job = self.work.next(cache, requests, revision) orelse return;
        const began = x.Timer.now();
        @import("display_trace.zig").record(.cover_load, began, @truncate(job.request.id));
        defer @import("display_trace.zig").record(.cover_loaded, x.Timer.now(), x.Timer.elapsed(began));
        self.load_attempts +|= 1;
        self.active_load = .{ .id = job.request.id, .artwork = Cache.identity(job.request.art) };
        defer {
            self.active_load = null;
            self.load_ticks_max = @max(self.load_ticks_max, x.Timer.elapsed(began));
            diag.report.cover_loads = self.load_attempts;
            diag.report.cover_read_calls = self.read_calls;
            diag.report.cover_read_bytes = self.read_bytes;
            diag.report.cover_cancelled = self.cancelled_loads;
            diag.report.cover_load_max = self.load_ticks_max;
            diag.report.cover_prepare_max = self.prepare_ticks_max;
            diag.report.cover_evictions = self.cache.evictions;
        }
        cache.begin(job);
        const result: Result = self.load(volume, job) catch |failure| if (failure == error.Cancelled) .cancelled else .missing;
        switch (result) {
            .ready => {
                cache.noteLoad(x.Timer.elapsed(began) / x.Timer.milliseconds(1));
                cache.publish(job);
            },
            .missing => cache.publishMissing(job),
            .cancelled => self.cancelled_loads +|= 1,
        }
    }

    const Result = enum { ready, missing, cancelled };

    fn load(self: *Loader, volume: *library.Volume, job: Cache.Load) !Result {
        if (self.unavailable or !std.mem.startsWith(u8, job.request.art.cache_path, "atlas:")) return .missing;
        const slot = try std.fmt.parseInt(u32, job.request.art.cache_path[6..], 10);
        if (self.file == null) {
            const entry = volume.findPath(".gain/artwork.bin") catch {
                self.unavailable = true;
                return .missing;
            };
            self.file = try entry.file();
        }
        var reader = try volume.reader(self.file.?);
        const bytes = memory.scan_io.uncachedSlice(u8)[0 .. 512 + art.pixel_count * 2];
        const offset = 4096 + @as(u64, slot) * bytes.len;
        if (offset > std.math.maxInt(u32) or offset + bytes.len > self.file.?.size) return .missing;
        try self.seeks.seek(&reader, @intCast(offset), @as(u32, volume.sectors_per_cluster) * 512, self);
        var loaded: usize = 0;
        while (loaded < bytes.len) {
            if (self.cancelled()) return .cancelled;
            const count = @min(4096, bytes.len - loaded);
            const read = try reader.read(bytes[loaded..][0..count]);
            self.read_calls +|= 1;
            self.read_bytes +|= @intCast(read);
            if (read != count) return .missing;
            loaded += count;
        }
        var original: art.Tile = .{};
        if (!try @import("cover_cache.zig").decodeTile(bytes, &original, self)) return .cancelled;
        const prepare_began = x.Timer.now();
        const prepared = @import("cover_flow.zig").prepareCooperative(.{ .pixels = &original.pixels, .x = original.x, .y = original.y, .width = original.width, .height = original.height }, &self.cache.tiles[job.slot], self);
        self.prepare_ticks_max = @max(self.prepare_ticks_max, x.Timer.elapsed(prepare_began));
        if (!prepared or self.cancelled()) return .cancelled;
        return .ready;
    }
};

test "native loader resets poisoned bookkeeping and leaves unowned tile storage untouched" {
    const loader = try std.testing.allocator.create(Loader);
    defer std.testing.allocator.destroy(loader);
    @memset(std.mem.asBytes(loader), 0xa5);
    loader.reset();
    try std.testing.expectEqual(null, loader.file);
    try std.testing.expectEqual(null, loader.idle_yield);
    try std.testing.expectEqual(null, loader.active_load);
    try std.testing.expect(!loader.unavailable);
    try std.testing.expect(loader.work.pending(0));
    try std.testing.expectEqual(0, loader.seeks.count);
    try std.testing.expectEqual(0, loader.seeks.source_identity);
    try std.testing.expectEqual(0, loader.cache.ready_mask.load(.acquire));
    try std.testing.expectEqual(0, loader.load_attempts);
    try std.testing.expectEqual(0, loader.read_calls);
    try std.testing.expectEqual(0, loader.read_bytes);
    try std.testing.expectEqual(0, loader.cancelled_loads);
    try std.testing.expectEqual(0, loader.load_ticks_max);
    try std.testing.expectEqual(0, loader.prepare_ticks_max);
}
