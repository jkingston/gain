//! A bounded snapshot of the chosen play order. It owns stable IDs, never
//! catalogue pointers; browsing and progressive publications cannot reorder it.
const std = @import("std");
pub const Queue = struct {
    bytes: []u8,
    count: usize = 0,
    cursor: usize = 0,

    pub fn init(bytes: []u8) Queue {
        return .{ .bytes = bytes };
    }

    pub fn capacity(self: Queue) usize {
        return self.bytes.len / 8;
    }

    pub fn clear(self: *Queue) void {
        self.count = 0;
        self.cursor = 0;
    }

    pub fn append(self: *Queue, id: u64) !void {
        if (id == 0) return error.InvalidTrackIdentity;
        if (self.count == self.capacity()) return error.QueueFull;
        std.mem.writeInt(u64, self.bytes[self.count * 8 ..][0..8], id, .little);
        self.count += 1;
    }

    pub fn at(self: Queue, index: usize) ?u64 {
        if (index >= self.count) return null;
        return std.mem.readInt(u64, self.bytes[index * 8 ..][0..8], .little);
    }

    pub fn select(self: *Queue, id: u64) bool {
        for (0..self.count) |i| if (self.at(i).? == id) {
            self.cursor = i;
            return true;
        };
        return false;
    }

    /// The resolver sees the latest catalogue. Missing tracks are skipped;
    /// existing IDs retain their original relative order and current metadata.
    pub fn adjacent(self: *Queue, direction: i2, resolver: anytype) ?u64 {
        std.debug.assert(direction == -1 or direction == 1);
        var position = self.cursor;
        while (true) {
            if (direction < 0) {
                if (position == 0) return null;
                position -= 1;
            } else {
                position += 1;
                if (position >= self.count) return null;
            }
            const id = self.at(position).?;
            if (resolver.contains(id)) {
                self.cursor = position;
                return id;
            }
        }
    }
};

test "play order survives browsing changes, removals and retags without inserting new scans" {
    var bytes: [32]u8 = undefined;
    var queue = Queue.init(&bytes);
    for ([_]u64{ 8, 5, 3, 9 }) |id| try queue.append(id);
    try std.testing.expect(queue.select(5));
    const Resolver = struct {
        pub fn contains(_: @This(), id: u64) bool {
            return id != 3;
        }
    };
    try std.testing.expectEqual(9, queue.adjacent(1, Resolver{}).?);
    try std.testing.expectEqual(null, queue.adjacent(1, Resolver{}));
    try std.testing.expectEqual(5, queue.adjacent(-1, Resolver{}).?);
    try std.testing.expectEqual(8, queue.adjacent(-1, Resolver{}).?);
    try std.testing.expectEqual(null, queue.adjacent(-1, Resolver{}));
    try std.testing.expectEqual(3, queue.at(2).?);
    try std.testing.expectError(error.QueueFull, queue.append(10));
    try std.testing.expectEqual(4, queue.count);
}
