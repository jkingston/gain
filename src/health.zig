//! Bounded read-only qualification counters. Owners publish completed operations;
//! the optional USB development endpoint copies this fixed snapshot, never I2C.
pub const Snapshot = extern struct {
    version: u32 = 1,
    charger_valid: u32 = 0,
    charge_control: u32 = 0,
    charge_timing: u32 = 0,
    usb_path: u32 = 0,
    adc_enable: u32 = 0,
    adc_rate: u32 = 0,
    target_mv: u32 = 0,
    charge_ma: u32 = 0,
    usb_limit_ma: u32 = 0,
    temperature_adc: u32 = 0,
    text_initialized: u32 = 0,
    text_loaded: u32 = 0,
    text_result: u32 = 0,
    text_prepared: u32 = 0,
    text_worst_ticks: u32 = 0,
    text_bytes_low: u32 = 0,
    text_bytes_high: u32 = 0,
    text_heap_peak: u32 = 0,
    text_heap_failures: u32 = 0,
    text_page_reads: u32 = 0,
    text_page_hits: u32 = 0,
    text_labels: u32 = 0,
    text_glyphs: u32 = 0,
    playback_phase: u32 = 0,
    queue_count: u32 = 0,
    queue_cursor: u32 = 0,
};
pub var snapshot: Snapshot = .{};
pub fn charger(configuration: @import("axp192.zig").ChargerConfiguration) void {
    snapshot.charge_control = configuration.charge_control;
    snapshot.charge_timing = configuration.charge_timing;
    snapshot.usb_path = configuration.usb_path;
    snapshot.adc_enable = configuration.adc_enable;
    snapshot.adc_rate = configuration.adc_rate;
    snapshot.target_mv = configuration.targetMillivolts();
    snapshot.charge_ma = configuration.chargeMilliamps();
    snapshot.usb_limit_ma = configuration.usbLimitMilliamps() orelse 0;
    snapshot.temperature_adc = @intFromBool(configuration.temperatureAdcEnabled());
    snapshot.charger_valid = 1;
}
