//! Sole-storage-owner adapter for the optional SD text engine. Draw callbacks
//! only touch Cache; worker I/O always yields to audio, control and watchdogs.
const std = @import("std");
const abi = @import("text/contract.zig");
const component = @import("text/component.zig");
const memory = @import("f20_memory.zig");
const library = @import("f20_library.zig");
const fat = @import("filesystem.zig");
const x = @import("x1000.zig");
const worker_service = @import("text/worker_service.zig");
// The code and bounded heaps have independent RAM reservations. Shutdown
// releases faces; initialize resets source-bound manifest/pages on every mount.
var resident: ?struct { identity: component.Identity, api: *const abi.Api } = null;
pub const Loader = struct {
    cache: @import("text/cache.zig").Cache = .{},
    volume: *library.Volume,
    file: ?fat.File = null,
    api: ?*const abi.Api = null,
    busy: bool = false,
    initialized: bool = false,
    warmup_requested: bool = false,
    warmup_label_requested: bool = false,
    last_result: abi.Result = .invalid_pack,
    prepared: u32 = 0,
    worst_ticks: u32 = 0,
    source_bytes: u64 = 0,
    statistics: abi.Statistics = .{},
    io: [4096]u8 align(32) = undefined,
    seeks: @import("file_seek_index.zig").Index = .{},
    yield: ?worker_service.Yield = null,
    storage_work: worker_service.StoragePump = .{},

    pub fn init(volume: *library.Volume) *Loader {
        comptime {
            if (@sizeOf(Loader) > memory.text_cache.bytes) @compileError("text cache exceeds its RAM reservation");
            if (memory.text_code.cached() != component.code_address or memory.text_code.bytes != component.code_capacity or
                memory.text_workspace.cached() != component.work_address or memory.text_workspace.bytes != component.work_capacity) @compileError("text component address mismatch");
        }
        const self: *Loader = @ptrFromInt(memory.text_cache.cached());
        self.cache.reset();
        self.volume = volume;
        self.file = null;
        self.api = null;
        self.busy = false;
        self.initialized = false;
        self.warmup_requested = false;
        self.warmup_label_requested = false;
        self.last_result = .invalid_pack;
        self.prepared = 0;
        self.worst_ticks = 0;
        self.source_bytes = 0;
        self.statistics = .{};
        self.yield = null;
        self.storage_work = .{};
        self.seeks.reset();
        return self;
    }

    fn poll(context: *anyopaque) callconv(.c) bool {
        const self: *Loader = @ptrCast(@alignCast(context));
        x.Watchdog.kick();
        return worker_service.poll(self.yield, &self.storage_work);
    }

    fn read(context: *anyopaque, at: u32, output: [*]u8, count: u32) callconv(.c) u32 {
        const self: *Loader = @ptrCast(@alignCast(context));
        return self.readFile(self.file orelse return 0, at, output[0..count]) catch 0;
    }

    fn readFile(self: *Loader, file: fat.File, at: u32, output: []u8) !u32 {
        var reader = try self.volume.reader(file);
        if (self.file != null and file.first_cluster == self.file.?.first_cluster and file.size == self.file.?.size) {
            const Observer = struct {
                loader: *Loader,
                pub fn cancelled(observer: @This()) bool {
                    return Loader.poll(observer.loader);
                }
            };
            try self.seeks.seek(&reader, at, @as(u32, self.volume.sectors_per_cluster) * 512, Observer{ .loader = self });
        } else try reader.seekTo(at);
        var copied: usize = 0;
        const bounce = @as(*[4096]u8, @ptrFromInt((@intFromPtr(&self.io) & 0x1fffffff) | 0xa0000000));
        while (copied < output.len) {
            if (poll(self)) return error.Cancelled;
            const n = @min(bounce.len, output.len - copied);
            const got = try reader.read(bounce[0..n]);
            if (got == 0) break;
            @memcpy(output[copied..][0..got], bounce[0..got]);
            copied += got;
        }
        self.source_bytes += copied;
        return @intCast(copied);
    }

    fn load(self: *Loader) !void {
        const entry = try self.volume.findPath(".gain/fonts/engine.bin");
        const file = try entry.file();
        var bytes: [component.header_bytes]u8 = undefined;
        if (try self.readFile(file, 0, &bytes) != bytes.len) return error.InvalidComponent;
        const header = try component.Header.decode(&bytes, file.size);
        const identity = component.Identity{ .source = self.volume.serial, .cluster = file.first_cluster, .modified = entry.modified, .bytes = file.size, .payload = header };
        const api = if (resident) |old| if (old.identity.same(identity)) old.api else try self.loadComponent(file, header, identity) else try self.loadComponent(file, header, identity);
        self.file = try (try self.volume.findPath(".gain/fonts/fonts.bin")).file();
        const source = abi.Source{ .context = self, .bytes = self.file.?.size, .read = read, .poll = poll };
        const workspace = abi.Workspace{
            .primary = @alignCast(memory.text_heap.cachedSlice(u8).ptr),
            .primary_bytes = memory.text_heap.bytes,
            .auxiliary = @alignCast(memory.text_aux_heap.cachedSlice(u8).ptr),
            .auxiliary_bytes = memory.text_aux_heap.bytes,
        };
        self.last_result = api.initialize(&source, &workspace);
        if (self.last_result == .cancelled) return error.Cancelled;
        if (self.last_result != .ready) return error.InvalidPack;
        self.api = api;
    }

    fn loadComponent(self: *Loader, file: fat.File, header: component.Header, identity: component.Identity) !*const abi.Api {
        resident = null;
        const code = memory.text_code.cachedSlice(u8);
        const work = memory.text_workspace.cachedSlice(u8);
        var cleared: usize = 0;
        while (cleared < work.len) {
            if (poll(self)) return error.Cancelled;
            const count = @min(4096, work.len - cleared);
            @memset(work[cleared..][0..count], 0);
            cleared += count;
        }
        if (try self.readFile(file, component.header_bytes, code[0..header.bytes]) != header.bytes or !header.validate(code[0..header.bytes])) return error.InvalidComponent;
        // Publish cached writes to instruction fetch. X1000 cache lines are
        // 32 bytes; hit operations affect only this component's reservation.
        var at = memory.text_code.cached();
        while (at < memory.text_code.cached() + header.bytes) : (at += 32) {
            asm volatile ("cache 0x15, 0(%[at])"
                :
                : [at] "r" (at),
                : .{ .memory = true });
        }
        x.memoryBarrier();
        at = memory.text_code.cached();
        while (at < memory.text_code.cached() + header.bytes) : (at += 32) {
            asm volatile ("cache 0x10, 0(%[at])"
                :
                : [at] "r" (at),
                : .{ .memory = true });
        }
        asm volatile ("ehb" ::: .{ .memory = true });
        const entry: *const fn () callconv(.c) *const abi.Api = @ptrFromInt(component.code_address);
        const api = entry();
        const address = @intFromPtr(api);
        if (address < memory.text_code.cached() or address + @sizeOf(abi.Api) > memory.text_code.cachedTop() or api.version != abi.version) return error.InvalidComponent;
        inline for (.{ api.initialize, api.prepare, api.shutdown, api.statistics }) |function| {
            const fn_address = @intFromPtr(function);
            if (fn_address < memory.text_code.cached() or fn_address >= memory.text_code.cachedTop()) return error.InvalidComponent;
        }
        resident = .{ .identity = identity, .api = api };
        return api;
    }

    /// Queue-only: call after the first frame when the library needs Unicode.
    /// Existing sole-owner service performs all work cooperatively.
    pub fn requestWarmup(self: *Loader) void {
        self.warmup_requested = true;
    }

    /// Copy one actual library label to prime its script's font tables. A
    /// vacant cache slot only; visible work always wins and can evict it.
    pub fn requestWarmupLabel(self: *Loader, value: []const u8, role: abi.Role, width: u16) void {
        if (self.warmup_label_requested) return;
        self.warmup_label_requested = true;
        self.requestWarmup();
        const status = x.Interrupts.disableCpu();
        defer x.Interrupts.restoreCpu(status);
        _ = self.cache.prefetch(value, role, width, true);
    }

    pub fn serviceWithYield(self: *Loader, hook: worker_service.Yield) void {
        worker_service.withYield(self, hook, Loader.service);
    }

    pub fn service(self: *Loader) void {
        if (self.busy) return;
        self.busy = true;
        defer self.busy = false;
        defer {
            const masks = x.Interrupts.disableCpu();
            defer x.Interrupts.restoreCpu(masks);
            const health = &@import("health.zig").snapshot;
            health.text_initialized = @intFromBool(self.initialized);
            health.text_loaded = @intFromBool(self.api != null);
            health.text_result = @backingInt(self.last_result);
            health.text_prepared = self.prepared;
            health.text_worst_ticks = self.worst_ticks;
            health.text_bytes_low = @truncate(self.source_bytes);
            health.text_bytes_high = @truncate(self.source_bytes >> 32);
            health.text_heap_peak = self.statistics.heap_peak;
            health.text_heap_failures = self.statistics.heap_failures;
            health.text_page_reads = self.statistics.page_reads;
            health.text_page_hits = self.statistics.page_hits;
            health.text_labels = self.statistics.labels;
            health.text_glyphs = self.statistics.glyphs;
        }
        if (!self.initialized) {
            // Visible demand or an explicit background warmup starts loading.
            if (!self.warmup_requested and !self.cache.pending()) return;
            const bytes_before = self.source_bytes;
            @import("display_trace.zig").record(.text_load, x.Timer.now(), 0);
            defer @import("display_trace.zig").record(.text_loaded, x.Timer.now(), @truncate(self.source_bytes - bytes_before));
            self.load() catch |failure| {
                self.initialized = failure != error.Cancelled;
                if (self.initialized) {
                    if (failure != error.InvalidPack) self.last_result = if (failure == error.InvalidComponent) .invalid_pack else .io_error;
                    const masks = x.Interrupts.disableCpu();
                    self.cache.unavailable(self.last_result);
                    x.Interrupts.restoreCpu(masks);
                }
                return;
            };
            self.initialized = true;
        }
        const api = self.api orelse return;
        const status = x.Interrupts.disableCpu();
        const job = self.cache.claim();
        x.Interrupts.restoreCpu(status);
        const slot = job orelse return;
        const began = x.Timer.now();
        const bytes_before = self.source_bytes;
        @import("display_trace.zig").record(.text_prepare, began, @backingInt(self.cache.request(slot).role));
        self.last_result = api.prepare(self.cache.request(slot), self.cache.destination(slot));
        @import("display_trace.zig").record(.text_prepared, x.Timer.now(), @truncate(self.source_bytes - bytes_before));
        self.worst_ticks = @max(self.worst_ticks, x.Timer.elapsed(began));
        self.prepared +%= 1;
        self.cache.publish(slot, self.last_result);
        api.statistics(&self.statistics);
    }

    pub fn deinit(self: *Loader) void {
        self.storage_work.hook = null;
        self.yield = null;
        if (self.api) |api| api.shutdown();
        self.api = null;
    }
};
