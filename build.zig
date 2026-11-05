const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .mipsel,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.mips.cpu.mips32r2 },
    });
    const loader_api = b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = target, .optimize = .ReleaseSafe });
    const loader_module = b.createModule(.{ .root_source_file = b.path("src/boot/loader.zig"), .target = target, .optimize = .ReleaseSafe });
    loader_module.addImport("platform", loader_api);
    loader_module.addAssemblyFile(b.path("src/boot/start.S"));
    loader_module.addAssemblyFile(b.path("src/boot/fresh_rom.S"));
    const loader = b.addExecutable(.{ .name = "gain-loader.elf", .root_module = loader_module });
    loader.entry = .disabled;
    loader.setLinkerScript(b.path("loader.ld"));
    const loader_raw = loader.addObjCopy(.{ .format = .binary, .basename = "gain-loader.bin" });
    const loader_pack = b.addSystemCommand(&.{ "python3", "tools/pack_firmware.py", "loader" });
    loader_pack.addFileArg(loader_raw.getOutput());
    const loader_image = loader_pack.addOutputFileArg("gain-loader.uimage");
    const loader_step = b.step("build-loader", "Build the read-only SD loader for the factory kernel boot path");
    loader_step.dependOn(&b.addInstallArtifact(loader, .{}).step);
    loader_step.dependOn(&b.addInstallFileWithDir(loader_raw.getOutput(), .bin, "gain-loader.bin").step);
    loader_step.dependOn(&b.addInstallFileWithDir(loader_image, .bin, "gain-loader.uimage").step);
    b.getInstallStep().dependOn(loader_step);
    const boot_tests_step = b.step("test-boot", "Test boot validation, fallback, recovery and filesystem loading");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe, .ReleaseFast }) |mode| {
        const boot_module = b.createModule(.{ .root_source_file = b.path("src/boot_tests.zig"), .target = b.graph.host, .optimize = mode });
        const boot_tests = b.addTest(.{ .root_module = boot_module });
        boot_tests_step.dependOn(&b.addRunArtifact(boot_tests).step);
    }
    const filesystem_tests_step = b.step("test-filesystems", "Test FAT32 and sparse 256 GiB exFAT cards");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe, .ReleaseFast }) |mode| {
        const module = b.createModule(.{ .root_source_file = b.path("src/filesystem_tests.zig"), .target = b.graph.host, .optimize = mode });
        const unit = b.addTest(.{ .root_module = module });
        filesystem_tests_step.dependOn(&b.addRunArtifact(unit).step);
    }
    const filesystem_check_module = b.createModule(.{ .root_source_file = b.path("tools/check_filesystem.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    filesystem_check_module.addImport("gain", b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }));
    const filesystem_check = b.addExecutable(.{ .name = "check-filesystem", .root_module = filesystem_check_module });
    b.step("build-filesystem-check", "Build the read-only raw-card filesystem inspector").dependOn(&b.addInstallArtifact(filesystem_check, .{}).step);
    const text_target = target;
    const text_module = b.createModule(.{
        .root_source_file = b.path("src/text_engine.zig"),
        .target = text_target,
        .single_threaded = true,
        .optimize = .ReleaseSmall,
        .strip = !(b.option(bool, "text-symbols", "Retain native text-engine debug symbols") orelse false),
    });
    @import("build_text.zig").add(b, text_module, text_target, .ReleaseSmall);
    const text_engine = b.addExecutable(.{ .name = "gain-text.elf", .root_module = text_module });
    text_engine.entry = .disabled;
    text_engine.setLinkerScript(b.path("text.ld"));
    const text_raw = text_engine.addObjCopy(.{ .format = .binary, .basename = "gain-text.bin" });
    const text_pack = b.addSystemCommand(&.{ "python3", "tools/pack_text_engine.py" });
    text_pack.addFileArg(text_raw.getOutput());
    const text_component = text_pack.addOutputFileArg("engine.bin");
    const text_component_check = b.addSystemCommand(&.{ "python3", "tools/check_text_component.py", "--elf" });
    text_component_check.addArtifactArg(text_engine);
    text_component_check.addArg("--component");
    text_component_check.addFileArg(text_component);
    const text_step = b.step("build-text", "Build the SD-backed F20 Unicode text engine");
    text_step.dependOn(&text_component_check.step);
    text_step.dependOn(&b.addInstallArtifact(text_engine, .{}).step);
    text_step.dependOn(&b.addInstallFileWithDir(text_component, .bin, "engine.bin").step);
    text_step.dependOn(&b.addInstallFileWithDir(text_raw.getOutput(), .bin, "gain-text.bin").step);
    const text_test_module = b.createModule(.{ .root_source_file = b.path("src/text_tests.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .link_libc = true, .link_libcpp = true });
    @import("build_text.zig").add(b, text_test_module, b.graph.host, .ReleaseSafe);
    text_test_module.addImport("font_fixture", b.createModule(.{ .root_source_file = b.path("tests/font_fixture.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }));
    const text_tests = b.addTest(.{ .root_module = text_test_module });
    const text_test_step = b.step("test-text", "Test Unicode layout, SD fonts and prepared label caching");
    text_test_step.dependOn(&b.addRunArtifact(text_tests).step);
    const text_fuzz = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/text_fuzz.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    const text_fuzz_run = b.addRunArtifact(text_fuzz);
    text_test_step.dependOn(&text_fuzz_run.step);
    b.step("fuzz-text", "Fuzz text-pack envelopes and UTF-8 request bounds").dependOn(&text_fuzz_run.step);
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
    const firmware_options = b.addOptions();
    firmware_options.addOption(bool, "maintenance", false);
    const build_identity = b.option(u64, "build-id", "Content/revision identity included in diagnostics") orelse 0;
    firmware_options.addOption(u64, "build_id", build_identity);
    stage2_module.addOptions("firmware_options", firmware_options);
    stage2_module.addAssemblyFile(b.path("src/start.S"));
    stage2_module.addAssemblyFile(b.path("src/x1000_context.S"));
    @import("build_codecs.zig").add(b, stage2_module, target, .ReleaseFast, true);
    _ = @import("build_usb.zig").add(b, stage2_module, target, .ReleaseFast, true);
    @import("build_art.zig").add(b, stage2_module, target, .ReleaseFast, true);
    const stage2 = b.addExecutable(.{ .name = "gain-stage2.elf", .root_module = stage2_module });
    stage2.entry = .disabled;
    stage2.setLinkerScript(b.path("stage2.ld"));
    const core_check = b.addSystemCommand(&.{ "python3", "tools/check_firmware.py" });
    core_check.addArtifactArg(stage2);
    b.getInstallStep().dependOn(&core_check.step);
    const stage2_raw = stage2.addObjCopy(.{ .format = .binary, .basename = "gain-stage2.bin" });

    b.getInstallStep().dependOn(text_step);
    b.installArtifact(spl);
    b.installArtifact(stage2);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(spl_raw.getOutput(), .bin, "gain-spl.raw").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(spl_image, .bin, "gain-spl.bin").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(stage2_raw.getOutput(), .bin, "gain-stage2.bin").step);

    const firmware_pack = b.addSystemCommand(&.{ "python3", "tools/pack_firmware.py", "firmware" });
    firmware_pack.addFileArg(stage2_raw.getOutput());
    const firmware_image = firmware_pack.addOutputFileArg("firmware.f20");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(firmware_image, .bin, "firmware.f20").step);

    const instrumented_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = .ReleaseFast });
    instrumented_module.addAssemblyFile(b.path("src/recovery_start.S"));
    instrumented_module.addAssemblyFile(b.path("src/x1000_context.S"));
    @import("build_codecs.zig").add(b, instrumented_module, target, .ReleaseFast, true);
    _ = @import("build_usb.zig").add(b, instrumented_module, target, .ReleaseFast, true);
    @import("build_art.zig").add(b, instrumented_module, target, .ReleaseFast, true);
    const maintenance_options = b.addOptions();
    maintenance_options.addOption(bool, "maintenance", true);
    maintenance_options.addOption(u64, "build_id", build_identity);
    instrumented_module.addOptions("firmware_options", maintenance_options);
    const instrumented = b.addExecutable(.{ .name = "gain-instrumented.elf", .root_module = instrumented_module });
    instrumented.entry = .disabled;
    instrumented.setLinkerScript(b.path("stage2.ld"));
    const instrumented_check = b.addSystemCommand(&.{ "python3", "tools/check_firmware.py" });
    instrumented_check.addArtifactArg(instrumented);
    const instrumented_raw = instrumented.addObjCopy(.{ .format = .binary, .basename = "gain-instrumented.bin" });
    const instrumented_step = b.step("instrumented", "Build the complete player with RAM-only maintenance controls");
    instrumented_step.dependOn(&instrumented_check.step);
    instrumented_step.dependOn(&b.addInstallArtifact(instrumented, .{}).step);
    instrumented_step.dependOn(&b.addInstallFileWithDir(instrumented_raw.getOutput(), .bin, "gain-instrumented.bin").step);
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
    const player_reader = b.addExecutable(.{
        .name = "read-player-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/read_player_check.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    player_check_step.dependOn(&b.addInstallArtifact(player_reader, .{}).step);
    b.getInstallStep().dependOn(&player_check.step);
    const usb_check_api = b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = target, .optimize = .ReleaseSafe });
    @import("build_codecs.zig").add(b, usb_check_api, target, .ReleaseSafe, true);
    const usb_check_c = @import("build_usb.zig").add(b, usb_check_api, target, .ReleaseSafe, true);

    const usb_check_module = b.createModule(.{ .root_source_file = b.path("tools/usb_check.zig"), .target = target, .optimize = .ReleaseSafe });
    usb_check_module.addImport("gain", usb_check_api);
    usb_check_module.addImport("c_usb", usb_check_c);
    usb_check_module.addAssemblyFile(b.path("tools/player_check_start.S"));
    usb_check_module.addAssemblyFile(b.path("src/x1000_context.S"));
    const usb_check = b.addExecutable(.{ .name = "gain-usb-check.elf", .root_module = usb_check_module });
    usb_check.entry = .disabled;
    usb_check.setLinkerScript(b.path("stage2.ld"));
    const usb_check_raw = usb_check.addObjCopy(.{ .format = .binary, .basename = "gain-usb-check.bin" });
    const usb_check_step = b.step("usb-check-f20", "Build RAM-only production USB/SD qualification");
    usb_check_step.dependOn(&b.addInstallArtifact(usb_check, .{}).step);
    usb_check_step.dependOn(&b.addInstallFileWithDir(usb_check_raw.getOutput(), .bin, "gain-usb-check.bin").step);
    usb_check_step.dependOn(&b.addInstallFileWithDir(spl_image, .bin, "gain-spl.bin").step);
    const reference_api = b.createModule(.{
        .root_source_file = b.path("src/f20.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    @import("build_codecs.zig").add(b, reference_api, b.graph.host, .ReleaseFast, false);
    const reference_module = b.createModule(.{
        .root_source_file = b.path("tools/player_reference.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    reference_module.addImport("gain", reference_api);
    reference_module.addImport("fixtures", b.createModule(.{
        .root_source_file = b.path("tests/codec_fixtures.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }));
    const reference = b.addExecutable(.{ .name = "player-reference", .root_module = reference_module, .use_llvm = true });
    player_check_step.dependOn(&b.addInstallArtifact(reference, .{}).step);

    // SDL is optional: firmware and ordinary host tests do not build it.
    const simulator_api = b.createModule(.{ .root_source_file = b.path("src/simulator.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const simulator_module = b.createModule(.{
        .root_source_file = b.path("tools/sim.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    simulator_module.addImport("gain_simulator", simulator_api);
    const sdl_prefix = b.option([]const u8, "sdl-prefix", "SDL3 installation prefix") orelse if (b.graph.host.result.os.tag == .macos) "/opt/homebrew" else "/usr";
    const sdl_headers = b.addTranslateC(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ sdl_prefix, "include/SDL3/SDL.h" }) },
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
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
    const player_app_module = b.createModule(.{
        .root_source_file = b.path("tools/player_app.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    const player_ui_module = b.createModule(.{ .root_source_file = b.path("src/ui_api.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .link_libc = true, .link_libcpp = true });
    @import("build_text.zig").add(b, player_ui_module, b.graph.host, .ReleaseSafe);
    @import("build_metadata.zig").add(b, player_ui_module, b.graph.host, .ReleaseSafe);
    @import("build_art.zig").add(b, player_ui_module, b.graph.host, .ReleaseSafe, false);
    player_app_module.addImport("gain_ui", player_ui_module);
    const player_app = b.addLibrary(.{ .name = "gain-player-ui", .linkage = .dynamic, .root_module = player_app_module });
    b.step("build-player-ui", "Build the production player UI as a simulator app").dependOn(&b.addInstallArtifact(player_app, .{}).step);
    const player_ui_check = b.addSystemCommand(&.{ "python3", "tools/check_player_ui.py", "--app" });
    player_ui_check.addArtifactArg(player_app);
    b.step("test-player-ui", "Qualify the production UI with a generated mock SD card").dependOn(&player_ui_check.step);
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
        const fixture_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_app.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        });
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
    const ui_reader = b.addExecutable(.{
        .name = "read-ui-bench",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/read_ui_bench.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
    });
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
    const firmware_bench_module = b.createModule(.{ .root_source_file = b.path("tools/bench_firmware.zig"), .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true });
    const firmware_bench_gain = b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true });
    @import("build_codecs.zig").add(b, firmware_bench_gain, b.graph.host, .ReleaseFast, false);
    firmware_bench_module.addImport("gain", firmware_bench_gain);
    firmware_bench_module.addImport("fixtures", b.createModule(.{ .root_source_file = b.path("tests/codec_fixtures.zig"), .target = b.graph.host, .optimize = .ReleaseFast }));
    const firmware_bench = b.addExecutable(.{ .name = "bench-firmware", .root_module = firmware_bench_module });
    const firmware_bench_step = b.step("bench-firmware", "Benchmark production library, UI, artwork and audio algorithms on the host");
    firmware_bench_step.dependOn(&b.addRunArtifact(firmware_bench).step);
    const firmware_bench_install = b.addInstallArtifact(firmware_bench, .{});
    firmware_bench_step.dependOn(&firmware_bench_install.step);
    b.step("build-bench-firmware", "Build host benchmarks without running timing measurements").dependOn(&firmware_bench_install.step);

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
    const input_fuzz = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/input_capture.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
        .filters = &.{"captured edge streams"},
    });
    b.step("fuzz-input", "Fuzz captured wheel/button edges, overflow and recovery").dependOn(&b.addRunArtifact(input_fuzz).step);
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
        for ([_][]const u8{ "src/preferences.zig", "src/runtime_theme.zig", "src/input_capture.zig", "src/navigation.zig", "src/ui.zig", "src/music_ui.zig", "src/usb_view.zig", "src/battery.zig", "src/canvas.zig", "src/font_data.zig", "src/cover_cache.zig", "src/cover_flow.zig", "src/volume_transition.zig", "src/render_ahead.zig", "src/frame_pacer.zig", "src/display_banks.zig", "src/display_trace.zig", "src/presentation.zig", "src/display_phase.zig", "src/player_view.zig", "src/player_presenter.zig", "tools/ui_bench_report.zig" }) |source| {
            const tests = b.addTest(.{
                .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = b.graph.host, .optimize = mode }),
            });
            display_tests_step.dependOn(&b.addRunArtifact(tests).step);
        }
    }
    const ui_fuzz_module = b.createModule(.{ .root_source_file = b.path("tests/ui_fuzz.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    ui_fuzz_module.addImport("gain_ui", b.createModule(.{
        .root_source_file = b.path("src/ui_api.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }));
    const ui_fuzz_tests = b.addTest(.{ .root_module = ui_fuzz_module });
    const ui_fuzz_run = b.addRunArtifact(ui_fuzz_tests);
    display_tests_step.dependOn(&ui_fuzz_run.step);
    b.step("fuzz-ui", "Fuzz display packing from one corpus owner").dependOn(&ui_fuzz_run.step);
    const hardware_support_step = b.step("test-hardware", "Run codec and board protocol tests in Debug and ReleaseFast");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
        for ([_][]const u8{ "src/aiff.zig", "src/flac_pcm.zig", "src/pcm_sample.zig", "src/es9018k2m.zig", "src/axp192.zig", "src/pdma_frontier.zig", "src/dac_lock.zig", "src/output_route.zig", "src/audio.zig" }) |source| {
            const tests = b.addTest(.{
                .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = b.graph.host, .optimize = mode }),
            });
            hardware_support_step.dependOn(&b.addRunArtifact(tests).step);
        }
    }
    const codec_fuzz_module = b.createModule(.{
        .root_source_file = b.path("tests/codec_fuzz.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    codec_fuzz_module.addImport("codecs", b.createModule(.{
        .root_source_file = b.path("src/codec_api.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }));
    const codec_fuzz_tests = b.addTest(.{ .root_module = codec_fuzz_module });
    const codec_fuzz_run = b.addRunArtifact(codec_fuzz_tests);
    hardware_support_step.dependOn(&codec_fuzz_run.step);
    const codec_fuzz_step = b.step("fuzz-codecs", "Fuzz container parsing and PCM conversion");
    codec_fuzz_step.dependOn(&codec_fuzz_run.step);
    const container_fuzz_module = b.createModule(.{
        .root_source_file = b.path("tests/container_fuzz.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    container_fuzz_module.addImport("gain", b.createModule(.{
        .root_source_file = b.path("src/f20.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }));
    for ([_][]const u8{ "fuzz MP4", "fuzz Ogg" }) |filter| {
        const container_fuzz_run = b.addRunArtifact(b.addTest(.{ .root_module = container_fuzz_module, .filters = &.{filter} }));
        codec_fuzz_step.dependOn(&container_fuzz_run.step);
        hardware_support_step.dependOn(&container_fuzz_run.step);
    }
    const pipeline_tests_step = b.step("test-pipeline", "Run shared executive, session and PCM pipeline regressions");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
        for ([_][]const u8{ "src/replay_gain.zig", "src/transport.zig", "src/sd_arming.zig", "src/deadline_timer.zig", "src/scan_admission.zig", "src/track_selection.zig", "tools/player_check_report.zig", "tools/player_pcm_checksum.zig", "src/file_browser.zig", "src/player_screen.zig", "src/f20_player.zig", "src/buffer_regions.zig", "src/executive.zig", "src/task_context.zig", "src/task_stack.zig", "src/task_dispatch.zig", "src/byte_ring.zig", "src/input_stream.zig", "src/codec_pool.zig", "src/codec_runtime.zig", "src/codec_math.zig", "src/media_source.zig", "src/f20_memory.zig", "src/pcm_reservoir.zig", "src/audio_output.zig" }) |source| {
            const tests = b.addTest(.{
                .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = b.graph.host, .optimize = mode }),
            });
            pipeline_tests_step.dependOn(&b.addRunArtifact(tests).step);
        }
    }
    const codec_tests_step = b.step("test-codecs", "Run production decoder and container integration tests");
    for ([_]std.builtin.OptimizeMode{ .ReleaseSafe, .ReleaseFast }) |mode| {
        const codec_module = b.createModule(.{
            .root_source_file = b.path("src/f20.zig"),
            .target = b.graph.host,
            .optimize = mode,
            .link_libc = true,
        });
        @import("build_codecs.zig").add(b, codec_module, b.graph.host, mode, false);
        const codec_tests_module = b.createModule(.{
            .root_source_file = b.path("tests/codec_stream_tests.zig"),
            .target = b.graph.host,
            .optimize = mode,
            .link_libc = true,
        });
        codec_tests_module.addImport("gain", codec_module);
        const codec_tests = b.addTest(.{ .root_module = codec_tests_module, .use_llvm = true });
        codec_tests_step.dependOn(&b.addRunArtifact(codec_tests).step);
        const bridge_module = b.createModule(.{
            .root_source_file = b.path("src/codec_backend.zig"),
            .target = b.graph.host,
            .optimize = mode,
            .link_libc = true,
        });
        @import("build_codecs.zig").add(b, bridge_module, b.graph.host, mode, false);
        codec_tests_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bridge_module, .use_llvm = true })).step);
    }
    // Independently link every selected engine for the actual target.
    // The check has no hardware startup and is not installed.
    const native_codecs = b.createModule(.{ .root_source_file = b.path("src/f20.zig"), .target = target, .optimize = .ReleaseFast });
    @import("build_codecs.zig").add(b, native_codecs, target, .ReleaseFast, true);
    const codec_link_module = b.createModule(.{
        .root_source_file = b.path("tests/codec_compile_check.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    codec_link_module.addImport("gain", native_codecs);
    const codec_link_check = b.addExecutable(.{ .name = "gain-codec-link-check", .root_module = codec_link_module });
    codec_link_check.entry = .disabled;
    _ = codec_link_check.getEmittedBin();
    codec_link_check.setLinkerScript(b.path("stage2.ld"));
    b.step("check-codecs-f20", "Compile and link the complete codec path for freestanding MIPS").dependOn(&codec_link_check.step);
    codec_tests_step.dependOn(&codec_link_check.step);
    const usb_tests_step = b.step("test-usb", "Test SD ownership, production MSC wire protocol and descriptors");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
        const usb_module = b.createModule(.{
            .root_source_file = b.path("src/usb_test.zig"),
            .target = b.graph.host,
            .optimize = mode,
            .link_libc = true,
        });
        _ = @import("build_usb.zig").add(b, usb_module, b.graph.host, mode, false);
        const usb_tests = b.addTest(.{ .root_module = usb_module });
        usb_tests_step.dependOn(&b.addRunArtifact(usb_tests).step);
        const verify_module = b.createModule(.{ .root_source_file = b.path("tools/usb_verify.zig"), .target = b.graph.host, .optimize = mode });
        usb_tests_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = verify_module })).step);
    }
    const metadata_step = b.step("test-metadata", "Check native metadata against synthetic media fixtures");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe, .ReleaseFast }) |mode| {
        const module = b.createModule(.{ .root_source_file = b.path("tests/metadata_tests.zig"), .target = b.graph.host, .optimize = mode });
        const metadata_module = b.createModule(.{ .root_source_file = b.path("src/library_metadata.zig"), .target = b.graph.host, .optimize = mode });
        @import("build_metadata.zig").add(b, metadata_module, b.graph.host, mode);
        module.addImport("metadata", metadata_module);
        metadata_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
    const metadata_fuzz_module = b.createModule(.{ .root_source_file = b.path("tests/metadata_tests.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const metadata_fuzz_parser = b.createModule(.{ .root_source_file = b.path("src/library_metadata.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    @import("build_metadata.zig").add(b, metadata_fuzz_parser, b.graph.host, .ReleaseSafe);
    metadata_fuzz_module.addImport("metadata", metadata_fuzz_parser);
    b.step("fuzz-metadata", "Fuzz bounded native metadata readers").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = metadata_fuzz_module })).step);
    const library_step = b.step("test-library", "Test portable catalogue reconciliation and persistence");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
        for ([_][]const u8{ "src/ogg_metadata.zig", "src/id3.zig", "src/progressive_view.zig", "src/f20_library.zig", "src/catalog_codec.zig", "src/diagnostics.zig", "src/catalog_store.zig", "src/library_metadata.zig", "src/maintenance_protocol.zig", "src/f20_storage.zig" }) |path| {
            const module = b.createModule(.{ .root_source_file = b.path(path), .target = b.graph.host, .optimize = mode });
            @import("build_metadata.zig").add(b, module, b.graph.host, mode);
            if (std.mem.eql(u8, path, "src/f20_library.zig")) @import("build_art.zig").add(b, module, b.graph.host, mode, false);
            library_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
        }
        const art_tests = b.createModule(.{
            .root_source_file = b.path("src/artwork.zig"),
            .target = b.graph.host,
            .optimize = mode,
            .link_libc = true,
        });
        @import("build_art.zig").add(b, art_tests, b.graph.host, mode, false);
        library_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = art_tests })).step);
        const tags_tests = b.createModule(.{ .root_source_file = b.path("tests/mp4_tags_tests.zig"), .target = b.graph.host, .optimize = mode });
        tags_tests.addImport("mp4_tags", b.createModule(.{
            .root_source_file = b.path("src/mp4_tags.zig"),
            .target = b.graph.host,
            .optimize = mode,
        }));
        library_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tags_tests })).step);
        const library_module = b.createModule(.{ .root_source_file = b.path("src/library.zig"), .target = b.graph.host, .optimize = mode });
        const library_test_module = b.createModule(.{
            .root_source_file = b.path("tests/library_tests.zig"),
            .target = b.graph.host,
            .optimize = mode,
        });
        library_test_module.addImport("library", library_module);
        library_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = library_test_module })).step);
    }
    const art_fuzz_module = b.createModule(.{ .root_source_file = b.path("src/artwork.zig"), .target = b.graph.host, .optimize = .ReleaseSafe, .link_libc = true });
    @import("build_art.zig").add(b, art_fuzz_module, b.graph.host, .ReleaseSafe, false);
    b.step("fuzz-artwork", "Fuzz bounded image decoding and PNG chunk mutations").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = art_fuzz_module })).step);
    const test_step = b.step("test", "Run host-side tests");
    test_step.dependOn(filesystem_tests_step);
    test_step.dependOn(boot_tests_step);
    test_step.dependOn(metadata_step);
    test_step.dependOn(library_step);
    test_step.dependOn(text_test_step);
    test_step.dependOn(usb_tests_step);
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
