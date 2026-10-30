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
- ES9018K2M setup and linked-PDMA PCM playback;
- a watchdog-backed panic screen.

The storage and playback path has been verified from RAM on the physical F20:
120 50 ms chunks streamed from microSD with 120 descriptor handoffs, no audio
underruns and a 32-frame FIFO low-water mark. It has no NAND write path, and
the SD API is read-only.

The PCM output path has also been verified on the physical F20 at 44.1, 48,
88.2, 96, 176.4 and 192 kHz. Packed 16-bit, native 24-bit and 24-bit samples
in 32-bit I2S slots all held DAC lock for three linked DMA cycles with no
underruns and a 32-frame FIFO low-water mark. The 48 kHz clock family is exact;
the 44.1 kHz family is 1.56 ppm low.

## Development

Install [mise](https://mise.jdx.dev), then install the pinned Zig toolchain and
run the complete project check:

```sh
mise install
mise run check
```

Useful individual tasks are `mise run format`, `mise run lint`,
`mise run build`, `mise run test` and `mise run fuzz`. The lint task checks
canonical Zig formatting and runs Zig's AST validation. The complete check
then builds both firmware images and runs the host-side tests. The separate
fuzz task runs 100,000 generated cases against the SPL image builder and WAV
parser.

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
| `src/audio.zig` | Native AIC, ES9018K2M and linked-PDMA output |
| `src/playback.zig` | Portable buffer lifecycle and descriptor state machine |
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


