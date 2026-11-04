//! F20 storage adapter. Prepared artwork is published only after a complete tile.
const std = @import("std");
const art = @import("artwork_tile.zig");
const memory = @import("f20_memory.zig");
const library = @import("f20_library.zig");
pub const Cache = @import("cover_cache.zig").Cache;

pub const Loader = struct {
    pub const IdleYield = struct { context: *anyopaque, poll: *const fn (*anyopaque) bool };
    cache: Cache = .{},
    file: ?@import("fat32.zig").File = null,
    unavailable: bool = false,
    work: Cache.WorkQueue = .{},
    idle_yield: ?IdleYield = null,

    pub fn init() *Loader {
        comptime {
            if (@sizeOf(Loader) > memory.cover_cache.bytes) @compileError("cover cache too large");
        }
        const loader: *Loader = @ptrFromInt(memory.cover_cache.cached());
        loader.* = .{};
        return loader;
    }

    pub fn cancelled(self: *Loader) bool {
        return if (self.idle_yield) |hook| hook.poll(hook.context) else false;
    }

    pub fn service(self: *Loader, volume: *library.Volume) void {
        const cache = &self.cache;
        if (!self.work.pending(cache.request_revision.load(.acquire))) return;
        // UI may preempt this task. Snapshot only these small descriptors with
        // CPU interrupts masked; all FAT/card operations run after restoring.
        const status = @import("x1000.zig").Interrupts.disableCpu();

        const requests = cache.requested;
        const revision = cache.request_revision.load(.monotonic);
        @import("x1000.zig").Interrupts.restoreCpu(status);
        const job = self.work.next(cache, requests, revision) orelse return;
        cache.begin(job);
        const result = self.load(volume, job) catch .missing;
        switch (result) {
            .ready => cache.publish(job),
            .missing => cache.publishMissing(job),
            .cancelled => {},
        }
    }

    const Result = enum { ready, missing, cancelled };

    fn load(self: *Loader, volume: *library.Volume, job: Cache.Load) !Result {
        if (self.unavailable) return .missing;
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
        try reader.seekTo(@intCast(offset));
        var loaded: usize = 0;
        while (loaded < bytes.len) {
            if (self.cancelled()) return .cancelled;
            const count = @min(4096, bytes.len - loaded);
            if (try reader.read(bytes[loaded..][0..count]) != count) return .missing;
            loaded += count;
        }
        var original: art.Tile = .{};
        if (!try @import("cover_cache.zig").decodeTile(bytes, &original, self)) return .cancelled;
        if (!@import("cover_flow.zig").prepareCooperative(.{ .pixels = &original.pixels, .x = original.x, .y = original.y, .width = original.width, .height = original.height }, &self.cache.tiles[job.slot], self)) return .cancelled;
        return .ready;
    }
};
