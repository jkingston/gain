//! Bounded occurrence-aware play order. Track identity is distinct from a
//! queue occurrence so repeated songs remain independently selectable/editable.
const std = @import("std");

pub const Repeat = enum { off, all, one };
pub const Shuffle = enum { off, songs, albums };
pub const Occurrence = u32;
/// Prepared by the sole storage writer before its short admission critical
/// section. Queue edits invalidate it; natural audible-front retirement does not.
pub const Admission = struct {
    occurrence: Occurrence,
    position: usize,
    membership_revision: u32,
    generation: u32,
};

const no_slot = std.math.maxInt(u16);

/// Caller storage contains four packed columns: 8N bytes of track IDs, 4N of
/// occurrence tokens, then two 2N permutations. Byte access imposes no alignment
/// requirement and avoids native struct padding in the fixed RAM reservation.
pub const Queue = struct {
    bytes: []u8,
    count: usize = 0,
    free_head: u16 = no_slot,
    cursor: usize = 0,
    shuffled: bool = false,
    shuffle_kind: Shuffle = .off,
    repeat: Repeat = .off,
    pinned_next: usize = 0,
    committed: [64]Occurrence = @splat(0),
    committed_count: usize = 0,
    admission_generation: u32 = 0,
    next_occurrence: Occurrence = 1,
    revision: u32 = 0,
    membership_revision: u32 = 0,

    pub fn init(bytes: []u8) Queue {
        var queue = Queue{ .bytes = bytes };
        queue.resetSlots();
        return queue;
    }

    /// Free slots reuse their otherwise unused token words as a free list.
    /// Capturing an 8192-song queue is linear, rather than rescanning occupied
    /// slots for every append. Live occurrence tokens remain monotonic.
    fn resetSlots(self: *Queue) void {
        @memset(self.bytes, 0);
        self.free_head = if (self.capacity() == 0) no_slot else 0;
        for (0..self.capacity()) |slot| self.setToken(slot, if (slot + 1 == self.capacity()) no_slot else @intCast(slot + 1));
    }

    pub fn capacity(self: Queue) usize {
        return @min(8192, self.bytes.len / 16);
    }

    fn track(self: Queue, slot: usize) u64 {
        return std.mem.readInt(u64, self.bytes[slot * 8 ..][0..8], .little);
    }

    fn setTrack(self: *Queue, slot: usize, id: u64) void {
        std.mem.writeInt(u64, self.bytes[slot * 8 ..][0..8], id, .little);
    }

    fn token(self: Queue, slot: usize) Occurrence {
        return std.mem.readInt(u32, self.bytes[self.capacity() * 8 + slot * 4 ..][0..4], .little);
    }

    fn setToken(self: *Queue, slot: usize, value: Occurrence) void {
        std.mem.writeInt(u32, self.bytes[self.capacity() * 8 + slot * 4 ..][0..4], value, .little);
    }

    fn index(self: Queue, position: usize, shuffled: bool) u16 {
        return std.mem.readInt(u16, self.bytes[self.capacity() * (if (shuffled) @as(usize, 14) else 12) + position * 2 ..][0..2], .little);
    }

    fn setIndex(self: *Queue, position: usize, shuffled: bool, slot: u16) void {
        std.mem.writeInt(u16, self.bytes[self.capacity() * (if (shuffled) @as(usize, 14) else 12) + position * 2 ..][0..2], slot, .little);
    }

    fn rank(self: Queue, slot: u16, shuffled: bool) ?usize {
        for (0..self.count) |i| if (self.index(i, shuffled) == slot) return i;
        return null;
    }

    pub fn clear(self: *Queue) void {
        self.resetSlots();
        self.count = 0;
        self.cursor = 0;
        self.pinned_next = 0;
        self.committed_count = 0;
        self.shuffled = false;
        self.shuffle_kind = .off;
        self.repeat = .off;
        self.revision +%= 1;
        self.membership_revision +%= 1;
    }

    pub fn append(self: *Queue, id: u64) !void {
        if (id == 0) return error.InvalidTrackIdentity;
        if (self.count == self.capacity()) return error.QueueFull;
        if (self.next_occurrence == std.math.maxInt(Occurrence)) return error.OccurrenceExhausted;
        const slot = self.free_head;
        std.debug.assert(slot != no_slot);
        self.free_head = @intCast(self.token(slot));
        self.setTrack(slot, id);
        self.setToken(slot, self.next_occurrence);
        self.next_occurrence += 1;
        self.setIndex(self.count, false, @intCast(slot));
        self.setIndex(self.count, true, @intCast(slot));
        self.count += 1;
        self.revision +%= 1;
        self.membership_revision +%= 1;
    }

    pub fn at(self: Queue, position: usize) ?u64 {
        return if (position < self.count) self.track(self.index(position, self.shuffled)) else null;
    }

    pub fn slotAt(self: Queue, position: usize) ?u16 {
        return if (position < self.count) self.index(position, self.shuffled) else null;
    }

    pub fn canonicalSlotAt(self: Queue, position: usize) ?u16 {
        return if (position < self.count) self.index(position, false) else null;
    }

    pub fn canonicalAt(self: Queue, position: usize) ?u64 {
        return if (self.canonicalSlotAt(position)) |slot| self.track(slot) else null;
    }

    pub fn isCommitted(self: Queue, occurrence: Occurrence) bool {
        return std.mem.indexOfScalar(Occurrence, self.committed[0..self.committed_count], occurrence) != null;
    }

    fn committedAnchor(self: Queue) ?u16 {
        return if (self.committed_count == 0) null else self.slotAt(self.positionOf(self.committed[self.committed_count - 1]) orelse return null);
    }

    /// Decoder lookahead is fenced until its audible boundary. These
    /// tokens never enter the persisted session and explicit replacement clears
    /// them after cancelling the old producer.
    pub fn membershipRevision(self: *const Queue) u32 {
        // The UI can preempt preparation on the native single-core executive.
        // Force real word observations rather than allowing CSE of two loads
        // across allocation-free lookup loops with no explicit function yield.
        return @as(*const volatile u32, &self.membership_revision).*;
    }

    pub fn prepareCommit(self: *const Queue, occurrence: Occurrence) !Admission {
        const revision = self.membershipRevision();
        const generation = self.admission_generation;
        const position = self.positionOf(occurrence) orelse return error.StaleOccurrence;
        if (position <= self.cursor) return error.NotUpcoming;
        if (self.committed_count == self.committed.len) return error.CommitFull;
        if (self.isCommitted(occurrence)) return error.AlreadyCommitted;
        if (self.committedAnchor()) |last| if (position <= self.rank(last, self.shuffled).?) return error.NotUpcoming;
        if (self.membershipRevision() != revision or self.admission_generation != generation) return error.QueueChanged;
        return .{ .occurrence = occurrence, .position = position, .membership_revision = revision, .generation = generation };
    }

    /// O(1) commit. The caller excludes UI preemption around this method and
    /// installing the corresponding reader. No scans, allocation or I/O belong
    /// in that critical section. Only this storage writer appends admissions;
    /// the UI may have retired any number from the front since preparation.
    pub fn commitPrepared(self: *Queue, admission: Admission) !void {
        if (self.membershipRevision() != admission.membership_revision or self.admission_generation != admission.generation) return error.QueueChanged;
        if (admission.position <= self.cursor) return error.NotUpcoming;
        if (self.occurrenceAt(admission.position) != admission.occurrence) return error.StaleOccurrence;
        if (self.committed_count == self.committed.len) return error.CommitFull;
        self.committed[self.committed_count] = admission.occurrence;
        self.committed_count += 1;
        self.admission_generation +%= 1;
    }

    pub fn commitNext(self: *Queue, occurrence: Occurrence) !void {
        try self.commitPrepared(try self.prepareCommit(occurrence));
    }

    pub fn advanceCommitted(self: *Queue, occurrence: Occurrence) bool {
        if (self.committed_count == 0 or self.committed[0] != occurrence) return false;
        const position = self.positionOf(occurrence) orelse return false;
        self.pinned_next -= @min(self.pinned_next, position -| self.cursor);
        self.cursor = position;
        self.committed_count -= 1;
        @memmove(self.committed[0..self.committed_count], self.committed[1..][0..self.committed_count]);
        self.revision +%= 1;
        return true;
    }

    /// Validate all untrusted persisted fields before changing a live queue.
    /// Occurrences are fresh after restore; disk ordinals identify duplicates.
    pub fn restoreFrom(self: *Queue, source: anytype, cursor: usize, kind: Shuffle, repeat_mode: Repeat, pinned: usize) !void {
        const length = source.len();
        if (length > self.capacity() or length > std.math.maxInt(Occurrence) - self.next_occurrence) return error.QueueFull;
        if ((length == 0 and (cursor != 0 or pinned != 0)) or (length != 0 and (cursor >= length or pinned > length - cursor - 1))) return error.InvalidQueue;
        var seen = std.StaticBitSet(8192).empty;
        for (0..length) |i| {
            const ordinal = source.ordinal(i);
            if (source.canonical(i) == 0 or ordinal >= length or seen.isSet(ordinal) or (kind == .off and ordinal != i)) return error.InvalidQueue;
            seen.set(ordinal);
        }
        self.clear();
        for (0..length) |i| try self.append(source.canonical(i));
        for (0..length) |i| self.setIndex(i, true, source.ordinal(i));
        self.cursor = cursor;
        self.shuffle_kind = kind;
        self.shuffled = kind != .off;
        self.repeat = repeat_mode;
        self.pinned_next = pinned;
    }

    pub fn occurrenceAt(self: Queue, position: usize) ?Occurrence {
        return if (position < self.count) self.token(self.index(position, self.shuffled)) else null;
    }

    pub fn positionOf(self: Queue, occurrence: Occurrence) ?usize {
        if (occurrence == 0) return null;
        for (0..self.count) |i| if (self.occurrenceAt(i).? == occurrence) return i;
        return null;
    }

    pub fn selectOccurrence(self: *Queue, occurrence: Occurrence) bool {
        self.cursor = self.positionOf(occurrence) orelse return false;
        self.pinned_next = 0;
        self.revision +%= 1;
        return true;
    }

    pub fn select(self: *Queue, id: u64) bool {
        for (0..self.count) |i| {
            if (self.at(i).? == id) return self.selectOccurrence(self.occurrenceAt(i).?);
        }
        return false;
    }

    fn syncInactive(self: *Queue) void {
        if (!self.shuffled) for (0..self.count) |i| {
            self.setIndex(i, true, self.index(i, false));
        };
    }

    fn relocate(self: *Queue, from: usize, to: usize, shuffled: bool) void {
        const slot = self.index(from, shuffled);
        if (from < to) {
            for (from..to) |i| self.setIndex(i, shuffled, self.index(i + 1, shuffled));
        } else {
            var i = from;
            while (i > to) : (i -= 1) self.setIndex(i, shuffled, self.index(i - 1, shuffled));
        }
        self.setIndex(to, shuffled, slot);
    }

    fn relocateAfter(self: *Queue, slot: u16, anchor: u16, shuffled: bool) void {
        const from = self.rank(slot, shuffled).?;
        const target = self.rank(anchor, shuffled).?;
        self.relocate(from, if (from < target) target else target + 1, shuffled);
    }

    /// Validate a whole batch before mutation, and retain its original order.
    pub fn insert(self: *Queue, ids: []const u64, next: bool) !void {
        const Source = struct {
            ids: []const u64,
            pub fn len(source: @This()) usize {
                return source.ids.len;
            }

            pub fn id(source: @This(), i: usize) u64 {
                return source.ids[i];
            }
        };
        try self.insertFrom(Source{ .ids = ids }, next);
    }

    /// A prepared catalogue can supply a large album without a temporary ID
    /// array. The source must remain immutable for this synchronous operation.
    pub fn insertFrom(self: *Queue, source: anytype, next: bool) !void {
        const length = source.len();
        if (length > self.capacity() - self.count) return error.QueueFull;
        if (length > std.math.maxInt(Occurrence) - self.next_occurrence) return error.OccurrenceExhausted;
        for (0..length) |i| if (source.id(i) == 0) return error.InvalidTrackIdentity;
        if (length == 0) return;
        self.syncInactive();
        const current = if (self.count > 0) self.index(self.cursor, self.shuffled) else null;
        const insertion = if (self.committedAnchor()) |slot| self.rank(slot, self.shuffled) else null;
        const anchor = if (insertion) |position| self.index(position, self.shuffled) else current;
        const canonical = if (anchor) |slot| self.rank(slot, false).? else 0;
        const playback = insertion orelse self.cursor;
        for (0..length) |i| {
            try self.append(source.id(i));
            if (next and current != null) {
                self.relocate(self.count - 1, canonical + 1 + i, false);
                self.relocate(self.count - 1, playback + 1 + i, true);
            }
        }
        if (next and current != null) {
            self.pinned_next = @max(self.pinned_next, playback -| self.cursor) + length;
            if (self.repeat == .one) self.repeat = .off;
        }
    }

    pub fn remove(self: *Queue, occurrence: Occurrence) !void {
        const position = self.positionOf(occurrence) orelse return error.StaleOccurrence;
        if (self.isCommitted(occurrence)) return error.CommittedOccurrence;
        self.syncInactive();
        if (position == self.cursor) return error.CurrentOccurrence;
        const slot = self.index(position, self.shuffled);
        const canonical = self.rank(slot, false).?;
        const played = self.rank(slot, true).?;
        for (canonical..self.count - 1) |i| self.setIndex(i, false, self.index(i + 1, false));
        for (played..self.count - 1) |i| self.setIndex(i, true, self.index(i + 1, true));
        if (position > self.cursor and position <= self.cursor + self.pinned_next) self.pinned_next -= 1;
        if (position < self.cursor) self.cursor -= 1;
        self.setTrack(slot, 0);
        self.setToken(slot, self.free_head);
        self.free_head = slot;
        self.count -= 1;
        self.revision +%= 1;
        self.membership_revision +%= 1;
    }

    pub fn moveNext(self: *Queue, occurrence: Occurrence) !void {
        const position = self.positionOf(occurrence) orelse return error.StaleOccurrence;
        if (self.isCommitted(occurrence)) return error.CommittedOccurrence;
        self.syncInactive();
        if (position <= self.cursor) return error.NotUpcoming;
        const current = self.index(self.cursor, self.shuffled);
        const slot = self.index(position, self.shuffled);
        const was_pinned = position <= self.cursor + self.pinned_next;
        const anchor = self.committedAnchor() orelse current;
        self.relocateAfter(slot, anchor, false);
        self.relocateAfter(slot, anchor, true);
        if (!was_pinned) self.pinned_next = @max(self.pinned_next + 1, self.rank(slot, self.shuffled).? - self.cursor);
        self.revision +%= 1;
        self.membership_revision +%= 1;
    }

    pub fn shuffle(self: *Queue, seed: u64, preserve_current: bool) void {
        if (self.shuffled) return;
        for (0..self.count) |i| self.setIndex(i, true, self.index(i, false));
        var generator = std.Random.DefaultPrng.init(seed);
        const random = generator.random();
        const first = if (preserve_current and self.count != 0) self.cursor + 1 + @max(self.pinned_next, if (self.committedAnchor()) |slot| self.rank(slot, self.shuffled).? - self.cursor else 0) else 0;
        var end = self.count;
        while (end > first + 1) {
            end -= 1;
            const other = first + random.uintLessThan(usize, end - first + 1);
            const slot = self.index(end, true);
            self.setIndex(end, true, self.index(other, true));
            self.setIndex(other, true, slot);
        }
        self.shuffled = true;
        self.shuffle_kind = .songs;
        if (!preserve_current) self.cursor = 0;
        self.revision +%= 1;
        self.membership_revision +%= 1;
    }

    /// Resolver exposes canonical album spans; scratch occupies the unused tail
    /// of the playback permutation until each span has been materialised.
    pub fn shuffleAlbums(self: *Queue, seed: u64, resolver: anytype) !void {
        if (resolver.trackCount() != self.count or resolver.albumCount() > self.count) return error.InvalidAlbumGroups;
        const groups = resolver.albumCount();
        var expected: usize = 0;
        for (0..groups) |group| {
            const length = resolver.count(group);
            if (resolver.first(group) != expected or length == 0 or length > self.count - expected) return error.InvalidAlbumGroups;
            expected += length;
        }
        if (expected != self.count) return error.InvalidAlbumGroups;
        const base = self.capacity() - groups;
        for (0..groups) |i| self.setIndex(base + i, true, @intCast(i));
        var generator = std.Random.DefaultPrng.init(seed);
        var end = groups;
        while (end > 1) {
            end -= 1;
            const other = generator.random().uintLessThan(usize, end + 1);
            const value = self.index(base + end, true);
            self.setIndex(base + end, true, self.index(base + other, true));
            self.setIndex(base + other, true, value);
        }
        var written: usize = 0;
        for (0..groups) |i| {
            const group = self.index(base + i, true);
            for (resolver.first(group)..resolver.first(group) + resolver.count(group)) |rank_index| {
                self.setIndex(written, true, self.index(rank_index, false));
                written += 1;
            }
        }
        std.debug.assert(written == self.count);
        self.shuffled = true;
        self.shuffle_kind = .albums;
        self.cursor = 0;
        self.pinned_next = 0;
        self.revision +%= 1;
        self.membership_revision +%= 1;
    }

    pub fn sortCanonical(self: *Queue, resolver: anytype) void {
        std.debug.assert(!self.shuffled);
        const Sort = struct {
            queue: *Queue,
            resolver: @TypeOf(resolver),
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return ctx.resolver.less(ctx.queue.at(a).?, ctx.queue.at(b).?);
            }

            pub fn swap(ctx: @This(), a: usize, b: usize) void {
                const slot = ctx.queue.index(a, false);
                ctx.queue.setIndex(a, false, ctx.queue.index(b, false));
                ctx.queue.setIndex(b, false, slot);
            }
        };
        std.sort.heapContext(0, self.count, Sort{ .queue = self, .resolver = resolver });
        for (0..self.count) |i| self.setIndex(i, true, self.index(i, false));
    }

    pub fn unshuffle(self: *Queue) void {
        const current = self.occurrenceAt(self.cursor);
        if (current != null) {
            var anchor = self.index(self.cursor, self.shuffled);
            const committed_end = if (self.committedAnchor()) |slot| self.rank(slot, self.shuffled).? - self.cursor else 0;
            const prefix = @max(self.pinned_next, committed_end);
            // Retain the entire admitted/manual prefix in its realized order,
            // including skipped rows. Moving only committed tokens can split a
            // manual Play Next segment when canonical order is restored.
            for (self.cursor + 1..self.cursor + 1 + prefix) |position| {
                const slot = self.index(position, self.shuffled);
                self.relocateAfter(slot, anchor, false);
                anchor = slot;
            }
        }
        self.shuffled = false;
        self.shuffle_kind = .off;
        if (current) |occurrence| self.cursor = self.positionOf(occurrence).?;
        self.revision +%= 1;
        self.membership_revision +%= 1;
    }

    pub fn adjacent(self: *Queue, direction: i2, resolver: anytype) ?u64 {
        std.debug.assert(direction == -1 or direction == 1);
        if (self.count == 0) return null;
        var position = self.cursor;
        for (0..self.count) |_| {
            if (direction < 0) {
                if (position == 0) {
                    if (self.repeat != .all) return null;
                    position = self.count;
                }
                position -= 1;
            } else {
                position += 1;
                if (position >= self.count) {
                    if (self.repeat != .all) return null;
                    position = 0;
                }
            }
            const id = self.at(position).?;
            if (resolver.contains(id)) {
                if (direction > 0) {
                    self.pinned_next -= @min(self.pinned_next, if (position > self.cursor) position - self.cursor else self.pinned_next);
                } else self.pinned_next = 0;
                self.cursor = position;
                self.revision +%= 1;
                return id;
            }
        }
        return null;
    }

    pub fn cycleRepeat(self: *Queue) void {
        self.repeat = switch (self.repeat) {
            .off => .all,
            .all => .one,
            .one => .off,
        };
        self.membership_revision +%= 1;
        self.revision +%= 1;
    }

    pub fn finished(self: *Queue, resolver: anytype) ?u64 {
        if (self.repeat == .one) {
            if (self.at(self.cursor)) |id| if (resolver.contains(id)) return id;
        }
        return self.adjacent(1, resolver);
    }
};

const Present = struct {
    pub fn contains(_: @This(), id: u64) bool {
        return id != 3;
    }
};

test "play order survives browsing changes, removals and retags without inserting new scans" {
    var bytes: [64]u8 = undefined;
    var queue = Queue.init(&bytes);
    for ([_]u64{ 8, 5, 3, 9 }) |id| try queue.append(id);
    try std.testing.expect(queue.select(5));
    try std.testing.expectEqual(9, queue.adjacent(1, Present{}).?);
    try std.testing.expectEqual(null, queue.adjacent(1, Present{}));
    try std.testing.expectEqual(5, queue.adjacent(-1, Present{}).?);
    try std.testing.expectEqual(8, queue.adjacent(-1, Present{}).?);
    try std.testing.expectEqual(null, queue.adjacent(-1, Present{}));
    try std.testing.expectEqual(3, queue.at(2).?);
    try std.testing.expectError(error.QueueFull, queue.append(10));
}

test "seeded shuffle is a permutation, retains current playback and restores canonical order" {
    for (0..100) |seed| {
        var bytes: [64 * 16]u8 = undefined;
        var queue = Queue.init(&bytes);
        for (1..65) |id| try queue.append(id);
        try std.testing.expect(queue.select(12));
        queue.shuffle(seed, true);
        try std.testing.expectEqual(12, queue.at(queue.cursor).?);
        var seen: u64 = 0;
        for (0..queue.count) |i| {
            const mask = @as(u64, 1) << @as(u6, @intCast(queue.at(i).? - 1));
            try std.testing.expectEqual(0, seen & mask);
            seen |= mask;
            if (i < 12) try std.testing.expectEqual(i + 1, queue.at(i).?);
        }
        try std.testing.expectEqual(std.math.maxInt(u64), seen);
        const next = queue.adjacent(1, Present{}).?;
        queue.unshuffle();
        try std.testing.expectEqual(next, queue.at(queue.cursor).?);
        for (0..queue.count) |i| try std.testing.expectEqual(i + 1, queue.at(i).?);
    }
}

test "collection shuffle includes its first track and is reproducible" {
    var left: [128]u8 = undefined;
    var right: [128]u8 = undefined;
    var a = Queue.init(&left);
    var b = Queue.init(&right);
    for (1..9) |id| {
        try a.append(id);
        try b.append(id);
    }
    a.shuffle(42, false);
    b.shuffle(42, false);
    try std.testing.expectEqualSlices(u8, &left, &right);
    var different = false;
    for (0..a.count) |i| different = different or a.at(i).? != i + 1;
    try std.testing.expect(different);
}

test "repeat boundaries, manual skips and a wholly missing queue terminate correctly" {
    var bytes: [64]u8 = undefined;
    var queue = Queue.init(&bytes);
    for ([_]u64{ 8, 3, 9 }) |id| try queue.append(id);
    try std.testing.expect(queue.select(9));
    try std.testing.expectEqual(null, queue.finished(Present{}));
    queue.repeat = .all;
    try std.testing.expectEqual(8, queue.finished(Present{}).?);
    try std.testing.expectEqual(9, queue.adjacent(-1, Present{}).?);
    queue.repeat = .one;
    try std.testing.expectEqual(9, queue.finished(Present{}).?);
    try std.testing.expectEqual(8, queue.adjacent(-1, Present{}).?);
    const Missing = struct {
        pub fn contains(_: @This(), _: u64) bool {
            return false;
        }
    };
    queue.repeat = .all;
    try std.testing.expectEqual(null, queue.finished(Missing{}));
    queue.clear();
    try std.testing.expectEqual(null, queue.finished(Present{}));
    try std.testing.expectEqual(Repeat.off, queue.repeat);
    try std.testing.expect(!queue.shuffled);
}

test "duplicate occurrences are independently selectable and stale edits cannot affect reused slots" {
    var bytes: [8 * 16]u8 = undefined;
    var queue = Queue.init(&bytes);
    try queue.insert(&.{ 7, 7, 8 }, false);
    const first = queue.occurrenceAt(0).?;
    const duplicate = queue.occurrenceAt(1).?;
    try std.testing.expect(first != duplicate);
    try std.testing.expect(queue.selectOccurrence(duplicate));
    try queue.remove(first);
    try queue.append(7);
    try std.testing.expectError(error.StaleOccurrence, queue.remove(first));
    try std.testing.expectEqual(duplicate, queue.occurrenceAt(queue.cursor).?);
    try std.testing.expectError(error.CurrentOccurrence, queue.remove(duplicate));
}

test "ordered Play Next batches survive shuffle and failed insertions are atomic" {
    var bytes: [8 * 16]u8 = undefined;
    var queue = Queue.init(&bytes);
    try queue.insert(&.{ 1, 2, 3, 4 }, false);
    try std.testing.expect(queue.select(2));
    queue.repeat = .one;
    try queue.insert(&.{ 8, 9 }, true);
    try std.testing.expectEqual(Repeat.off, queue.repeat);
    const current = queue.occurrenceAt(queue.cursor).?;
    queue.shuffle(41, true);
    try std.testing.expectEqual(8, queue.at(queue.cursor + 1).?);
    try std.testing.expectEqual(9, queue.at(queue.cursor + 2).?);
    queue.unshuffle();
    try std.testing.expectEqual(current, queue.occurrenceAt(queue.cursor).?);
    try queue.insert(&.{ 10, 11 }, true);
    const before = bytes;
    try std.testing.expectError(error.QueueFull, queue.insert(&.{12}, true));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
    try std.testing.expectEqual(10, queue.at(queue.cursor + 1).?);
    try std.testing.expectEqual(11, queue.at(queue.cursor + 2).?);
    try std.testing.expectEqual(8, queue.at(queue.cursor + 3).?);
}

test "seeded edits preserve both permutations and the current occurrence" {
    var bytes: [64 * 16]u8 = undefined;
    var queue = Queue.init(&bytes);
    try queue.append(1);
    const current = queue.occurrenceAt(0).?;
    var prng = std.Random.DefaultPrng.init(0x4741494e);
    const random = prng.random();
    for (0..20000) |step| {
        switch (random.uintLessThan(u8, 6)) {
            0 => if (queue.count < queue.capacity()) {
                try queue.append(1 + random.uintLessThan(u64, 8));
            },
            1 => if (queue.count < queue.capacity()) {
                try queue.insert(&.{1 + random.uintLessThan(u64, 8)}, true);
            },
            2 => if (queue.count > 1) {
                try queue.remove(queue.occurrenceAt(1 + random.uintLessThan(usize, queue.count - 1)).?);
            },
            3 => queue.shuffle(step, true),
            4 => queue.unshuffle(),
            else => if (queue.count > 1) {
                try queue.moveNext(queue.occurrenceAt(1 + random.uintLessThan(usize, queue.count - 1)).?);
            },
        }
        try std.testing.expectEqual(current, queue.occurrenceAt(queue.cursor).?);
        var canonical: u64 = 0;
        var playback: u64 = 0;
        for (0..queue.count) |i| {
            const a = @as(u64, 1) << @as(u6, @intCast(queue.index(i, false)));
            const b = @as(u64, 1) << @as(u6, @intCast(queue.index(i, true)));
            try std.testing.expectEqual(0, canonical & a);
            try std.testing.expectEqual(0, playback & b);
            canonical |= a;
            playback |= b;
        }
        try std.testing.expectEqual(canonical, playback);
    }
}

test "album shuffle covers full capacity, preserves album sequence and rejects invalid spans" {
    const Source = struct {
        size: usize,
        pub fn trackCount(_: @This()) usize {
            return 8192;
        }

        pub fn albumCount(s: @This()) usize {
            return std.math.divCeil(usize, 8192, s.size) catch unreachable;
        }

        pub fn first(s: @This(), i: usize) usize {
            return i * s.size;
        }

        pub fn count(s: @This(), i: usize) usize {
            return @min(s.size, 8192 - s.first(i));
        }
    };
    const bytes = try std.testing.allocator.alloc(u8, 8192 * 16);
    defer std.testing.allocator.free(bytes);
    for ([_]usize{ 1, 2, 7, 64, 8192 }) |size| {
        var queue = Queue.init(bytes);
        for (1..8193) |id| try queue.append(id);
        try queue.shuffleAlbums(42, Source{ .size = size });
        var seen = std.StaticBitSet(8192).empty;
        for (0..queue.count) |i| {
            const id = queue.at(i).? - 1;
            try std.testing.expect(!seen.isSet(id));
            seen.set(id);
            if (id % size != 0) try std.testing.expectEqual(id, queue.at(i - 1).?);
        }
        queue.unshuffle();
        for (0..8192) |i| try std.testing.expectEqual(i + 1, queue.at(i).?);
    }
}

test "decoder lookahead fences committed occurrences while edits preserve their audible FIFO" {
    var bytes: [16 * 16]u8 = undefined;
    var queue = Queue.init(&bytes);
    for (1..10) |id| try queue.append(id);
    try std.testing.expect(queue.select(3));
    const playing = queue.occurrenceAt(queue.cursor).?;
    const first = queue.occurrenceAt(4).?;
    const second = queue.occurrenceAt(6).?;
    try queue.commitNext(first);
    try queue.commitNext(second);
    try std.testing.expectError(error.CommittedOccurrence, queue.remove(first));
    try std.testing.expectError(error.CommittedOccurrence, queue.moveNext(second));
    try queue.insert(&.{ 99, 100 }, true);
    try std.testing.expectEqual(99, queue.at(7).?);
    try std.testing.expectEqual(100, queue.at(8).?);
    // A missing/unadmitted queue row may sit before the last admitted row.
    // Moving it next must land immediately after that row, without a +1 error.
    try queue.moveNext(queue.occurrenceAt(3).?);
    try std.testing.expectEqual(7, queue.at(5).?);
    try std.testing.expectEqual(4, queue.at(6).?);
    try std.testing.expectEqual(99, queue.at(7).?);
    queue.shuffle(47, true);
    queue.unshuffle();
    try std.testing.expectEqual(playing, queue.occurrenceAt(queue.cursor).?);
    try std.testing.expectEqualSlices(Occurrence, &.{ first, second }, queue.committed[0..queue.committed_count]);
    try std.testing.expect(!queue.advanceCommitted(second));
    const revision = queue.membership_revision;
    try std.testing.expect(queue.advanceCommitted(first));
    try std.testing.expect(queue.advanceCommitted(second));
    try std.testing.expectEqual(revision, queue.membership_revision);
    try std.testing.expectEqual(0, queue.committed_count);
    try std.testing.expectEqual(second, queue.occurrenceAt(queue.cursor).?);
    try std.testing.expect(queue.pinned_next <= queue.count - queue.cursor - 1);
}

test "moving a skipped upcoming item after the decoder fence never exceeds the pinned range" {
    var bytes: [8 * 16]u8 = undefined;
    var queue = Queue.init(&bytes);
    try queue.insert(&.{ 1, 2, 3, 4, 5 }, false);
    try queue.commitNext(queue.occurrenceAt(2).?);
    try queue.commitNext(queue.occurrenceAt(4).?);
    const skipped = queue.occurrenceAt(1).?;
    try queue.moveNext(skipped);
    try std.testing.expectEqual(5, queue.at(3).?);
    try std.testing.expectEqual(2, queue.at(4).?);
    try std.testing.expectEqual(4, queue.pinned_next);
    queue.shuffle(42, true);
    try std.testing.expectEqual(2, queue.at(4).?);
    queue.unshuffle();
    try std.testing.expectEqual(2, queue.at(4).?);
}

test "full lookahead window backpressures atomically and reclamation accepts one new occurrence" {
    var bytes: [130 * 16]u8 = undefined;
    var queue = Queue.init(&bytes);
    for (1..131) |id| try queue.append(id);
    for (1..65) |i| try queue.commitNext(queue.occurrenceAt(i).?);
    const before = queue.committed;
    try std.testing.expectError(error.CommitFull, queue.commitNext(queue.occurrenceAt(65).?));
    try std.testing.expectEqualSlices(Occurrence, &before, &queue.committed);
    try std.testing.expect(queue.advanceCommitted(queue.occurrenceAt(1).?));
    try queue.commitNext(queue.occurrenceAt(65).?);
    for (2..66) |i| try std.testing.expect(queue.advanceCommitted(queue.occurrenceAt(i).?));
    try std.testing.expectEqual(65, queue.cursor);
    try std.testing.expectEqual(0, queue.committed_count);
}

test "every upcoming move preserves the playing occurrence, committed order and both permutations" {
    for (0..8) |playing_position| for (playing_position + 1..8) |anchor| for (playing_position + 1..8) |moved_position| {
        if (anchor == moved_position) continue;
        var bytes: [8 * 16]u8 = undefined;
        var queue = Queue.init(&bytes);
        for (1..9) |id| try queue.append(id);
        queue.cursor = playing_position;
        const playing = queue.occurrenceAt(playing_position).?;
        const committed = queue.occurrenceAt(anchor).?;
        const moved = queue.occurrenceAt(moved_position).?;
        try queue.commitNext(committed);
        try queue.moveNext(moved);
        try std.testing.expectEqual(playing, queue.occurrenceAt(queue.cursor).?);
        try std.testing.expectEqual(queue.positionOf(committed).? + 1, queue.positionOf(moved).?);
        try std.testing.expect(queue.pinned_next <= queue.count - queue.cursor - 1);
        for ([_]bool{ false, true }) |shuffled| {
            var seen: u8 = 0;
            for (0..queue.count) |i| {
                const bit = @as(u8, 1) << @as(u3, @intCast(queue.index(i, shuffled)));
                try std.testing.expectEqual(0, seen & bit);
                seen |= bit;
            }
            try std.testing.expectEqual(255, seen);
        }
        queue.shuffle(47, true);
        try std.testing.expectEqual(queue.positionOf(committed).? + 1, queue.positionOf(moved).?);
        queue.unshuffle();
        try std.testing.expectEqual(playing, queue.occurrenceAt(queue.cursor).?);
        try std.testing.expectEqual(queue.positionOf(committed).? + 1, queue.positionOf(moved).?);
    };
}

test "free slot reuse remains bounded after removal and a clear never reuses occurrence identities" {
    var bytes: [64 * 16]u8 = undefined;
    var queue = Queue.init(&bytes);
    for (1..65) |id| try queue.append(id);
    var stale: [32]Occurrence = undefined;
    for (&stale, 0..) |*occurrence, i| occurrence.* = queue.occurrenceAt(i * 2 + 1).?;
    for (stale) |occurrence| try queue.remove(occurrence);
    for (0..32) |_| try queue.append(7);
    for (stale) |occurrence| try std.testing.expectEqual(null, queue.positionOf(occurrence));
    const latest = queue.next_occurrence;
    queue.clear();
    for (1..65) |id| try queue.append(id);
    try std.testing.expectEqual(latest, queue.occurrenceAt(0).?);
    try std.testing.expectEqual(no_slot, queue.free_head);
    for (0..queue.count) |i| try std.testing.expectEqual(i + 1, queue.at(i).?);
}

test "queue edits between preparation and admission invalidate stale source handoffs" {
    var bytes: [12 * 16]u8 = undefined;
    for (0..4) |mutation| {
        var queue = Queue.init(&bytes);
        try queue.insert(&.{ 1, 2, 3, 4, 5 }, false);
        const next = queue.occurrenceAt(1).?;
        const admission = try queue.prepareCommit(next);
        switch (mutation) {
            0 => queue.shuffle(42, true),
            1 => try queue.insert(&.{7}, true),
            2 => try queue.remove(next),
            else => {
                queue.clear();
                try queue.insert(&.{ 8, 9 }, false);
            },
        }
        try std.testing.expectError(error.QueueChanged, queue.commitPrepared(admission));
        try std.testing.expectEqual(0, queue.committed_count);
    }
}

test "natural audible retirement is allowed between preparation and constant-time admission" {
    var bytes: [8 * 16]u8 = undefined;
    var queue = Queue.init(&bytes);
    try queue.insert(&.{ 1, 2, 3, 4 }, false);
    const second = queue.occurrenceAt(1).?;
    const third = queue.occurrenceAt(2).?;
    try queue.commitNext(second);
    const admission = try queue.prepareCommit(third);
    try std.testing.expect(queue.advanceCommitted(second));
    try queue.commitPrepared(admission);
    try std.testing.expectEqual(1, queue.committed_count);
    try std.testing.expectEqual(third, queue.committed[0]);
    try std.testing.expect(queue.advanceCommitted(third));
    try std.testing.expectEqual(2, queue.cursor);
    try std.testing.expectError(error.QueueChanged, queue.commitPrepared(admission));
}

test "another admission invalidates an outstanding preparation without rescanning the queue" {
    var bytes: [8 * 16]u8 = undefined;
    var queue = Queue.init(&bytes);
    try queue.insert(&.{ 1, 2, 3 }, false);
    const earlier = try queue.prepareCommit(queue.occurrenceAt(1).?);
    const later = try queue.prepareCommit(queue.occurrenceAt(2).?);
    try queue.commitPrepared(later);
    try std.testing.expectError(error.QueueChanged, queue.commitPrepared(earlier));
    try std.testing.expectEqual(1, queue.committed_count);
}
