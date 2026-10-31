const std = @import("std");
fn base(b: *std.Build, m: *std.Build.Module, native: bool) void {
    for ([_][]const u8{ "malloc", "calloc", "realloc", "free" }) |name| m.addCMacro(name, b.fmt("gain_codec_{s}", .{name}));
    m.addIncludePath(b.path("src/codecs/include"));
    m.sanitize_c = .off;
    m.addCMacro("HAVE_ALLOCA_H", "1");
    m.addCMacro("HAVE_LRINTF", "1");
    if (native) {
        m.addCMacro("NDEBUG", "1");
        m.addIncludePath(b.path("src/codecs/include/native"));
    }
}
pub fn add(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native: bool) void {
    base(b, m, native);
    // Translate the upstream public headers into Zig declarations. No local C
    // translation unit or handwritten duplicate ABI declarations are needed.
    inline for (.{
        .{ "c_faad", "vendor/faad2/include/neaacdec.h" },
        .{ "c_vorbis", "vendor/vorbis/include/vorbis/codec.h" },
        .{ "c_opus", "vendor/opus/include/opus.h" },
        .{ "c_alac_types", "vendor/alac/codec/ALACAudioTypes.h" },
        .{ "c_alac_bits", "vendor/alac/codec/ALACBitUtilities.h" },
        .{ "c_mp3", "vendor/minimp3/minimp3.h" },
    }) |header| {
        const declarations = b.addTranslateC(.{ .root_source_file = b.path(header[1]), .target = target, .optimize = optimize, .link_libc = !native });
        declarations.addIncludePath(b.path("src/codecs/include"));
        declarations.addIncludePath(b.path("vendor/ogg/include"));
        if (native) declarations.addIncludePath(b.path("src/codecs/include/native"));
        if (std.mem.eql(u8, header[0], "c_mp3")) declarations.defineCMacro("MINIMP3_FLOAT_OUTPUT", "1");
        m.addImport(header[0], declarations.createModule());
    }
    m.addImport("mpeg_metadata", b.createModule(.{ .root_source_file = b.path("vendor/mpeg-metadata/root.zig"), .target = target, .optimize = optimize }));
    for ([_][]const u8{ "vendor/faad2/include", "vendor/alac/codec", "vendor/vorbis/include", "vendor/ogg/include", "vendor/opus/include" }) |path| m.addIncludePath(b.path(path));
    const flags: *const [6][]const u8 = &.{ "-std=gnu99", "-ffunction-sections", "-fdata-sections", "-ffp-contract=off", "-fwrapv", "-fno-sanitize-coverage=trace-cmp,trace-pc-guard,inline-8bit-counters,pc-table" };
    const faad = [_][]const u8{ "bits.c", "cfft.c", "common.c", "decoder.c", "drc.c", "drm_dec.c", "error.c", "filtbank.c", "hcr.c", "huffman.c", "ic_predict.c", "is.c", "lt_predict.c", "mdct.c", "mp4.c", "ms.c", "output.c", "pns.c", "ps_dec.c", "ps_syntax.c", "pulse.c", "rvlc.c", "sbr_dct.c", "sbr_dec.c", "sbr_e_nf.c", "sbr_fbt.c", "sbr_hfadj.c", "sbr_hfgen.c", "sbr_huff.c", "sbr_qmf.c", "sbr_syntax.c", "sbr_tf_grid.c", "specrec.c", "ssr.c", "ssr_fb.c", "ssr_ipqf.c", "syntax.c", "tns.c" };
    const f = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = !native });
    base(b, f, native);
    f.addIncludePath(b.path("vendor/faad2/include"));
    f.addIncludePath(b.path("vendor/faad2/libfaad"));
    f.addCMacro("HAVE_INTTYPES_H", "1");
    f.addCMacro("HAVE_STDINT_H", "1");
    f.addCMacro("HAVE_STRING_H", "1");
    f.addCMacro("PACKAGE_VERSION", "\"2.11.4\"");
    f.addCSourceFiles(.{ .root = b.path("vendor/faad2/libfaad"), .files = &faad, .flags = flags });
    m.linkLibrary(b.addLibrary(.{ .name = "gain-faad", .linkage = .static, .root_module = f }));
    const v = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = !native });
    base(b, v, native);
    for ([_][]const u8{ "vendor/vorbis/include", "vendor/vorbis/lib", "vendor/ogg/include" }) |path| v.addIncludePath(b.path(path));
    const vorbis = [_][]const u8{ "mdct.c", "smallft.c", "block.c", "envelope.c", "window.c", "lsp.c", "lpc.c", "analysis.c", "synthesis.c", "psy.c", "info.c", "floor1.c", "floor0.c", "res0.c", "mapping0.c", "registry.c", "codebook.c", "sharedbook.c", "lookup.c", "bitrate.c" };
    v.addCSourceFiles(.{ .root = b.path("vendor/vorbis/lib"), .files = &vorbis, .flags = flags });
    v.addCSourceFiles(.{ .root = b.path("vendor/ogg/src"), .files = &.{ "bitwise.c", "framing.c" }, .flags = flags });
    m.linkLibrary(b.addLibrary(.{ .name = "gain-vorbis", .linkage = .static, .root_module = v }));
    const a = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = !native });
    base(b, a, native);
    a.addCMacro("TARGET_RT_LITTLE_ENDIAN", "1");
    a.addIncludePath(b.path("vendor/alac/codec"));
    a.addCSourceFiles(.{ .root = b.path("vendor/alac/codec"), .files = &.{ "ALACBitUtilities.c", "EndianPortable.c", "ag_dec.c", "matrix_dec.c" }, .flags = flags });
    a.addCSourceFile(.{ .file = b.path("vendor/alac/codec/dp_dec.c"), .flags = flags ++ [_][]const u8{"-Dunpc_block=gain_upstream_unpc_block"} });
    const cpp = &.{ "-std=c++11", "-fno-exceptions", "-fno-rtti", "-ffunction-sections", "-fdata-sections", "-fwrapv", "-fno-sanitize-coverage=trace-cmp,trace-pc-guard,inline-8bit-counters,pc-table" };
    a.addCSourceFile(.{ .file = b.path("vendor/alac/codec/ALACDecoder.cpp"), .flags = cpp });
    m.linkLibrary(b.addLibrary(.{ .name = "gain-alac", .linkage = .static, .root_module = a }));
    m.addIncludePath(b.path("vendor/minimp3"));
    m.addCMacro("MINIMP3_FLOAT_OUTPUT", "1");
    // Compile an unchanged copy of the upstream implementation header as C.
    const mp3_implementation = b.addWriteFiles().addCopyFile(b.path("vendor/minimp3/minimp3.h"), "minimp3.c");
    m.addCSourceFile(.{ .file = mp3_implementation, .flags = flags ++ [_][]const u8{ "-DMINIMP3_IMPLEMENTATION", "-DMINIMP3_NO_SIMD" } });
    const o = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = !native });
    base(b, o, native);
    @import("build_opus.zig").add(b, o, false, native, false);
    m.linkLibrary(b.addLibrary(.{ .name = "gain-opus", .linkage = .static, .root_module = o }));
}
