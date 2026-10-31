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
    stage2_module.addAssemblyFile(b.path("src/x1000_context.S"));
    @import("build_codecs.zig").add(b, stage2_module, target, .ReleaseFast, true);
    const stage2 = b.addExecutable(.{ .name = "gain-stage2.elf", .root_module = stage2_module });
    stage2.entry = .disabled;
    stage2.setLinkerScript(b.path("stage2.ld"));
    const stage2_raw = stage2.addObjCopy(.{ .format = .binary, .basename = "gain-stage2.bin" });

    b.installArtifact(spl);
    b.installArtifact(stage2);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(spl_raw.getOutput(), .bin, "gain-spl.raw").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(spl_image, .bin, "gain-spl.bin").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(stage2_raw.getOutput(), .bin, "gain-stage2.bin").step);

    const player_check_api = b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = target, .optimize = .ReleaseFast });
    @import("build_codecs.zig").add(b, player_check_api, target, .ReleaseFast, true);
    const player_check_module = b.createModule(.{ .root_source_file = b.path("tools/player_check.zig"), .target = target, .optimize = .ReleaseFast });
    player_check_module.addImport("gain", player_check_api);
    player_check_module.addAssemblyFile(b.path("tools/player_check_start.S"));
    player_check_module.addAssemblyFile(b.path("src/x1000_context.S"));
    const player_check = b.addExecutable(.{ .name = "gain-player-check.elf", .root_module = player_check_module });
    player_check.entry = .disabled;
    player_check.setLinkerScript(b.path("stage2.ld"));
    const player_check_step = b.step("player-check-f20", "Build bounded RAM-only production player qualification");
    player_check_step.dependOn(&b.addInstallArtifact(player_check, .{}).step);
    player_check_step.dependOn(&b.addInstallFileWithDir(spl_image, .bin, "gain-spl.bin").step);
    const player_check_raw = player_check.addObjCopy(.{ .format = .binary, .basename = "gain-player-check.bin" });
    player_check_step.dependOn(&b.addInstallFileWithDir(player_check_raw.getOutput(), .bin, "gain-player-check.bin").step);
    const player_reader = b.addExecutable(.{ .name = "read-player-check", .root_module = b.createModule(.{ .root_source_file = b.path("tools/read_player_check.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    player_check_step.dependOn(&b.addInstallArtifact(player_reader, .{}).step);
    b.getInstallStep().dependOn(&player_check.step);
    const reference_api = b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true });
    @import("build_codecs.zig").add(b, reference_api, b.graph.host, .ReleaseFast, false);
    const reference_module = b.createModule(.{ .root_source_file = b.path("tools/player_reference.zig"), .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true });
    reference_module.addImport("gain", reference_api);
    reference_module.addImport("fixtures", b.createModule(.{ .root_source_file = b.path("tests/codec_fixtures.zig"), .target = b.graph.host, .optimize = .ReleaseFast }));
    const reference = b.addExecutable(.{ .name = "player-reference", .root_module = reference_module, .use_llvm = true });
    player_check_step.dependOn(&b.addInstallArtifact(reference, .{}).step);

    // SDL is optional: firmware and ordinary host tests do not build it.
    const simulator_api = b.createModule(.{ .root_source_file = b.path("src/simulator.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const simulator_module = b.createModule(.{ .root_source_file = b.path("tools/sim.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .link_libc = true });
    simulator_module.addImport("gain_simulator", simulator_api);
    const sdl_prefix = b.option([]const u8, "sdl-prefix", "SDL3 installation prefix") orelse if (b.graph.host.result.os.tag == .macos) "/opt/homebrew" else "/usr";
    const sdl_headers = b.addTranslateC(.{ .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ sdl_prefix, "include/SDL3/SDL.h" }) }, .target = b.graph.host, .optimize = .ReleaseSafe });
    sdl_headers.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdl_prefix, "include" }) });
    simulator_module.addImport("sdl", sdl_headers.createModule());
    simulator_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdl_prefix, "lib" }) });
    simulator_module.addRPath(.{ .cwd_relative = b.pathJoin(&.{ sdl_prefix, "lib" }) });
    simulator_module.linkSystemLibrary("SDL3", .{});
    const simulator = b.addExecutable(.{ .name = "gain-sim", .root_module = simulator_module });
    b.step("build-sim", "Build the generic F20 desktop simulator").dependOn(&b.addInstallArtifact(simulator, .{}).step);
    const simulator_run = b.addRunArtifact(simulator);
    if (b.option([]const u8, "sim-app", "Native app library to run")) |path| simulator_run.addArgs(&.{ "--app", path });
    if (b.option(bool, "sim-watch", "Reload the app when its built module changes") orelse false) simulator_run.addArg("--watch");
    b.step("sim", "Run a native app in the F20 simulator (-Dsim-app=PATH)").dependOn(&simulator_run.step);
    const sim_core_module = b.createModule(.{ .root_source_file = b.path("tools/sim_core.zig"), .target = b.graph.host, .optimize = .Debug });
    sim_core_module.addImport("gain_simulator", simulator_api);
    const sim_unit_tests = b.addTest(.{ .root_module = sim_core_module });
    const sim_policy_step = b.step("test-sim-core", "Test simulator policies without SDL");
    sim_policy_step.dependOn(&b.addRunArtifact(sim_unit_tests).step);
    const sim_check = b.addSystemCommand(&.{ "python3", "tools/check_sim.py", "--sim" });
    sim_check.addArtifactArg(simulator);
    if (b.option(bool, "sim-visible", "Run simulator qualification in a visible native window") orelse false) sim_check.addArg("--visible");
    const SimFixture = enum { good, bad_version, reject, oversized, missing, changed };
    for (std.enums.values(SimFixture)) |variant| {
        const name = if (variant == .bad_version) "bad-version" else @tagName(variant);
        const fixture_module = b.createModule(.{ .root_source_file = b.path("tests/sim_app.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .link_libc = true });
        fixture_module.addImport("gain_simulator", simulator_api);
        const fixture_options = b.addOptions();
        fixture_options.addOption(SimFixture, "variant", variant);
        fixture_module.addOptions("sim_fixture", fixture_options);
        const fixture = b.addLibrary(.{ .name = b.fmt("sim-{s}", .{name}), .linkage = .dynamic, .root_module = fixture_module });
        sim_check.addArg(b.fmt("--{s}", .{name}));
        sim_check.addArtifactArg(fixture);
    }
    const sim_test_step = b.step("test-sim", "Qualify native loading, reload, input and pixel presentation headlessly");
    sim_test_step.dependOn(sim_policy_step);
    sim_test_step.dependOn(&sim_check.step);

    const ui_benchmark_module = b.createModule(.{ .root_source_file = b.path("tools/bench_ui.zig"), .target = target, .optimize = .ReleaseFast });
    ui_benchmark_module.addAssemblyFile(b.path("tools/bench_start.S"));
    ui_benchmark_module.addImport("gain", b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = target, .optimize = .ReleaseFast }));
    const ui_benchmark = b.addExecutable(.{ .name = "gain-ui-bench.elf", .root_module = ui_benchmark_module });
    ui_benchmark.entry = .disabled;
    ui_benchmark.setLinkerScript(b.path("tools/bench_ui.ld"));
    b.getInstallStep().dependOn(&ui_benchmark.step);
    const ui_benchmark_raw = ui_benchmark.addObjCopy(.{ .format = .binary, .basename = "gain-ui-bench.bin" });
    const ui_benchmark_step = b.step("bench-ui-f20", "Build RAM-only UI ownership/performance qualification");
    ui_benchmark_step.dependOn(&b.addInstallArtifact(ui_benchmark, .{}).step);
    ui_benchmark_step.dependOn(&b.addInstallFileWithDir(ui_benchmark_raw.getOutput(), .bin, "gain-ui-bench.bin").step);
    ui_benchmark_step.dependOn(&b.addInstallFileWithDir(spl_image, .bin, "gain-spl.bin").step);
    const ui_reader = b.addExecutable(.{ .name = "read-ui-bench", .root_module = b.createModule(.{ .root_source_file = b.path("tools/read_ui_bench.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    const ui_reader_run = b.addRunArtifact(ui_reader);
    if (b.option([]const u8, "ui-report", "UI benchmark report path")) |path| ui_reader_run.addArg(path);
    b.step("read-ui-bench", "Validate one F20 UI benchmark report").dependOn(&ui_reader_run.step);

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
    const display_tests_step = b.step("test-ui", "Run UI and presentation regressions in Debug and ReleaseFast");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
        for ([_][]const u8{ "src/ui.zig", "src/presentation.zig", "src/display_phase.zig", "src/player_view.zig", "src/player_presenter.zig", "tools/ui_bench_report.zig" }) |source| {
            const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = b.graph.host, .optimize = mode }) });
            display_tests_step.dependOn(&b.addRunArtifact(tests).step);
        }
    }
    const ui_fuzz_module = b.createModule(.{ .root_source_file = b.path("tests/ui_fuzz.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    ui_fuzz_module.addImport("gain_ui", b.createModule(.{ .root_source_file = b.path("src/ui_api.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }));
    const ui_fuzz_tests = b.addTest(.{ .root_module = ui_fuzz_module });
    const ui_fuzz_run = b.addRunArtifact(ui_fuzz_tests);
    display_tests_step.dependOn(&ui_fuzz_run.step);
    b.step("fuzz-ui", "Fuzz display packing from one corpus owner").dependOn(&ui_fuzz_run.step);
    const hardware_support_step = b.step("test-hardware", "Run codec and board protocol tests in Debug and ReleaseFast");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
        for ([_][]const u8{ "src/aiff.zig", "src/flac_pcm.zig", "src/pcm_sample.zig", "src/es9018k2m.zig", "src/axp192.zig", "src/pdma_frontier.zig", "src/dac_lock.zig", "src/output_route.zig", "src/audio.zig" }) |source| {
            const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = b.graph.host, .optimize = mode }) });
            hardware_support_step.dependOn(&b.addRunArtifact(tests).step);
        }
    }
    const codec_fuzz_module = b.createModule(.{ .root_source_file = b.path("tests/codec_fuzz.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    codec_fuzz_module.addImport("codecs", b.createModule(.{ .root_source_file = b.path("src/codec_api.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }));
    const codec_fuzz_tests = b.addTest(.{ .root_module = codec_fuzz_module });
    const codec_fuzz_run = b.addRunArtifact(codec_fuzz_tests);
    hardware_support_step.dependOn(&codec_fuzz_run.step);
    const codec_fuzz_step = b.step("fuzz-codecs", "Fuzz container parsing and PCM conversion");
    codec_fuzz_step.dependOn(&codec_fuzz_run.step);
    const container_fuzz_module = b.createModule(.{ .root_source_file = b.path("tests/container_fuzz.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    container_fuzz_module.addImport("gain", b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }));
    for ([_][]const u8{ "fuzz MP4", "fuzz Ogg" }) |filter| {
        const container_fuzz_run = b.addRunArtifact(b.addTest(.{ .root_module = container_fuzz_module, .filters = &.{filter} }));
        codec_fuzz_step.dependOn(&container_fuzz_run.step);
        hardware_support_step.dependOn(&container_fuzz_run.step);
    }
    const pipeline_tests_step = b.step("test-pipeline", "Run shared executive, session and PCM pipeline regressions");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
        for ([_][]const u8{ "tools/player_check_report.zig", "tools/player_pcm_checksum.zig", "src/file_browser.zig", "src/player_screen.zig", "src/f20_player.zig", "src/buffer_regions.zig", "src/executive.zig", "src/task_context.zig", "src/task_stack.zig", "src/task_dispatch.zig", "src/byte_ring.zig", "src/input_stream.zig", "src/codec_pool.zig", "src/codec_runtime.zig", "src/media_source.zig", "src/f20_memory.zig", "src/pcm_reservoir.zig", "src/audio_output.zig" }) |source| {
            const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = b.graph.host, .optimize = mode }) });
            pipeline_tests_step.dependOn(&b.addRunArtifact(tests).step);
        }
    }
    const codec_tests_step = b.step("test-codecs", "Run production decoder and container integration tests");
    for ([_]std.builtin.OptimizeMode{ .ReleaseSafe, .ReleaseFast }) |mode| {
        const codec_module = b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = b.graph.host, .optimize = mode, .link_libc = true });
        @import("build_codecs.zig").add(b, codec_module, b.graph.host, mode, false);
        const codec_tests_module = b.createModule(.{ .root_source_file = b.path("tests/codec_stream_tests.zig"), .target = b.graph.host, .optimize = mode, .link_libc = true });
        codec_tests_module.addImport("gain", codec_module);
        const codec_tests = b.addTest(.{ .root_module = codec_tests_module, .use_llvm = true });
        codec_tests_step.dependOn(&b.addRunArtifact(codec_tests).step);
        const bridge_module = b.createModule(.{ .root_source_file = b.path("src/codec_backend.zig"), .target = b.graph.host, .optimize = mode, .link_libc = true });
        @import("build_codecs.zig").add(b, bridge_module, b.graph.host, mode, false);
        codec_tests_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bridge_module, .use_llvm = true })).step);
    }
    // Independently link every selected engine for the actual target.
    // The check has no hardware startup and is not installed.
    const native_codecs = b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = target, .optimize = .ReleaseFast });
    @import("build_codecs.zig").add(b, native_codecs, target, .ReleaseFast, true);
    const codec_link_module = b.createModule(.{ .root_source_file = b.path("tests/codec_compile_check.zig"), .target = target, .optimize = .ReleaseFast });
    codec_link_module.addImport("gain", native_codecs);
    const codec_link_check = b.addExecutable(.{ .name = "gain-codec-link-check", .root_module = codec_link_module });
    codec_link_check.entry = .disabled;
    _ = codec_link_check.getEmittedBin();
    codec_link_check.setLinkerScript(b.path("stage2.ld"));
    b.step("check-codecs-f20", "Compile and link the complete codec path for freestanding MIPS").dependOn(&codec_link_check.step);
    codec_tests_step.dependOn(&codec_link_check.step);
    const test_step = b.step("test", "Run host-side tests");
    test_step.dependOn(sim_policy_step);
    test_step.dependOn(codec_tests_step);
    test_step.dependOn(pipeline_tests_step);
    test_step.dependOn(display_tests_step);
    test_step.dependOn(hardware_support_step);
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
