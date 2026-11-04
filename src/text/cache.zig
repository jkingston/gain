//! Immutable label masks. Drawing copies requests; the storage owner publishes
//! completed slots. No font parser, filesystem or allocator runs in the UI.
const std = @import("std");
const contract = @import("contract.zig");
const fonts = @import("../font_data.zig");
pub const slot_count = 12;
const Phase = enum(u32) { empty, queued, working, ready, failed };
const Slot = struct {
    phase: std.atomic.Value(Phase) = .init(.empty),
    used: u32 = 0,
    request: contract.Request = .{},
    // Written completely by prepare before publishing .ready. Leaving masks
    // uninitialised avoids a large ROM/boot-image initializer for empty slots.
    label: contract.Label = undefined,
    result: contract.Result = .ready,
};
pub const Cache = struct {
    slots: [slot_count]Slot = @splat(.{}),
    epoch: u32 = 0,
    locale: contract.Locale = .automatic,
    revision: std.atomic.Value(u32) = .init(0),
    hits: u32 = 0,
    misses: u32 = 0,
    deferred: u32 = 0,

    pub fn reset(self: *Cache) void {
        self.epoch = 0;
        self.locale = .automatic;
        self.revision = .init(0);
        self.hits = 0;
        self.misses = 0;
        self.deferred = 0;
        for (&self.slots) |*slot| {
            slot.used = 0;
            slot.result = .ready;
            slot.phase = .init(.empty);
        }
    }

    pub fn beginFrame(self: *Cache) void {
        self.epoch +%= 1;
    }

    /// The returned mask is borrowed for the immediate draw call. Do not
    /// retain its pointer across frames or subsequent cache lookups.
    pub fn lookup(self: *Cache, value: []const u8, role: fonts.Role, width: u16, ellipsis: bool) ?*const contract.Label {
        if (value.len > contract.max_text_bytes or width == 0) return null;
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
                if (phase == .ready) {
                    self.hits +%= 1;
                    return &slot.label;
                }
                return null;
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
        self.misses +%= 1;
        const slot = vacancy orelse oldest orelse {
            self.deferred +%= 1;
            return null;
        };
        slot.phase.store(.empty, .release);
        slot.request = contract.Request.init(value, role, bounded, self.locale, ellipsis) catch return null;
        slot.used = self.epoch;
        slot.phase.store(.queued, .release);
        return null;
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
    pub fn claim(self: *Cache) ?usize {
        for (&self.slots, 0..) |*slot, i| {
            if (slot.phase.load(.acquire) == .queued) {
                slot.phase.store(.working, .release);
                return i;
            }
        }
        return null;
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
