const std = @import("std");

pub fn add(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native: bool) void {
    const api = b.addTranslateC(.{
        .root_source_file = b.path("vendor/picojpeg/picojpeg.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = !native,
    });
    module.addImport("c_jpeg", api.createModule());
    // Upstream Huffman sign extension shifts negative integers. Suppress only
    // that C diagnostic; Zig safety and the other C checks remain enabled.
    const flags: []const []const u8 = if (native) &.{
        "-std=c99",
        "-fno-builtin",
        "-mno-abicalls",
        "-fno-pic",
    } else &.{ "-std=c99", "-fno-sanitize=shift-base" };
    module.addCSourceFile(.{ .file = b.path("vendor/picojpeg/picojpeg.c"), .flags = flags });
    if (native) module.addIncludePath(b.path("src/codecs/include/native"));
}
