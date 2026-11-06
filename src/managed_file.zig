//! Existing diagnostic/cache allocations prepared by the host. Invalid or
//! missing files disable persistence; they never authorize allocation or format.
const std = @import("std");
const fat = @import("fat32.zig");

pub const prefix_bytes = 4096;

pub const Kind = enum(u16) { catalog = 1, artwork = 2, diagnostics = 3, settings = 4, session = 5, activity = 6, playlists = 7 };

pub fn valid(bytes: *const [512]u8, kind: Kind, size: u32) bool {
    return std.mem.eql(u8, bytes[0..4], "GPRV") and std.mem.readInt(u16, bytes[4..6], .little) == 1 and std.mem.readInt(u16, bytes[6..8], .little) == @backingInt(kind) and std.mem.readInt(u32, bytes[8..12], .little) == size and size >= prefix_bytes + 4096 and std.hash.Crc32.hash(bytes[0..508]) == std.mem.readInt(u32, bytes[508..512], .little);
}

pub fn open(volume: anytype, path: []const u8, kind: Kind, buffer: *[512]u8) !fat.File {
    const file = try (try volume.findPath(path)).file();
    var reader = try volume.reader(file);
    if (try reader.read(buffer) != 512 or !valid(buffer, kind, file.size)) return error.UnprovisionedFile;
    return file;
}
