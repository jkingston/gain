const std = @import("std");
pub fn add(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native: bool) *std.Build.Module {
    const files = b.addWriteFiles();
    const config = files.add("tusb_config.h",
        \\#pragma once
        \\#define CFG_TUSB_MCU OPT_MCU_NONE
        \\#define CFG_TUSB_OS OPT_OS_NONE
        \\#define CFG_TUD_ENABLED 1
        \\#define CFG_TUD_MAX_SPEED OPT_MODE_HIGH_SPEED
        \\#define CFG_TUSB_DEBUG 0
        \\#define TUP_USBIP_DWC2 1
        \\#define TUP_DCD_ENDPOINT_MAX 9
        \\#define TUP_RHPORT_HIGHSPEED 1
        \\#define CFG_TUD_DWC2_DMA_ENABLE 0
        \\#define CFG_TUD_DWC2_SLAVE_ENABLE 1
        \\#define CFG_TUD_MSC 1
        \\#define CFG_TUD_MSC_EP_BUFSIZE 4096
        \\#define CFG_TUSB_MEM_ALIGN __attribute__((aligned(32)))
    );
    _ = files.add("gain_dwc2_port.h",
        \\#define DWC2_EP_MAX 9
        \\extern const dwc2_controller_t _dwc2_controller[1];
        \\void dwc2_clock_init(uint8_t rhport, tusb_role_t role);
        \\void dwc2_int_set(uint8_t rhport, tusb_role_t role, bool enabled);
        \\void dwc2_remote_wakeup_delay(void);
        \\void dwc2_phy_init(dwc2_regs_t *regs, uint8_t phy);
        \\void dwc2_phy_update(dwc2_regs_t *regs, uint8_t phy);
        \\void dwc2_phy_deinit(dwc2_regs_t *regs, uint8_t phy);
    );
    const header = files.add("gain_usb.h", "#include \"tusb.h\"\n#include \"device/dcd.h\"\n#include \"device/usbd_pvt.h\"\n");
    const api = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize, .link_libc = !native });
    api.addIncludePath(config.dirname());
    api.addIncludePath(b.path("vendor/tinyusb/src"));
    if (native) api.addIncludePath(b.path("src/codecs/include/native"));
    const api_module = api.createModule();
    module.addImport("c_usb", api_module);
    // Keep the USB C policy independent of decoder compiler/sanitizer flags.
    const core = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = !native });
    core.addIncludePath(config.dirname());
    core.addIncludePath(b.path("vendor/tinyusb/src"));
    if (native) core.addIncludePath(b.path("src/codecs/include/native"));
    const flags: []const []const u8 = if (native) &.{ "-std=c11", "-fno-builtin", "-mno-abicalls", "-fno-pic" } else &.{ "-std=c11", "-U__ARM_FEATURE_UNALIGNED", "-D__ARM_FEATURE_UNALIGNED=0" };
    for ([_][]const u8{ "src/tusb.c", "src/common/tusb_fifo.c", "src/device/usbd.c", "src/class/msc/msc_device.c" }) |source| core.addCSourceFile(.{ .file = b.path(b.fmt("vendor/tinyusb/{s}", .{source})), .flags = flags });
    if (native) for ([_][]const u8{ "dcd_dwc2.c", "dwc2_common.c" }) |source| core.addCSourceFile(.{ .file = b.path(b.fmt("vendor/tinyusb/src/portable/synopsys/dwc2/{s}", .{source})), .flags = flags });
    module.linkLibrary(b.addLibrary(.{ .name = if (native) "gain-usb" else "gain-usb-test", .linkage = .static, .root_module = core }));
    return api_module;
}
