const std = @import("std");

/// The same upstream engines and Zig bridge back both host and F20 rendering.
/// Native code is a separate fixed-address SD component, never part of stage 2.
pub fn add(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const native = target.result.cpu.arch == .mipsel;
    // The intermediate object uses the compiler's bundled C/C++ headers.
    // Only its emitted object reaches the freestanding link: no hosted libc,
    // libc++ runtime, startup or constructors can propagate with it.
    const upstream = if (native) b.createModule(.{
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .mipsel,
            .os_tag = .linux,
            .abi = .musleabihf,
            .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips32r2 },
        }),
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    }) else module;
    const generated = b.addWriteFiles();
    _ = generated.add("gain-ft-modules.h",
        \\FT_USE_MODULE(FT_Driver_ClassRec, tt_driver_class)
        \\FT_USE_MODULE(FT_Module_Class, sfnt_module_class)
        \\FT_USE_MODULE(FT_Renderer_Class, ft_smooth_renderer_class)
        \\
    );
    const header = generated.add("gain-text.h",
        \\#include <hb.h>
        \\#include <hb-ft.h>
        \\#include <ft2build.h>
        \\#include FT_FREETYPE_H
        \\#include FT_MODULE_H
        \\#include <SheenBidi/SheenBidi.h>
        \\#include <utf8proc.h>
        \\
    );
    const includes = [_][]const u8{ "vendor/harfbuzz/src", "vendor/freetype/include", "vendor/sheen/Headers", "vendor/sheen/Source", "vendor/utf8proc" };
    const translated = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize, .link_libc = !native });
    for (includes) |path| {
        upstream.addIncludePath(b.path(path));
        translated.addIncludePath(b.path(path));
    }
    if (target.result.cpu.arch == .mipsel) {
        translated.link_libc = false;
        for ([_][]const u8{ "libc/include/mips-linux-musl", "libc/include/generic-musl", "libc/include/mips-linux-any", "libc/include/any-linux-any" }) |path| {
            const include = std.Build.LazyPath.zig_lib.path(b, path);
            translated.addIncludePath(include);
            upstream.addIncludePath(include);
        }
    }
    module.addImport("text_c", translated.createModule());
    upstream.addIncludePath(generated.getDirectory());
    upstream.addCMacro("FT_CONFIG_MODULES_H", "\"gain-ft-modules.h\"");
    upstream.addCMacro("FT2_BUILD_LIBRARY", "1");
    upstream.addCMacro("SB_CONFIG_UNITY", "1");
    upstream.addCMacro("SB_CONFIG_DISABLE_SCRATCH_MEMORY", "1");
    upstream.addCMacro("SB_CONFIG_ALLOW_NON_ATOMIC_FALLBACK", "1");
    upstream.addCMacro("UTF8PROC_STATIC", "1");
    upstream.addCMacro("HB_TINY", "1");
    upstream.addCMacro("HAVE_FREETYPE", "1");
    for ([_][]const u8{ "malloc", "calloc", "realloc", "free" }) |name| {
        upstream.addCMacro(b.fmt("hb_{s}_impl", .{name}), b.fmt("gain_text_{s}", .{name}));
    }
    upstream.addCMacro("strdup", "gain_text_strdup");
    upstream.addCMacro("getenv", "gain_text_getenv");
    const common: []const []const u8 = &.{ "-Os", "-ffunction-sections", "-fdata-sections", "-fvisibility=hidden", "-DNDEBUG", "-fno-sanitize=undefined" };
    var cpp: std.ArrayList([]const u8) = .empty;
    cpp.appendSlice(b.allocator, common) catch @panic("oom");
    cpp.appendSlice(b.allocator, &.{ "-std=c++11", "-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics" }) catch @panic("oom");
    upstream.addCSourceFile(.{ .file = b.path("vendor/harfbuzz/src/harfbuzz.cc"), .flags = cpp.items });
    // Default FT system allocation/file access is deliberately not compiled.
    // FT_New_Library receives the Zig pool and each FT face receives a stream.
    upstream.addCSourceFiles(.{ .root = b.path("vendor/freetype/src"), .files = &.{ "base/ftbase.c", "base/ftinit.c", "base/ftdebug.c", "base/ftbitmap.c", "base/ftmm.c", "gzip/ftgzip.c", "sfnt/sfnt.c", "truetype/truetype.c", "smooth/smooth.c" }, .flags = common });
    const bounded: []const []const u8 = &.{ "-Os", "-ffunction-sections", "-fdata-sections", "-fvisibility=hidden", "-DNDEBUG", "-Dmalloc=gain_text_malloc", "-Dcalloc=gain_text_calloc", "-Drealloc=gain_text_realloc", "-Dfree=gain_text_free" };
    upstream.addCSourceFile(.{ .file = b.path("vendor/sheen/Source/SheenBidi.c"), .flags = bounded });
    upstream.addCSourceFile(.{ .file = b.path("vendor/utf8proc/utf8proc.c"), .flags = bounded });
    if (native) {
        module.addAssemblyFile(std.Build.LazyPath.zig_lib.path(b, "libc/musl/src/setjmp/mips/setjmp.S"));
        module.addAssemblyFile(std.Build.LazyPath.zig_lib.path(b, "libc/musl/src/setjmp/mips/longjmp.S"));
        const object = b.addObject(.{ .name = "gain-text-upstream", .root_module = upstream });
        module.addObjectFile(object.getEmittedBin());
    }
}
