//! Bounded host-file access shared by player-app persistence adapters. Unknown
//! allocations and symbolic links stay untouched; this never creates files.
const std = @import("std");
const gain = @import("gain_ui");

pub const File = struct {
    file: ?std.Io.File = null,
    io: std.Io = undefined,
    read_only: bool = true,

    pub const Cursor = struct {
        file: std.Io.File,
        io: std.Io,
        at: u32 = 0,
        pub fn seekTo(self: *Cursor, at: u32) !void {
            self.at = at;
        }

        pub fn read(self: *Cursor, output: []u8) !usize {
            const amount = try self.file.readPositionalAll(self.io, output, self.at);
            self.at += @intCast(amount);
            return amount;
        }

        pub fn write(self: *Cursor, bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.at);
            self.at += @intCast(bytes.len);
        }

        pub fn sync(self: *Cursor) !void {
            try self.file.sync(self.io);
        }
    };

    pub fn open(self: *File, root_path: ?[]const u8, io: std.Io, read_only: bool, name: []const u8, kind: gain.managed_file.Kind, size: u32, block: *[512]u8) bool {
        self.* = .{ .io = io, .read_only = read_only };
        const path = root_path orelse return false;
        const root = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
        defer root.close(io);
        const directory = root.openDir(io, ".gain", .{ .follow_symlinks = false }) catch return false;
        defer directory.close(io);
        const file = directory.openFile(io, name, .{ .mode = if (read_only) .read_only else .read_write, .follow_symlinks = false }) catch return false;
        var accepted = false;
        defer if (!accepted) file.close(io);
        const stat = file.stat(io) catch return false;
        if (stat.kind != .file or stat.size != size) return false;
        if ((file.readPositionalAll(io, block, 0) catch 0) != 512 or !gain.managed_file.valid(block, kind, size)) return false;
        accepted = true;
        self.file = file;
        return true;
    }

    pub fn cursor(self: File) ?Cursor {
        return .{ .file = self.file orelse return null, .io = self.io };
    }

    pub fn close(self: *File) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }
};
