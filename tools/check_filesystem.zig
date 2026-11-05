//! Inspect a raw image using the production filesystem reader. No write
//! capability is supplied, so this tool cannot alter the image or a device.
const std = @import("std");
const fs = @import("gain").storage.filesystem;
const Disk = struct {
    file: std.Io.File,
    io: std.Io,
    pub fn readBlocks(self: *Disk, lba: u32, output: []u8) !void {
        if (output.len % 512 != 0) return error.InvalidRead;
        if (try self.file.readPositionalAll(self.io, output, @as(u64, lba) * 512) != output.len) return error.Truncated;
    }
};
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return error.MissingImage;
    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var disk = Disk{ .file = file, .io = init.io };
    var scratch: [512]u8 = undefined;
    var volume = try fs.Volume(Disk).mount(&disk, &scratch);
    std.debug.print("{s}: serial {x}, cluster {d} bytes\n", .{ @tagName(volume.kind()), volume.serial, volume.sectors_per_cluster * 512 });
    if (args.next()) |name| {
        const entry = try volume.findPath(name);
        const selected = try entry.file();
        var reader = try volume.reader(selected);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [32768]u8 align(4) = undefined;
        while (true) {
            const count = try reader.read(&buffer);
            if (count == 0) break;
            hash.update(buffer[0..count]);
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        std.debug.print("{s}: {d} bytes, SHA256 {s}\n", .{ name, selected.size, std.fmt.bytesToHex(&digest, .lower) });
    } else {
        var iterator = try volume.iterate(volume.rootDirectory());
        while (try iterator.next()) |entry| std.debug.print("{s} {d} {s}\n", .{ @tagName(entry.kind), entry.size, entry.name() });
    }
}
