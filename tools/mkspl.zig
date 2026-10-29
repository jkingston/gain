const std = @import("std");

const header_size = 2048;
const max_code_size = 10 * 1024;

fn tableEntry(index: u8) u8 {
    var value = index;
    var bit: u4 = 0;
    while (bit < 8) : (bit += 1) {
        value = if (value & 0x80 != 0) (value << 1) ^ 0x12 else value << 1;
    }
    return value >> 1;
}

fn crc7(bytes: []const u8) u8 {
    var crc: u8 = 0;
    for (bytes) |byte| crc = tableEntry((crc << 1) ^ byte);
    return crc;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const input_path = args.next() orelse return error.MissingInput;
    const output_path = args.next() orelse return error.MissingOutput;
    if (args.next() != null) return error.TooManyArguments;

    const input = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        input_path,
        init.gpa,
        .limited(max_code_size + 1),
    );
    defer init.gpa.free(input);
    if (input.len == 0) return error.EmptyInput;
    if (input.len > max_code_size) return error.InputTooLarge;

    var header: [header_size]u8 = @splat(0);
    const magic = [_]u8{ 0x06, 0x05, 0x04, 0x03, 0x02, 0x55, 0xaa, 0x55 };
    @memcpy(header[0..magic.len], &magic);
    header[8] = 0x00;
    header[9] = crc7(input);
    header[10] = 0x02;
    header[11] = 0x02;
    std.mem.writeInt(u32, header[12..16], @intCast(header_size + input.len), .little);

    const image = try init.gpa.alloc(u8, header_size + input.len);
    defer init.gpa.free(image);
    @memcpy(image[0..header_size], &header);
    @memcpy(image[header_size..], input);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = image });
}

test "CRC matches the established X1000 SPL" {
    try std.testing.expectEqual(@as(u8, 0x09), crc7(&.{0x01}));
    try std.testing.expectEqual(@as(u8, 0x12), crc7(&.{0x02}));
}
