//! Read-only desktop cover worker, using production decoding and cache policy.
//! File reads and image preparation happen outside the application's UI lock.
const std = @import("std");
const gain = @import("gain_ui");
const Cache = gain.cover_cache.Cache;

pub const Loader = struct {
    root: ?std.Io.Dir = null,
    io: std.Io = undefined,
    cache: *Cache = undefined,
    stop: *std.atomic.Value(bool) = undefined,
    acquire: *const fn () void = undefined,
    release: *const fn () void = undefined,
    thread: ?std.Thread = null,
    work: Cache.WorkQueue = .{},
    loads: u32 = 0,

    const Workspace = struct {
        sums: [gain.artwork.sum_words]u32 = undefined,
        scratch: [2 * 1024 * 1024]u8 = undefined,
        input: [64 * 1024]u8 = undefined,
        tile: gain.artwork.Tile = .{},
        prepared: gain.cover_flow.Prepared = .{},
    };

    pub fn start(self: *Loader, root_path: ?[]const u8, io: std.Io, cache: *Cache, stop: *std.atomic.Value(bool), acquire: *const fn () void, release: *const fn () void) void {
        self.* = .{ .io = io, .cache = cache, .stop = stop, .acquire = acquire, .release = release };
        const path = root_path orelse return;
        self.root = std.Io.Dir.cwd().openDir(io, path, .{}) catch return;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.root.?.close(io);
            self.root = null;
            return;
        };
    }

    pub fn close(self: *Loader) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.root) |root| root.close(self.io);
        self.root = null;
    }

    pub fn cancelled(self: *Loader) bool {
        return self.stop.load(.acquire);
    }

    const Reader = struct {
        file: std.Io.File,
        loader: *Loader,
        at: u64 = 0,
        pub fn seekTo(self: *Reader, at: u32) !void {
            self.at = at;
        }
        pub fn read(self: *Reader, bytes: []u8) !usize {
            if (self.loader.cancelled()) return error.Cancelled;
            const count = try self.file.readPositionalAll(self.loader.io, bytes, self.at);
            self.at += count;
            return count;
        }
    };

    fn decode(self: *Loader, job: Cache.Load, workspace: *Workspace) !void {
        const art = job.request.art;
        if (!std.mem.eql(u8, art.cache_path, "image") and !std.mem.eql(u8, art.cache_path, "embedded")) return error.UnsupportedArtwork;
        const file = try self.root.?.openFile(self.io, art.source, .{});
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.size > std.math.maxInt(u32)) return error.ArtworkLimit;
        var reader = Reader{ .file = file, .loader = self };
        var source = try gain.media_source.Source(Reader).init(&reader, stat.size, &workspace.input);
        const range = if (std.mem.eql(u8, art.cache_path, "embedded")) (try gain.library_metadata.embeddedPicture(&source) orelse return error.MissingArtwork) else gain.library_metadata.PictureRange{ .offset = 0, .length = @intCast(stat.size) };
        if (range.length > 16 * 1024 * 1024) return error.ArtworkLimit;
        try gain.artwork.decode(&source, range.offset, range.length, &workspace.sums, &workspace.scratch, &workspace.tile, self);
        const after = try file.stat(self.io);
        if (after.size != art.stamp.size or after.mtime.nanoseconds != art.stamp.modified) return error.ChangedDuringScan;
        if (!gain.cover_flow.prepareCooperative(.{ .pixels = &workspace.tile.pixels, .x = workspace.tile.x, .y = workspace.tile.y, .width = workspace.tile.width, .height = workspace.tile.height }, &workspace.prepared, self)) return error.Cancelled;
    }

    fn run(self: *Loader) void {
        const workspace = std.heap.c_allocator.create(Workspace) catch return;
        defer std.heap.c_allocator.destroy(workspace);
        while (!self.cancelled()) {
            var path: [4096]u8 = undefined;
            var key: [256]u8 = undefined;
            var locator: [128]u8 = undefined;
            self.acquire();
            const proposed = self.work.next(self.cache, self.cache.requested, self.cache.request_revision.load(.acquire));
            if (proposed == null) {
                self.release();
                std.Io.sleep(self.io, .fromMilliseconds(4), .awake) catch {};
                continue;
            }
            var job = proposed.?;
            const art = &job.request.art;
            if (art.source.len > path.len or art.key.len > key.len or art.cache_path.len > locator.len) {
                self.cache.begin(job);
                self.cache.publishMissing(job);
                self.release();
                continue;
            }
            @memcpy(path[0..art.source.len], art.source);
            @memcpy(key[0..art.key.len], art.key);
            @memcpy(locator[0..art.cache_path.len], art.cache_path);
            art.source = path[0..art.source.len];
            art.key = key[0..art.key.len];
            art.cache_path = locator[0..art.cache_path.len];
            self.cache.begin(job);
            self.release();
            const valid = if (self.decode(job, workspace)) |_| true else |_| false;
            self.acquire();
            self.loads +%= 1;
            if (self.cache.wants(job.request.id, Cache.identity(job.request.art))) {
                if (valid) {
                    self.cache.tiles[job.slot] = workspace.prepared;
                    self.cache.publish(job);
                } else if (!self.cancelled()) self.cache.publishMissing(job);
            }
            self.release();
        }
    }
};
