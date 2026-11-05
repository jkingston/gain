//! Desktop adapter for the same owned, provisioned journal as the device.
//! Unprovisioned roots remain read-only; neither directories nor files are made.
const std = @import("std");
const gain = @import("gain_ui");

pub const Store = struct {
    file: ?std.Io.File = null,
    io: std.Io = undefined,
    journal: gain.preferences.Journal = .{},
    disabled: bool = false,
    read_only: bool = false,
    block: [512]u8 align(4) = undefined,

    const Cursor = struct {
        file: std.Io.File,
        io: std.Io,
        at: u32 = 0,
        pub fn seekTo(self: *Cursor, at: u32) !void {
            self.at = at;
        }
        pub fn read(self: *Cursor, bytes: []u8) !usize {
            const n = try self.file.readPositionalAll(self.io, bytes, self.at);
            self.at += @intCast(n);
            return n;
        }
        pub fn write(self: *Cursor, bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.at);
        }
        pub fn sync(self: *Cursor) !void {
            try self.file.sync(self.io);
        }
    };

    pub fn load(self: *Store, root_path: ?[]const u8, io: std.Io, read_only: bool) gain.preferences.Options {
        self.* = .{ .io = io, .read_only = read_only };
        const path = root_path orelse return .{};
        const root = std.Io.Dir.cwd().openDir(io, path, .{}) catch return .{};
        defer root.close(io);
        const directory = root.openDir(io, ".gain", .{ .follow_symlinks = false }) catch return .{};
        defer directory.close(io);
        const file = directory.openFile(io, "settings.bin", .{ .mode = if (read_only) .read_only else .read_write, .follow_symlinks = false }) catch return .{};
        var accepted = false;
        defer if (!accepted) file.close(io);
        const stat = file.stat(io) catch return .{};
        if (stat.kind != .file or stat.size != gain.preferences.allocation_bytes) return .{};
        if ((file.readPositionalAll(io, &self.block, 0) catch 0) != 512 or !gain.managed_file.valid(&self.block, .settings, @intCast(stat.size))) return .{};
        var cursor = Cursor{ .file = file, .io = io };
        const options = self.journal.load(&cursor, &self.block) catch return .{};
        self.file = file;
        accepted = true;
        return options;
    }

    pub fn save(self: *Store, options: gain.preferences.Options) void {
        if (self.disabled or self.read_only) return;
        const file = self.file orelse return;
        var cursor = Cursor{ .file = file, .io = self.io };
        self.journal.save(&cursor, options, &self.block) catch {
            self.disabled = true;
        };
    }

    pub fn close(self: *Store) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }
};
