const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .mipsel,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips32r2 },
    });
    const spl_optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    const spl_module = b.createModule(.{
        .root_source_file = b.path("src/spl.zig"),
        .target = target,
        .optimize = spl_optimize,
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
        .optimize = .ReleaseFast,
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

    const benchmark_flac_module = b.createModule(.{
        .root_source_file = b.path("tests/bench_flac.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const benchmark_f20 = b.createModule(.{
        .root_source_file = b.path("src/f20.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    benchmark_flac_module.addImport("f20", benchmark_f20);
    const benchmark_flac = b.addExecutable(.{
        .name = "bench-flac",
        .root_module = benchmark_flac_module,
    });
    const benchmark_step = b.step("bench", "Run host-side FLAC performance benchmarks");
    benchmark_step.dependOn(&b.addRunArtifact(benchmark_flac).step);

    const f20_benchmark_module = b.createModule(.{
        .root_source_file = b.path("tools/bench_f20.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .strip = true,
    });
    f20_benchmark_module.addAssemblyFile(b.path("tools/bench_start.S"));
    f20_benchmark_module.addImport("f20", b.createModule(.{
        .root_source_file = b.path("src/f20.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));
    const f20_benchmark = b.addExecutable(.{
        .name = "gain-f20-bench.elf",
        .root_module = f20_benchmark_module,
    });
    f20_benchmark.entry = .disabled;
    f20_benchmark.setLinkerScript(b.path("tools/bench_f20.ld"));
    const f20_benchmark_raw = f20_benchmark.addObjCopy(.{
        .format = .binary,
        .basename = "gain-f20-bench.bin",
    });
    const f20_benchmark_step = b.step("bench-f20", "Build the RAM-only F20 performance benchmark");
    f20_benchmark_step.dependOn(&b.addInstallFileWithDir(
        spl_image,
        .bin,
        "gain-spl.bin",
    ).step);
    f20_benchmark_step.dependOn(&b.addInstallFileWithDir(
        f20_benchmark_raw.getOutput(),
        .bin,
        "gain-f20-bench.bin",
    ).step);

    const report_reader_module = b.createModule(.{
        .root_source_file = b.path("tools/read_f20_bench.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const report_reader = b.addExecutable(.{
        .name = "read-f20-bench",
        .root_module = report_reader_module,
    });
    const report_reader_run = b.addRunArtifact(report_reader);
    if (b.option([]const u8, "report", "Path to an uploaded F20 benchmark report")) |path| {
        report_reader_run.addArg(path);
    }
    const report_reader_step = b.step("read-f20-bench", "Print one F20 benchmark report");
    report_reader_step.dependOn(&report_reader_run.step);

    const benchmark_report_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/f20_bench_report.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });

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
    const sd_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/sd.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const audio_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const f20_audio_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/f20_audio.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const f20_media_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/f20_media.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const flac_module = b.createModule(.{
        .root_source_file = b.path("src/flac.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const flac_unit_tests = b.addTest(.{ .root_module = flac_module });
    const flac_lpc_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/flac_lpc.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const flac_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/flac_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    flac_tests_module.addImport("flac", flac_module);
    const flac_tests = b.addTest(.{ .root_module = flac_tests_module });
    const f20_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/f20.zig"),
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
    playback_sim_module.addImport("playback_controls", b.createModule(.{
        .root_source_file = b.path("src/playback_controls.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }));
    const playback_sim_tests = b.addTest(.{ .root_module = playback_sim_module });
    const playback_control_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/playback_controls.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const display_transfer_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/display_transfer.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const lcd_dma_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/lcd_dma.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const fat32_module = b.createModule(.{
        .root_source_file = b.path("src/fat32.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const wav_module = b.createModule(.{
        .root_source_file = b.path("src/wav.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const storage_sim_module = b.createModule(.{
        .root_source_file = b.path("tests/storage_sim.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    storage_sim_module.addImport("fat32", fat32_module);
    storage_sim_module.addImport("wav", wav_module);
    const storage_sim_tests = b.addTest(.{ .root_module = storage_sim_module });
    const f20_module = b.createModule(.{
        .root_source_file = b.path("src/f20.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const media_pipeline_sim_module = b.createModule(.{
        .root_source_file = b.path("tests/media_pipeline_sim.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    media_pipeline_sim_module.addImport("f20", f20_module);
    const media_pipeline_sim_tests = b.addTest(.{ .root_module = media_pipeline_sim_module });
    const flac_sim_module = b.createModule(.{
        .root_source_file = b.path("tests/flac_sim.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    flac_sim_module.addImport("flac", flac_module);
    flac_sim_module.addImport("playback", playback_module);
    const flac_sim_tests = b.addTest(.{ .root_module = flac_sim_module });
    const flac_pipeline_sim_module = b.createModule(.{
        .root_source_file = b.path("tests/flac_pipeline_sim.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    flac_pipeline_sim_module.addImport("f20", f20_module);
    const flac_pipeline_sim_tests = b.addTest(.{ .root_module = flac_pipeline_sim_module });
    const test_step = b.step("test", "Run host-side tests");
    test_step.dependOn(&b.addRunArtifact(packer_tests).step);
    test_step.dependOn(&b.addRunArtifact(hardware_tests).step);
    test_step.dependOn(&b.addRunArtifact(sd_tests).step);
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);
    test_step.dependOn(&b.addRunArtifact(f20_audio_tests).step);
    test_step.dependOn(&b.addRunArtifact(f20_media_tests).step);
    test_step.dependOn(&b.addRunArtifact(flac_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(flac_lpc_tests).step);
    test_step.dependOn(&b.addRunArtifact(benchmark_report_tests).step);
    test_step.dependOn(&b.addRunArtifact(flac_tests).step);
    test_step.dependOn(&b.addRunArtifact(f20_tests).step);
    test_step.dependOn(&b.addRunArtifact(playback_sim_tests).step);
    test_step.dependOn(&b.addRunArtifact(playback_control_tests).step);
    test_step.dependOn(&b.addRunArtifact(display_transfer_tests).step);
    test_step.dependOn(&b.addRunArtifact(lcd_dma_tests).step);
    test_step.dependOn(&b.addRunArtifact(storage_sim_tests).step);
    test_step.dependOn(&b.addRunArtifact(media_pipeline_sim_tests).step);
    test_step.dependOn(&b.addRunArtifact(flac_sim_tests).step);
    test_step.dependOn(&b.addRunArtifact(flac_pipeline_sim_tests).step);
}
