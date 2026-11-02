const std = @import("std");
const flac = @import("flac");

fn checkFile(comptime encoded: []const u8, comptime reference: []const u8, expected_depth: u6, coverage: ?*flac.Coverage) !void {
    const info = try flac.parseStreamInfo(encoded);
    try std.testing.expectEqual(expected_depth, info.bits_per_sample);
    var left: [65_535]i32 = undefined;
    var right: [65_535]i32 = undefined;
    var input_offset = info.first_frame_offset;
    var output_offset: usize = 0;
    var decoded_samples: u64 = 0;
    while (input_offset < encoded.len) {
        const frame = try flac.decodeFrameObserved(encoded[input_offset..], info, &left, &right, coverage);
        for (0..frame.block_size) |index| {
            if (output_offset + 8 > reference.len) return error.Truncated;
            const expected_left: i32 = @bitCast(std.mem.readInt(u32, reference[output_offset..][0..4], .little));
            const expected_right: i32 = @bitCast(std.mem.readInt(u32, reference[output_offset + 4 ..][0..4], .little));
            const scale: u5 = @intCast(32 - expected_depth);
            try std.testing.expectEqual(expected_left, left[index] << scale);
            try std.testing.expectEqual(expected_right, right[index] << scale);
            output_offset += 8;
        }
        input_offset += frame.bytes_consumed;
        decoded_samples += frame.block_size;
    }
    try std.testing.expectEqual(info.total_samples, decoded_samples);
    try std.testing.expectEqual(reference.len, output_offset);
}

test "decode generated 16-bit and 24-bit FLAC losslessly" {
    try checkFile(@embedFile("fixtures/flac-16.flac"), @embedFile("fixtures/flac-16.s32le"), 16, null);
    try checkFile(@embedFile("fixtures/flac-24.flac"), @embedFile("fixtures/flac-24.s32le"), 24, null);
}

test "decode every stereo decorrelation mode" {
    var coverage: flac.Coverage = .{};
    const reference = @embedFile("fixtures/flac-16.s32le");
    try checkFile(@embedFile("fixtures/flac-mode-independent.flac"), reference, 16, &coverage);
    try checkFile(@embedFile("fixtures/flac-mode-left-side.flac"), reference, 16, &coverage);
    try checkFile(@embedFile("fixtures/flac-mode-right-side.flac"), reference, 16, &coverage);
    try checkFile(@embedFile("fixtures/flac-mode-mid-side.flac"), reference, 16, &coverage);
    const expected = (@as(u16, 1) << 1) | (@as(u16, 1) << 8) |
        (@as(u16, 1) << 9) | (@as(u16, 1) << 10);
    try std.testing.expectEqual(expected, coverage.channel_modes & expected);
}

test "decode constant, predictor and wasted-bit streams" {
    var coverage: flac.Coverage = .{};
    try checkFile(@embedFile("fixtures/flac-constant.flac"), @embedFile("fixtures/flac-constant.s32le"), 16, &coverage);
    try checkFile(@embedFile("fixtures/flac-wasted.flac"), @embedFile("fixtures/flac-wasted.s32le"), 16, &coverage);
    try checkFile(@embedFile("fixtures/flac-noise-24.flac"), @embedFile("fixtures/flac-noise-24.s32le"), 24, &coverage);
    try std.testing.expect(coverage.subframe_types & 1 != 0);
    try std.testing.expect(coverage.subframe_types & 0xffff_ffff_ffff_ff00 != 0);
    try std.testing.expect(coverage.saw_wasted_bits);
}

test "reject damaged, truncated and undersized frames" {
    const source = @embedFile("fixtures/flac-16.flac");
    const info = try flac.parseStreamInfo(source);
    var left: [65_535]i32 = undefined;
    var right: [65_535]i32 = undefined;
    const frame = try flac.decodeFrame(source[info.first_frame_offset..], info, &left, &right);
    var damaged = source.*;
    damaged[info.first_frame_offset + frame.bytes_consumed - 1] ^= 1;
    try std.testing.expectError(
        error.InvalidFrameCrc,
        flac.decodeFrame(damaged[info.first_frame_offset..], info, &left, &right),
    );
    try std.testing.expectError(
        error.Truncated,
        flac.decodeFrame(source[info.first_frame_offset .. info.first_frame_offset + 8], info, &left, &right),
    );
    try std.testing.expectError(
        error.OutputTooSmall,
        flac.decodeFrame(source[info.first_frame_offset..], info, left[0..100], right[0..100]),
    );
}

test "FLAC parser and frame decoder remain bounded on arbitrary input" {
    try std.testing.fuzz({}, fuzzFlac, .{ .corpus = &.{
        "",
        "fLaC",
        "\xff\xf8\x00\x00\x00\x00\x00\x00",
    } });
}

fn fuzzFlac(_: void, smith: *std.testing.Smith) !void {
    var input: [4_096]u8 = undefined;
    const length = smith.slice(&input);
    const bytes = input[0..length];
    _ = flac.parseStreamInfo(bytes) catch {};

    const info = flac.StreamInfo{
        .minimum_block_size = 16,
        .maximum_block_size = 1_024,
        .minimum_frame_size = 0,
        .maximum_frame_size = 0,
        .sample_rate = 48_000,
        .channels = 2,
        .bits_per_sample = 24,
        .total_samples = 0,
        .first_frame_offset = 0,
    };

    var left: [1_024]i32 = undefined;
    var right: [1_024]i32 = undefined;
    _ = flac.decodeFrame(bytes, info, &left, &right) catch {};
}
