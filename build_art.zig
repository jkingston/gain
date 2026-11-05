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
    } else &.{ "-std=c99", "-fno-sanitize=shift-base", "-fno-sanitize-coverage=trace-cmp,trace-pc-guard,inline-8bit-counters,pc-table" };
    module.addCSourceFile(.{ .file = b.path("vendor/picojpeg/picojpeg.c"), .flags = flags });
    if (native) module.addIncludePath(b.path("src/codecs/include/native"));

    const png_target = if (native) b.resolveTargetQuery(.{
        .cpu_arch = .mipsel,
        .os_tag = .linux,
        .abi = .musleabihf,
        .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips32r2 },
    }) else target;
    const png = if (native) b.createModule(.{ .target = png_target, .optimize = optimize, .link_libc = true }) else module;
    const png_api = b.addTranslateC(.{ .root_source_file = b.path("vendor/spng/spng.h"), .target = target, .optimize = optimize, .link_libc = !native });
    if (native) for ([_][]const u8{ "libc/include/mips-linux-musl", "libc/include/generic-musl", "libc/include/mips-linux-any", "libc/include/any-linux-any" }) |path| {
        png_api.addIncludePath(std.Build.LazyPath.zig_lib.path(b, path));
    };
    module.addImport("c_spng", png_api.createModule());
    png.addIncludePath(b.path("vendor/spng"));
    png.addIncludePath(b.path("vendor/zlib"));
    // Zig's Smith runner does not supply Clang's coverage runtime. C still runs
    // under the host's ordinary safety checks; mutation guidance comes from Zig.
    const png_common = &[_][]const u8{ "-Os", "-std=c99", "-ffunction-sections", "-fdata-sections", "-DSPNG_STATIC", "-DNO_GZIP", "-fno-sanitize-coverage=trace-cmp,trace-pc-guard,inline-8bit-counters,pc-table" };
    const png_native = png_common ++ &[_][]const u8{ "-mno-abicalls", "-fno-pic", "-Dmalloc=gain_art_malloc", "-Dcalloc=gain_art_calloc", "-Drealloc=gain_art_realloc", "-Dfree=gain_art_free" };
    const png_flags = if (native) png_native else png_common;
    const zlib_flags = if (native) png_native ++ &[_][]const u8{"-DZ_SOLO"} else png_common ++ &[_][]const u8{"-DZ_SOLO"};
    if (native) png.addCMacro("SPNG_DISABLE_OPT", "1");
    png.addCSourceFile(.{ .file = b.path("vendor/spng/spng.c"), .flags = png_flags });
    png.addCSourceFile(.{ .file = b.path("vendor/zlib/compress.c"), .flags = png_flags });
    png.addCSourceFiles(.{ .root = b.path("vendor/zlib"), .files = &.{ "adler32.c", "crc32.c", "deflate.c", "inffast.c", "inflate.c", "inftrees.c", "trees.c", "zutil.c" }, .flags = zlib_flags });
    if (native) {
        const upstream = b.addObject(.{ .name = "gain-png-upstream", .root_module = png });
        module.addObjectFile(upstream.getEmittedBin());
    }
}
