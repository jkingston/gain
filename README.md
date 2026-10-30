# gain

Open-source firmware for the Surfans F20.

gain is a freestanding Zig firmware targeting the Ingenic X1000 directly. It
owns its bootloader and runtime and has no Linux or Rockbox dependency in its
normal boot path.

## Target

| Property | Value |
|---|---|
| Board | Surfans F20 V2.7 |
| SoC | Ingenic X1000 |
| CPU | XBurst-1, little-endian MIPS32 |
| RAM | 32 MiB integrated LPDDR |
| Display | 320 x 240 RGB565 |
| DAC | ES9018K2M |
| Storage | removable microSD |

Recovery images, stock firmware and captured device data are kept in the
separate `f20-v27-archive` repository.

## Current state

The first native hardware milestone is verified on a physical F20 V2.7. The
current RAM-only build provides:

- an X1000 ROM-loadable Zig SPL;
- LPDDR initialization and a gain-owned stage-two handoff;
- a freestanding Zig runtime with exception vectors;
- a 320 x 240 RGB565 display driver;
- all buttons and both wheel directions;
- AXP192 status, battery voltage and power-off;
- native read-only SD initialization at up to 50 MHz;
- allocation-free FAT32 and RIFF/WAVE parsing;
- allocation-free native FLAC decoding and streaming;
- ES9018K2M setup and linked-PDMA PCM playback;
- a watchdog-backed panic screen.

The storage and playback path has been verified from RAM on the physical F20:
120 50 ms chunks streamed from microSD with 120 descriptor handoffs, no audio
underruns and a 32-frame FIFO low-water mark. It has no NAND write path, and
the SD API is read-only.

The PCM output path has also been verified on the physical F20 at 44.1, 48,
88.2, 96, 176.4 and 192 kHz. Packed 16-bit and native 24-bit DMA layouts use
the X1000's fixed 32-bit I2S channel slots. Every rate held DAC lock for three
linked DMA cycles with no underruns and a 32-frame FIFO low-water mark. The
48 kHz clock family is exact; the 44.1 kHz family is 1.56 ppm low.

The complete media path has been verified audibly from microSD with both 16-bit
and packed 24-bit stereo WAV files. Each six-second track streamed 288,000
frames through FAT32, WAV parsing, PCM packing and linked DMA. The 24-bit test
preserved distinct left, right and stereo sections, completed 240 buffer loads
and descriptor handoffs across two descriptor-ring wraps at a 50 MHz SD clock,
and restarted cleanly after shutdown. Exact sample conversion and ordering are
also checked by the deterministic simulation.

The native FLAC decoder covers constant, verbatim, fixed and LPC subframes,
Rice and Rice2 residuals, wasted bits, CRC validation and every stereo
decorrelation mode. The complete production path streamed a two-second
24-bit/192 kHz FLAC from FAT32 on the physical microSD through an uncached SD
bounce buffer, cached native decoding, PCM packing and linked DMA. All 24
16,384-frame blocks completed with no underruns and a 32-frame FIFO low-water
mark. The slowest complete fill used 87.1% of its interval before the next DMA
event. A captured ReleaseSmall trace that missed a descriptor is retained as a
deterministic regression; stage two is compiled with ReleaseFast.

## Development

Install [mise](https://mise.jdx.dev), then install the pinned Zig toolchain and
run the complete project check:

```sh
mise install
mise run check
```

Useful individual tasks are `mise run format`, `mise run lint`,
`mise run build`, `mise run test`, `mise run fuzz` and `mise run bench`. The lint task checks
canonical Zig formatting and runs Zig's AST validation. The complete check
then builds both firmware images and runs the host-side tests. The separate
fuzz task runs at least 100,000 generated cases against the SPL image builder,
WAV parser and FLAC metadata/frame decoder.

`mise run bench` measures FLAC decoding, PCM packing and LPC reconstruction on
the host. `mise run bench-f20` runs the corresponding RAM-only benchmarks on a
connected F20 in the mask-ROM USB loop. Device results include the minimum,
median, p95 and maximum time as a fraction of a 16,384-frame 192 kHz playback
interval. The performance target is at most 70% for the maximum refill, with
75% as the enforced release ceiling. The default device suite is read-only and
returns to the ROM USB loop after every case. Cached-output and sustained-SD
probes are opt-in because they test cache coherency and experimental storage
paths rather than release behavior.

After one successful suite, the F20 remains in the ROM USB loop with DRAM
initialized. Set `GAIN_SKIP_SPL=1` for later benchmark invocations in that same
power session so a rebuilt payload can be uploaded without resetting the
device or re-running DDR initialization.

The build places these images in `zig-out/bin`:

| Image | Purpose |
|---|---|
| `gain-spl.bin` | X1000 ROM image with a 2 KiB boot header |
| `gain-spl.raw` | Unwrapped TCSM code |
| `gain-stage2.bin` | Flat DRAM image loaded at `0x80004000` |

## Hardware boundary

The source keeps SoC and board knowledge separate without a runtime HAL:

| Source | Responsibility |
|---|---|
| `src/x1000.zig` | Typed X1000 MMIO registers, fields and peripheral primitives |
| `src/f20_v27.zig` | F20 V2.7 wiring, panel data and verified LPDDR profile |
| `src/f20.zig` | Compile-time F20 device facade used by product code |
| `src/sd.zig` | Native X1000 read-only SD controller |
| `src/fat32.zig` | Portable allocation-free FAT32 reader |
| `src/wav.zig` | Portable bounded RIFF/WAVE parser |
| `src/pcm.zig` | Portable allocation-free WAV PCM to DMA frame conversion |
| `src/flac.zig` | Portable allocation-free native FLAC frame decoder |
| `src/flac_pcm.zig` | Portable FLAC stream to fixed DMA chunk conversion |
| `src/audio.zig` | Native AIC, ES9018K2M and linked-PDMA output |
| `src/playback.zig` | Portable buffer lifecycle and descriptor state machine |
| `src/f20_media.zig` | Allocation-free F20 WAV/FLAC streaming and audio lifecycle |
| `src/spl.zig` | Ordered clock and DRAM initialization flow |
| `src/main.zig` | Device behavior and diagnostics |

Small register and pin operations are explicitly inlined. Fixed LPDDR writes
use compact data tables, while waits, read-modify-write operations and ordering
boundaries remain imperative. Opaque panel and DRAM values are kept together
as named, board-specific profiles.

The SPL has a 10 KiB code limit imposed by both the linker and image packer.
Stage two has a 240 KiB link region ending at the framebuffer boundary. A
budget overflow therefore fails the build.

## Simulation

Simulation targets portable policy and feeds the same modules used on device:

| Test | Boundary |
|---|---|
| `tests/playback_sim.zig` | DMA/FIFO timing, refill interleavings, descriptor wraps and frame order through `src/playback.zig` |
| `tests/storage_sim.zig` | MBR, fragmented FAT32 files and WAV chunks through `src/fat32.zig` and `src/wav.zig` |
| `tests/media_pipeline_sim.zig` | Fragmented WAV input, irregular reads, exact PCM frames, partial EOF and buffer recycling through the complete portable media path |
| `tests/flac_sim.zig` | 24-bit/192 kHz decoding, exact F20 buffer bounds, measured decode deadlines and missed-event rejection |
| `tests/flac_pipeline_sim.zig` | FAT32 FLAC input, SD DMA alignment, bounce buffering, exact PCM chunks and captured device timing |
| Inline source tests | Register encodings, clock ratios, descriptors and other pure hardware facts |

The tests do not emulate the X1000. MMIO sequencing is checked by compiling
the concrete F20 specializations and by RAM-only tests on the physical device.

## RAM boot

The development boot uses the X1000 mask ROM and a compatible `usbboot` host
tool. It does not modify storage.

```sh
usbboot --cpu x1000 --stage1 zig-out/bin/gain-spl.bin
usbboot --cpu x1000 --addr 0x80004000 \
  --download zig-out/bin/gain-stage2.bin --flush-caches \
  --start1 0xf4001a00
```

The ROM loads the SPL at `0xf4001000` and enters it at `0xf4001800`. The SPL
initializes LPDDR and returns to the ROM USB loop. The final command uploads
stage two and calls gain's handoff at `0xf4001a00`.

## License

gain is released under the [MIT License](LICENSE).


