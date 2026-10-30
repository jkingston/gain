const x1000 = @import("x1000.zig");
const board = @import("f20_v27.zig");
const sd = @import("sd.zig");
const builtin = @import("builtin");

pub const Controller = sd.Controller(board.storage);
pub const DmaDescriptor = x1000.Msc0.DmaDescriptor;
pub const fat32 = @import("fat32.zig");
pub const wav = @import("wav.zig");

pub const Error = error{
    InvalidBounceBuffer,
};

/// Reads a FAT32 file through caller-owned uncached DMA memory, then copies it
/// into CPU-friendly cached storage. Selecting the bounce offset from the file
/// position keeps every whole-sector transfer four-byte aligned even when a
/// codec's metadata ends at an odd address.
pub fn BufferedReader(comptime Inner: type) type {
    return struct {
        const Self = @This();

        inner: *Inner,
        bounce: []u8,

        pub fn init(inner: *Inner, bounce: []u8) Error!Self {
            const address = @intFromPtr(bounce.ptr);
            if (bounce.len < fat32.sector_bytes + 3 or address & 3 != 0 or
                (comptime builtin.cpu.arch == .mipsel) and !x1000.isUncachedAddress(address))
            {
                return error.InvalidBounceBuffer;
            }
            return .{ .inner = inner, .bounce = bounce };
        }

        pub fn read(self: *Self, output: []u8) !usize {
            var written: usize = 0;
            while (written < output.len) {
                const offset: usize = self.inner.position & 3;
                const wanted = @min(output.len - written, self.bounce.len - offset);
                const count = try self.inner.read(self.bounce[offset..][0..wanted]);
                if (count == 0) break;
                @memcpy(output[written..][0..count], self.bounce[offset..][0..count]);
                written += count;
                if (count != wanted) break;
            }
            return written;
        }
    };
}
