const std = @import("std");

pub fn add(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    module.addImport("mpeg_metadata", b.createModule(.{ .root_source_file = b.path("vendor/mpeg-metadata/root.zig"), .target = target, .optimize = optimize }));
}
