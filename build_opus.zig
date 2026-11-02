const std = @import("std");

pub fn add(b: *std.Build, module: *std.Build.Module, fixed: bool, native: bool, res24: bool) void {
    const root = "vendor/opus/";
    for ([_][]const u8{ "include", "celt", "silk", "silk/float", "silk/fixed", "src", "dnn", "." }) |dir| module.addIncludePath(b.path(b.fmt("{s}{s}", .{
        root,
        dir,
    })));
    if (native) module.addIncludePath(b.path("src/codecs/include/native"));
    module.addCMacro("OPUS_BUILD", "1");
    module.addCMacro("VAR_ARRAYS", "1");
    module.addCMacro("HAVE_LRINTF", "1");
    module.addCMacro("HAVE_LRINT", "1");
    module.addCMacro("PACKAGE_VERSION", "\"1.6.1\"");
    if (fixed) module.addCMacro("FIXED_POINT", "1");
    if (fixed and res24) module.addCMacro("ENABLE_RES24", "1");
    module.sanitize_c = .off;
    const lists = [_][2][]const u8{ .{
        "celt_sources.mk",
        "CELT_SOURCES",
    }, .{
        "silk_sources.mk",
        "SILK_SOURCES",
    }, .{
        "silk_sources.mk",
        if (fixed) "SILK_SOURCES_FIXED" else "SILK_SOURCES_FLOAT",
    }, .{ "opus_sources.mk", "OPUS_SOURCES" }, .{ "opus_sources.mk", "OPUS_SOURCES_FLOAT" } };
    for (lists) |list| {
        const file = b.path(b.fmt("{s}{s}", .{ root, list[0] }));
        b.dependOnFileContents(file);
        const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, (b.root.joinString(b.allocator, b.fmt("{s}{s}", .{
            root,
            list[0],
        })) catch @panic("path")), b.allocator, .limited(1 << 20)) catch @panic("read source list");
        var files: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var selected = false;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!selected) {
                if (std.mem.startsWith(u8, line, list[1]) and std.mem.endsWith(u8, std.mem.trimEnd(u8, line[list[1].len..], " \\"), "=")) selected = true;
                continue;
            }
            const name = std.mem.trim(u8, std.mem.trimEnd(u8, line, "\\"), " \t");
            if (name.len > 0) files.append(b.allocator, b.dupe(name)) catch @panic("oom");
            if (!std.mem.endsWith(u8, line, "\\")) break;
        }
        if (files.items.len == 0) @panic("empty source list");
        module.addCSourceFiles(.{
            .root = b.path(root),
            .files = files.items,
            .flags = &.{
                "-std=gnu99",
                "-U__mips",
                "-ffunction-sections",
                "-fdata-sections",
                "-ffp-contract=off",
                "-fwrapv",
                "-fno-sanitize-coverage=trace-cmp,trace-pc-guard,inline-8bit-counters,pc-table",
            },
        });
    }
}
