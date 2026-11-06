//! Immutable label masks. Drawing copies requests; the storage owner publishes
//! completed slots. No font parser, filesystem or allocator runs in the UI.
const std = @import("std");
const contract = @import("contract.zig");
const fonts = @import("../font_data.zig");
pub const slot_count = 12;
const Phase = enum(u32) { empty, queued, working, ready, failed };
pub const Lookup = union(enum) { ready: *const contract.Label, pending, unavailable: contract.Result, deferred };
const Slot = struct {
    phase: std.atomic.Value(Phase) = .init(.empty),
    used: u32 = 0,
    request: contract.Request = .{},
    // Written completely by prepare before publishing .ready. Leaving masks
    // uninitialised avoids a large ROM/boot-image initializer for empty slots.
    label: contract.Label = undefined,
    result: contract.Result = .ready,
    prefetch: bool = false,
};
pub const Cache = struct {
    slots: [slot_count]Slot = @splat(.{}),
    epoch: u32 = 0,
    locale: contract.Locale = .automatic,
    revision: std.atomic.Value(u32) = .init(0),
    hits: u32 = 0,
    misses: u32 = 0,
    deferred: u32 = 0,
    failure: ?contract.Result = null,

    pub fn reset(self: *Cache) void {
        self.epoch = 0;
        self.locale = .automatic;
        self.revision = .init(0);
        self.hits = 0;
        self.misses = 0;
        self.deferred = 0;
        self.failure = null;
        for (&self.slots) |*slot| {
            slot.used = 0;
            slot.result = .ready;
            slot.prefetch = false;
            slot.phase = .init(.empty);
        }
    }

    pub fn beginFrame(self: *Cache) void {
        self.epoch +%= 1;
    }

    /// The returned mask is borrowed for the immediate draw call. Do not
    /// retain its pointer across frames or subsequent cache lookups.
    pub fn lookup(self: *Cache, value: []const u8, role: fonts.Role, width: u16, ellipsis: bool) ?*const contract.Label {
        return switch (self.lookupState(value, role, width, ellipsis)) {
            .ready => |label| label,
            else => null,
        };
    }

    pub fn lookupState(self: *Cache, value: []const u8, role: fonts.Role, width: u16, ellipsis: bool) Lookup {
        if (value.len > contract.max_text_bytes or width == 0) return .{ .unavailable = .invalid_text };
        const bounded = @min(width, contract.max_width);
        var oldest: ?*Slot = null;
        var vacancy: ?*Slot = null;
        for (&self.slots) |*slot| {
            const phase = slot.phase.load(.acquire);
            if (phase != .empty and slot.request.length == value.len and slot.request.role == role and
                slot.request.width == bounded and slot.request.locale == self.locale and
                slot.request.ellipsis == @intFromBool(ellipsis) and std.mem.eql(u8, slot.request.value(), value))
            {
                slot.used = self.epoch;
                slot.prefetch = false;
                if (phase == .ready) {
                    self.hits +%= 1;
                    return .{ .ready = &slot.label };
                }
                return if (phase == .failed) .{ .unavailable = slot.result } else .pending;
            }
            if (phase == .empty) {
                if (vacancy == null) vacancy = slot;
                continue;
            }
            if (phase == .working) continue;
            // Never replace a label used by this or the preceding frame. The
            // old screen remains resident while a transition draws both ends.
            if (self.epoch -% slot.used <= 1) continue;
            if (oldest == null or self.epoch -% slot.used > self.epoch -% oldest.?.used) oldest = slot;
        }
        if (self.failure) |result| return .{ .unavailable = result };
        self.misses +%= 1;
        const slot = vacancy orelse oldest orelse {
            self.deferred +%= 1;
            return .deferred;
        };
        slot.phase.store(.empty, .release);
        slot.request = contract.Request.init(value, role, bounded, self.locale, ellipsis) catch return .{ .unavailable = .invalid_text };
        slot.used = self.epoch;
        slot.prefetch = false;
        slot.phase.store(.queued, .release);
        return .pending;
    }

    /// One speculative label may occupy a vacant slot, never evict visible
    /// demand or pin a prior viewport. Caller excludes concurrent UI requests.
    pub fn prefetch(self: *Cache, value: []const u8, role: fonts.Role, width: u16, ellipsis: bool) bool {
        if (self.failure != null or value.len > contract.max_text_bytes or width == 0) return false;
        const bounded = @min(width, contract.max_width);
        var vacancy: ?*Slot = null;
        for (&self.slots) |*slot| {
            const phase = slot.phase.load(.acquire);
            if (phase == .empty) {
                if (vacancy == null) vacancy = slot;
            } else if (slot.request.length == value.len and slot.request.role == role and slot.request.width == bounded and
                slot.request.locale == self.locale and slot.request.ellipsis == @intFromBool(ellipsis) and std.mem.eql(u8, slot.request.value(), value)) return true;
        }
        const slot = vacancy orelse return false;
        slot.request = contract.Request.init(value, role, bounded, self.locale, ellipsis) catch return false;
        slot.used = self.epoch -% 2;
        slot.prefetch = true;
        slot.phase.store(.queued, .release);
        return true;
    }

    /// A missing/corrupt engine cannot service queued work. Publish a terminal
    /// outcome rather than leaving the UI in a permanent loading state.
    pub fn unavailable(self: *Cache, result: contract.Result) void {
        std.debug.assert(result != .ready and result != .cancelled);
        self.failure = result;
        for (&self.slots) |*slot| if (slot.phase.load(.acquire) == .queued) {
            slot.result = result;
            slot.phase.store(.failed, .release);
        };
        _ = self.revision.fetchAdd(1, .release);
    }

    pub fn pending(self: *const Cache) bool {
        for (&self.slots) |*slot| {
            const phase = slot.phase.load(.acquire);
            if (phase == .queued or phase == .working) return true;
        }
        return false;
    }

    /// Called while the adapter excludes UI callbacks/preemption. Heavy work
    /// happens after leaving that critical section; working slots cannot evict.
    /// Prefer the most recently requested label. An older queued label remains
    /// reusable: frame age cannot identify abandonment of a retained UI band.
    pub fn claim(self: *Cache) ?usize {
        var newest: ?usize = null;
        var newest_age: u32 = std.math.maxInt(u32);
        var speculative = true;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.phase.load(.acquire) != .queued) continue;
            const age = self.epoch -% slot.used;
            if (newest == null or (speculative and !slot.prefetch) or (speculative == slot.prefetch and age < newest_age)) {
                newest = i;
                newest_age = age;
                speculative = slot.prefetch;
            }
        }
        const index = newest orelse return null;
        self.slots[index].phase.store(.working, .release);
        return index;
    }

    pub fn request(self: *const Cache, slot: usize) *const contract.Request {
        return &self.slots[slot].request;
    }

    pub fn destination(self: *Cache, slot: usize) *contract.Label {
        return &self.slots[slot].label;
    }

    pub fn publish(self: *Cache, index: usize, result: contract.Result) void {
        const slot = &self.slots[index];
        std.debug.assert(slot.phase.load(.monotonic) == .working);
        const outcome = if (result == .ready and (slot.label.width > slot.request.width or slot.label.width > contract.max_width or slot.label.height > contract.max_height)) contract.Result.invalid_pack else result;
        slot.result = outcome;
        slot.phase.store(if (outcome == .ready) .ready else if (outcome == .cancelled) .queued else .failed, .release);
        _ = self.revision.fetchAdd(1, .release);
    }
};

/// Retain the embedded atlas for simple labels, recovery and missing packs.
/// Marks/joiners/complex scripts always use the full engine as one label.
pub fn needsEngine(value: []const u8) bool {
    const printable_ascii = for (value) |byte| {
        if (byte < 32 or byte >= 127) break false;
    } else true;
    if (printable_ascii) return false;
    var it = (std.unicode.Utf8View.init(value) catch return true).iterator();
    while (it.nextCodepoint()) |cp| {
        if ((cp >= 0x300 and cp <= 0x36f) or cp > 0x24f) return true;
        if (fonts.glyph(.body, cp).code != cp) return true;
    }
    return false;
}

pub const WarmupPriority = enum { embedded, shaping, fallback };

/// Prefer metadata that needs a fallback face over typography already present
/// in the embedded atlas. This is scheduling only; shaping policy is unchanged.
pub fn warmupPriority(value: []const u8) WarmupPriority {
    if (!needsEngine(value)) return .embedded;
    var iterator = (std.unicode.Utf8View.init(value) catch return .fallback).iterator();
    while (iterator.nextCodepoint()) |cp| if (fonts.glyph(.body, cp).code != cp) return .fallback;
    return .shaping;
}

test "warmup prioritises actual missing atlas glyphs over supported typographic punctuation" {
    try std.testing.expectEqual(WarmupPriority.embedded, warmupPriority("Café"));
    try std.testing.expectEqual(WarmupPriority.shaping, warmupPriority("Artist’s album"));
    for ([_][]const u8{ "日本語", "العربية", "\xff" }) |value| try std.testing.expectEqual(WarmupPriority.fallback, warmupPriority(value));
    // Empty/ASCII labels never start the optional font engine.
    try std.testing.expectEqual(WarmupPriority.embedded, warmupPriority(""));
    try std.testing.expectEqual(WarmupPriority.embedded, warmupPriority("Synthetic album"));
}

test "working labels survive eviction, copied metadata and publication" {
    var cache: Cache = .{};
    cache.beginFrame();
    var original = [_]u8{ 0xe6, 0x97, 0xa5 };
    try std.testing.expect(cache.lookup(&original, .body, 100, true) == null);
    const slot = cache.claim().?;
    original = @splat('x');
    try std.testing.expectEqualStrings("日", cache.request(slot).value());
    for (0..30) |_| {
        cache.beginFrame();
        _ = cache.lookup("Different", .body, 120, true);
    }
    try std.testing.expectEqualStrings("日", cache.request(slot).value());
    cache.destination(slot).width = 17;
    cache.publish(slot, .ready);
    try std.testing.expectEqual(@as(u16, 17), cache.lookup("日", .body, 100, true).?.width);
    try std.testing.expect(cache.lookup("日", .title, 100, true) == null);
    try std.testing.expect(cache.lookup("日", .body, 90, true) == null);
    cache.locale = .japanese;
    try std.testing.expect(cache.lookup("日", .body, 100, true) == null);
}

test "bounded text and shaped-script detection" {
    try std.testing.expect(!needsEngine("Café 123"));
    for ([_][]const u8{ "á", "العربية", "日本語", "עברית", "👩‍🎤" }) |value| try std.testing.expect(needsEngine(value));
    try std.testing.expectError(error.InvalidText, contract.Request.init("\xff", .body, 100, .automatic, true));
    var oversized: [contract.max_text_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.InvalidText, contract.Request.init(&oversized, .body, 100, .automatic, true));
}

test "cancelled jobs resume and invalid masks never enter the render cache" {
    var cache: Cache = undefined;
    cache.reset();
    cache.beginFrame();
    _ = cache.lookup("العربية", .body, 100, true);
    const first = cache.claim().?;
    cache.publish(first, .cancelled);
    try std.testing.expect(cache.pending());
    const resumed = cache.claim().?;
    try std.testing.expectEqual(first, resumed);
    cache.destination(resumed).* = .{ .width = 101, .height = 21 };
    cache.publish(resumed, .ready);
    try std.testing.expect(!cache.pending());
    try std.testing.expect(cache.lookup("العربية", .body, 100, true) == null);
    cache.reset();
    try std.testing.expect(!cache.pending());
}

test "newest caption is prepared before old queued history" {
    var cache: Cache = .{};
    for (0..8) |i| {
        var text: [64]u8 = undefined;
        cache.beginFrame();
        const value = try std.fmt.bufPrint(&text, "日本語のアルバム {d}", .{i});
        _ = cache.lookup(value, .reading, 288, true);
    }
    const newest = cache.claim().?;
    try std.testing.expectEqualStrings("日本語のアルバム 7", cache.request(newest).value());
    cache.destination(newest).* = .{ .width = 17, .height = 21 };
    cache.publish(newest, .ready);
    // Old labels remain useful on a return journey; prioritisation does not
    // turn them into failures or discard their requests.
    try std.testing.expect(cache.claim() != null);
    try std.testing.expect(cache.lookup("日本語のアルバム 7", .reading, 288, true) != null);
}

test "retained pending captions survive cover-only frames and epoch wrap" {
    var cache: Cache = .{};
    cache.epoch = std.math.maxInt(u32) - 1;
    for (0..3) |i| {
        var text: [64]u8 = undefined;
        cache.beginFrame();
        const value = try std.fmt.bufPrint(&text, "日本語のアルバム {d}", .{i});
        _ = cache.lookup(value, .reading, 288, true);
    }
    const working = cache.claim().?;
    try std.testing.expectEqualStrings("日本語のアルバム 2", cache.request(working).value());
    // The retained caption band makes no further lookups during cover motion.
    // Its frame age is not a valid cancellation or expiration signal.
    for (0..90) |_| cache.beginFrame();
    cache.publish(working, .cancelled);
    const resumed = cache.claim().?;
    try std.testing.expectEqual(working, resumed);
    cache.destination(resumed).* = .{ .width = 17, .height = 21 };
    cache.publish(resumed, .ready);
    try std.testing.expect(cache.lookup("日本語のアルバム 2", .reading, 288, true) != null);
}

test "cold pending cancellation failure and warm labels remain distinct without fabricated readiness" {
    var cache: Cache = undefined;
    cache.reset();
    cache.beginFrame();
    try std.testing.expectEqual(Lookup.pending, cache.lookupState("日本語", .body, 180, true));
    const slot = cache.claim().?;
    try std.testing.expectEqual(Lookup.pending, cache.lookupState("日本語", .body, 180, true));
    cache.publish(slot, .cancelled);
    try std.testing.expectEqual(Lookup.pending, cache.lookupState("日本語", .body, 180, true));
    const retry = cache.claim().?;
    cache.destination(retry).* = .{ .width = 25, .height = 21 };
    cache.publish(retry, .ready);
    try std.testing.expect(cache.lookupState("日本語", .body, 180, true) == .ready);
    const revision = cache.revision.load(.acquire);
    for (0..100) |_| try std.testing.expect(cache.lookupState("日本語", .body, 180, true) == .ready);
    try std.testing.expectEqual(revision, cache.revision.load(.acquire));
    _ = cache.lookupState("עברית", .body, 180, true);
    cache.unavailable(.io_error);
    try std.testing.expect(!cache.pending());
    try std.testing.expectEqual(Lookup{ .unavailable = .io_error }, cache.lookupState("עברית", .body, 180, true));
    try std.testing.expectEqual(Lookup{ .unavailable = .io_error }, cache.lookupState("العربية", .body, 180, true));
    try std.testing.expect(cache.lookupState("日本語", .body, 180, true) == .ready);
    cache.reset();
    try std.testing.expectEqual(Lookup.pending, cache.lookupState("日本語", .body, 180, true));
}

test "one speculative label copies source and yields to visible demand without eviction" {
    var cache: Cache = undefined;
    cache.reset();
    cache.beginFrame();
    var source = [_]u8{ 0xe6, 0x97, 0xa5 };
    try std.testing.expect(cache.prefetch(&source, .reading, 288, true));
    source = @splat('x');
    _ = cache.lookupState("かな", .reading, 288, true);
    const visible = cache.claim().?;
    try std.testing.expectEqualStrings("かな", cache.request(visible).value());
    cache.destination(visible).* = .{ .width = 25, .height = 24 };
    cache.publish(visible, .ready);
    const speculative = cache.claim().?;
    try std.testing.expectEqualStrings("日", cache.request(speculative).value());
    cache.publish(speculative, .cancelled);
    // A real lookup promotes this same copied request, without a duplicate.
    _ = cache.lookupState("日", .reading, 288, true);
    const promoted = cache.claim().?;
    try std.testing.expectEqual(speculative, promoted);
    cache.destination(promoted).* = .{ .width = 16, .height = 24 };
    cache.publish(promoted, .ready);
    cache.reset();
    cache.beginFrame();
    for (0..slot_count) |i| {
        var buffer: [32]u8 = undefined;
        _ = cache.lookupState(try std.fmt.bufPrint(&buffer, "日本語 {d}", .{i}), .body, 288, true);
    }
    try std.testing.expect(!cache.prefetch("かな", .reading, 288, true));
    var claimed: usize = 0;
    while (cache.claim()) |slot| {
        try std.testing.expect(!cache.slots[slot].prefetch);
        cache.destination(slot).* = .{ .width = 16, .height = 21 };
        cache.publish(slot, .ready);
        claimed += 1;
    }
    try std.testing.expectEqual(slot_count, claimed);
}
