const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .mipsel,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips32r2 },
    });
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    const spl_module = b.createModule(.{
        .root_source_file = b.path("src/spl.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    spl_module.addAssemblyFile(b.path("src/spl_start.S"));
    const spl = b.addExecutable(.{ .name = "gain-spl.elf", .root_module = spl_module });
    spl.entry = .disabled;
    spl.setLinkerScript(b.path("spl.ld"));
    const spl_raw = spl.addObjCopy(.{ .format = .binary, .basename = "gain-spl.raw" });

    const packer_module = b.createModule(.{
        .root_source_file = b.path("tools/mkspl.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const packer = b.addExecutable(.{ .name = "mkspl", .root_module = packer_module });
    const pack = b.addRunArtifact(packer);
    pack.addFileArg(spl_raw.getOutput());
    const spl_image = pack.addOutputFileArg("gain-spl.bin");

    const stage2_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    stage2_module.addAssemblyFile(b.path("src/start.S"));
    const stage2 = b.addExecutable(.{ .name = "gain-stage2.elf", .root_module = stage2_module });
    stage2.entry = .disabled;
    stage2.setLinkerScript(b.path("stage2.ld"));
    const stage2_raw = stage2.addObjCopy(.{ .format = .binary, .basename = "gain-stage2.bin" });

    b.installArtifact(spl);
    b.installArtifact(stage2);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(spl_raw.getOutput(), .bin, "gain-spl.raw").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(spl_image, .bin, "gain-spl.bin").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(stage2_raw.getOutput(), .bin, "gain-stage2.bin").step);

    const packer_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/mkspl.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const hardware_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/f20_v27.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const playback_module = b.createModule(.{
        .root_source_file = b.path("src/playback.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const playback_sim_module = b.createModule(.{
        .root_source_file = b.path("tests/playback_sim.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    playback_sim_module.addImport("playback", playback_module);
    const playback_sim_tests = b.addTest(.{ .root_module = playback_sim_module });
    const test_step = b.step("test", "Run host-side tests");
    test_step.dependOn(&b.addRunArtifact(packer_tests).step);
    test_step.dependOn(&b.addRunArtifact(hardware_tests).step);
    test_step.dependOn(&b.addRunArtifact(playback_sim_tests).step);
}
