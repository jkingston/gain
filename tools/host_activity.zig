//! Player-app adapter for the firmware's bounded activity journal.
const std = @import("std");
const gain = @import("gain_ui");
const activity = gain.listening_activity;

pub const Store = struct {
    file: ?std.Io.File = null,
    io: std.Io = undefined,
    journal: activity.Journal = .{},
    saved_revision: ?u32 = null,
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

    pub fn load(self: *Store, root_path: ?[]const u8, io: std.Io, read_only: bool, state: *activity.State, scratch: []u8) void {
        self.* = .{ .io = io, .read_only = read_only };
        const path = root_path orelse return;
        const root = std.Io.Dir.cwd().openDir(io, path, .{}) catch return;
        defer root.close(io);
        const directory = root.openDir(io, ".gain", .{ .follow_symlinks = false }) catch return;
        defer directory.close(io);
        const file = directory.openFile(io, "activity.bin", .{ .mode = if (read_only) .read_only else .read_write, .follow_symlinks = false }) catch return;
        var accepted = false;
        defer if (!accepted) file.close(io);
        const stat = file.stat(io) catch return;
        if (stat.kind != .file or stat.size != activity.allocation_bytes) return;
        if ((file.readPositionalAll(io, &self.block, 0) catch 0) != 512 or !gain.managed_file.valid(&self.block, .activity, @intCast(stat.size))) return;
        accepted = true;
        self.file = file;
        var cursor = Cursor{ .file = file, .io = io };
        const payload = (self.journal.load(&cursor, state.source, scratch, &self.block, activity.State) catch return) orelse return;
        state.load(payload) catch return;
        self.saved_revision = state.revision;
    }

    pub fn save(self: *Store, state: *const activity.State, scratch: []u8) void {
        if (self.disabled or self.read_only or self.saved_revision == state.revision) return;
        const file = self.file orelse return;
        const revision = state.revision;
        const payload = state.capture(scratch) catch {
            self.disabled = true;
            return;
        };
        var cursor = Cursor{ .file = file, .io = self.io };
        self.journal.save(&cursor, state.source, payload, &self.block) catch {
            self.disabled = true;
            return;
        };
        self.saved_revision = revision;
    }

    pub fn close(self: *Store) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }
};
