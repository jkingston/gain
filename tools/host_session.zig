//! Desktop adapter for the same owned session journal used on the F20. The
//! simulator host stays app-agnostic; only the player app accesses this file.
const std = @import("std");
const gain = @import("gain_ui");
const session = gain.listening_session;

pub const Store = struct {
    file: ?std.Io.File = null,
    io: std.Io = undefined,
    journal: session.Journal = .{},
    membership_key: ?u64 = null,
    disabled: bool = false,
    read_only: bool = false,
    block: [512]u8 align(4) = undefined,
    scratch: [session.scratch_bytes]u8 = undefined,

    const Cursor = struct {
        file: std.Io.File,
        io: std.Io,
        at: u32 = 0,

        pub fn seekTo(self: *Cursor, at: u32) !void {
            self.at = at;
        }

        pub fn read(self: *Cursor, bytes: []u8) !usize {
            const count = try self.file.readPositionalAll(self.io, bytes, self.at);
            self.at += @intCast(count);
            return count;
        }

        pub fn write(self: *Cursor, bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.at);
            self.at += @intCast(bytes.len);
        }

        pub fn sync(self: *Cursor) !void {
            try self.file.sync(self.io);
        }
    };

    pub fn load(self: *Store, root_path: ?[]const u8, io: std.Io, source: u64, read_only: bool) ?session.Record {
        self.* = .{ .io = io, .read_only = read_only };
        const path = root_path orelse return null;
        const root = std.Io.Dir.cwd().openDir(io, path, .{}) catch return null;
        defer root.close(io);
        const directory = root.openDir(io, ".gain", .{ .follow_symlinks = false }) catch return null;
        defer directory.close(io);
        const file = directory.openFile(io, "session.bin", .{ .mode = if (read_only) .read_only else .read_write, .follow_symlinks = false }) catch return null;
        var accepted = false;
        defer if (!accepted) file.close(io);
        const stat = file.stat(io) catch return null;
        if (stat.kind != .file or stat.size != session.allocation_bytes) return null;
        if ((file.readPositionalAll(io, &self.block, 0) catch 0) != 512 or !gain.managed_file.valid(&self.block, .session, @intCast(stat.size))) return null;
        self.file = file;
        accepted = true;
        var cursor = Cursor{ .file = file, .io = io };
        const record = (self.journal.load(&cursor, source, &self.scratch, &self.block) catch return null) orelse return null;
        self.membership_key = session.membershipKey(record.data);
        return record;
    }

    pub fn save(self: *Store, queue: anytype, source: u64, position: session.Position, navigation: session.Navigation) void {
        if (self.disabled or self.read_only) return;
        const file = self.file orelse return;
        const data = session.capture(queue, source, position, navigation, &self.scratch) catch {
            self.disabled = true;
            return;
        };
        const key = session.membershipKey(data);
        var cursor = Cursor{ .file = file, .io = self.io };
        if (self.membership_key == null or self.membership_key.? != key) {
            self.journal.saveQueue(&cursor, data, &self.block) catch {
                self.disabled = true;
                return;
            };
            self.membership_key = key;
        } else self.journal.savePosition(&cursor, data, position, &self.block) catch {
            self.disabled = true;
        };
    }

    pub fn close(self: *Store) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }
};
