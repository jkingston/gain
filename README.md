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
- identified AXP192 power, battery/USB voltage, current telemetry and power-off;
- configured headphone/line jack inputs with debouncing support;
- native SD initialization, raw sector reads and host-exclusive writes at up to 50 MHz;
- allocation-free FAT32 traversal, seeking, long names, WAV and AIFF parsing;
- native FLAC decoding and bounded C backends for MP3, AAC, ALAC, Vorbis and Opus;
- identified ES9018K2M, filters, de-emphasis, mute and output routing;
- linked-PDMA PCM playback with source-validated buffer ownership;
- a folder browser and now-playing screen with track and volume controls;
- DAC hardware volume and bounded, priority-aware display updates;
- a watchdog-backed panic screen.

The player uses separate preemptive output, UI, control, codec and storage tasks.
Compressed input arrives in SD bursts, decoding publishes canonical Q1.31 PCM,
and output fills fixed-duration DMA periods. Only control performs DAC I2C.
Only storage reads the card. The firmware has no NAND write path. Player filesystem access is read-only;
USB mode grants the computer exclusive raw SD access.

The PCM clock and DMA path is verified at 8, 11.025, 12, 16, 22.05, 24,
32, 44.1, 48, 64, 88.2, 96, 176.4 and 192 kHz. All fourteen rates hold DAC
lock through hardware-volume and output-routing changes with no underruns and
a 32-frame FIFO minimum. Low rates reuse the 11.2896/12.288 MHz clock families
with integer BCLK division. The 48 kHz family is exact; the 44.1 kHz family is
1.56 ppm low. The F20 serial interface uses fixed 32-bit I2S slots and sends
16-bit packed or 24-bit PCM.

The DAC locks to silence before source playback, preserving the track opening.
Its identity comes from status register 64, rather than configuration register
0. Register 10 uses the ESS revision/rate-specific lock setting. Output route
changes mute first and settle in pollable stages. Filter changes require idle
audio. Any DAC control failure asserts the independent analogue mute.
[ESS register reference](https://clara.nz/docs/hardware/ESS%20Technology/ES9018K2M-datasheet-v3.7-2021-04-22.pdf).

DMA completion is corroborated with the live source address. X1000 CDOA can identify the current fetch or its successor during a
descriptor handoff, so its value alone cannot establish buffer release.
The observer handles completion/fetch windows, duplicate observations, wrap
and coalesced events, with a bounded failure for incoherent register samples.
Captured volume-change failures have deterministic regressions.

The native pipeline qualification covers 32 synthetic codec/container fixtures
with expected presentation lengths, volume changes, clean shutdown and zero
underruns. The worst observed DMA fill was about 1.02 ms for a 10 ms period
at 192 kHz. A separate 30-second real-SD/UI run at 96 kHz completed 3,001 DMA
periods and 598 volume changes without underruns. These are bounded workloads,
not claims about every file, analogue performance or battery life.

The interactive player uses a shared declarative renderer for its browser and
now-playing views. Declarations own their copied text, use fixed command/text
budgets, clip glyphs to their widget, and accept a theme. The desktop simulator presents the same framebuffer format and physical inputs;
apps own their rendering and navigation. The device browser reads the actual
FAT32 microSD.

Presentation is hybrid: volume, progress and selection rows use true region
DMA; initial presentation and screen changes use full-frame DMA. Odd dirty
widths expand to an even window, including at the right edge. The cached CPU
canvas is separate from uncached immutable DMA sources. Every transfer follows
prepare, commit, EOF, bus drain, disable acknowledgement and source release.
A fault retains ownership. EOF alone never permits source reuse or direct-mode
fallback. Late region deadlines are re-sampled against panel scanout.

The rendering/backend qualification includes panel readback, browser/player
slides, region updates, odd geometry and canvas mutation after snapshot
preparation. The player uses screen cuts and prepares its initial full snapshot
before audio starts. UI work is preemptible by the output task. Rendering and
DMA-source ownership remain independently tested portable policies.

## Media support

| Format | Current native decoder |
|---|---|
| FLAC | Mono/stereo, 4–24-bit; CRC, fixed/LPC, Rice/Rice2 and stereo modes |
| WAV | Mono/stereo PCM 8/16/24/32-bit; extensible valid bits; IEEE float32/64 |
| AIFF | Mono/stereo signed PCM up to 32-bit, including non-byte-aligned precision |
| AIFF-C | NONE/twos/sowt PCM and fl32/fl64; other compression types rejected |
| MPEG audio | Layers I/II/III, MPEG-1/2/2.5, free format and Xing/LAME trim |
| AAC/M4A | AAC in bounded MP4 sample tables; edit/presentation trimming |
| ALAC/M4A | Mono/stereo 16/24-bit in MP4 |
| Ogg Vorbis | Continued packets, CRC validation and compatible chained streams |
| Ogg Opus | Preskip/end trim and compatible chained streams |
| Raw ADTS AAC, WavPack, Musepack | Not implemented |
| DSD, multichannel downmix, resampling | Not implemented |

The browser filters supported file extensions; the decoder detects content.
Every format shares stop/previous/next/volume controls. Mono duplicates into
stereo. Native integer sources up to 24-bit retain exact samples; higher
precision is reduced to 24-bit with deterministic TPDF dither at final output.
NaNs become silence and out-of-range float values clip. PCM conversion uses
integer operations and caller-owned buffers. C codecs allocate from a bounded,
caller-owned arena and release their allocations on completion or cancellation.

Third-party codec implementations are pinned, unmodified sources under `vendor/`.
All gain-owned adapters, allocation/runtime services and safety checks are Zig.
The build translates upstream C headers into Zig declarations. The ALAC adapter
binds the pinned decoder's non-virtual C++ ABI and checks audio element lengths
before decoding; its zero-denominator predictor cases are handled in Zig.
The desktop SDL adapter is also Zig.

DMA periods are 10 ms, or 20/40 ms at 22.05/11.025 kHz to preserve integral
native-rate frames. Startup primes PCM before playback. EOF clears cyclic
buffers with silence before the output FIFO drains. Linked-descriptor interrupts
wake output directly; a one-period watchdog bounds a missing notification.

MP4 has direct sample lookup. MP3, FLAC and Ogg decoder seeking currently
replays from the beginning; the player UI provides track navigation rather than
scrubbing. MP4/Ogg title parsing is available to decoder callers. Full ID3,
artist/album, ReplayGain and artwork integration remain incomplete. Analogue
noise/distortion, switching quality and battery savings require separate
measurement or listening tests.

PMIC telemetry does not fabricate measurements when an ADC is disabled or I2C
fails. Jack GPIOs are explicitly configured as inputs before their levels are
used. The charge-current API can only reduce the existing setting; it does not
negotiate a USB current budget or change battery voltage settings. Bluetooth
transport/A2DP, native USB mass storage/audio, RTC, PWM brightness and suspend
are not implemented. USB development currently uses the X1000 ROM interface.

## Player qualification

`mise run check` builds both firmware images and the RAM qualification image,
runs the deterministic codec, storage, scheduling, presentation and application
controller tests, and checks the host USB runner with a mocked transport.
Upstream C/C++ decoders remain vendored; all gain-owned bridges are Zig.

The physical player checks use the same folder browser, player controller,
renderer, decoder pipeline and memory factory as the interactive firmware.
The runner uploads only RAM, returns to the USB ROM loop after each campaign,
and initializes DRAM only when the PHY reports a cold state. It never writes
flash or the SD filesystem. Python 3 and the existing X1000 `usbboot` host tool
are required for these optional hardware checks.

```sh
GAIN_USBBOOT=/path/to/usbboot mise run check-player-f20 -- --output /tmp/gain-player-matrix
GAIN_USBBOOT=/path/to/usbboot mise run check-player-f20 -- --mode mixed --repeat 3 --output /tmp/gain-player-mixed
GAIN_USBBOOT=/path/to/usbboot mise run check-player-f20 -- --mode sd --seconds 180 --output /tmp/gain-player-sd
GAIN_USBBOOT=/path/to/usbboot mise run check-player-f20 -- --mode sd-fault --seconds 12 --output /tmp/gain-player-fault
```

The matrix uses synthetic fixtures with known frame counts and rates, and
compares device PCM checksums with the host decoder through the same pipeline.
The host decoder is separately checked against independent sample references. Mixed
mode replays every fixture in the same process to exercise format/rate changes,
allocator cleanup and task reuse. SD mode browses the actual card and chooses a
supported file of at least 32 MiB; it requires the file to last for the requested
duration. Fault mode injects a read error after playback starts, exercising the
production cancellation and mute path without requiring physical card removal.
`--mode stop`, `next`, `previous` and `truncated` provide focused checks;
`--fixture` selects one fixture. Reports, image hashes and JSON results must be
saved outside the source checkout. The image and report reader are rebuilt by
default; `--skip-build` is only for an already-built qualification image.

Fixture regression ceilings are 25% of one DMA period for refill, 256 KiB of
requested decoder heap, 500 ms to DMA start, 10 ms per UI callback, 35 ms
between UI callbacks, 50 microseconds per interrupt handler, and at least 4 KiB
free in each task stack. These are fixture budgets, not limits claimed for all
possible media. Production checks stack bounds at dispatch and stack fences at
session completion; full stack painting is enabled only for qualification.

The 32-fixture device campaign measured a worst startup of about 241 ms, refill
of 1.02 ms, UI callback of 5.3 ms and UI interval of 22 ms. Maximum codec stack
usage was below 69 KiB and UI stack usage below 10 KiB. A 96-track mixed-format
campaign and a separate 180-second, 96 kHz real-SD/UI run completed without
underruns; the latter completed 18,003 output periods. Injected SD read failure
returned `CardRemoved`, and subsequent playback succeeded. These checks do not
establish physical hot-removal behaviour or analogue audio quality.

## Development

Install [mise](https://mise.jdx.dev), then install the pinned Zig toolchain and
run the complete project check:

```sh
mise install
mise run check
```

Useful individual tasks are `mise run format`, `mise run lint`,
`mise run build`, `mise run test`, `mise run fuzz` and `mise run bench`. The
lint task checks canonical Zig formatting and runs Zig's AST validation. The
complete check then builds both firmware images and runs the host-side tests.
The separate fuzz task runs at least 100,000 generated cases against the SPL
image builder, WAV parser and FLAC metadata/frame decoder.

`mise run test-ui` runs deterministic presentation, coordinator, rendering and
geometry tests in Debug and ReleaseFast. It is also part of `mise run check`.
`mise run fuzz-ui` runs 100,000 generated region/alignment/canary cases from a
single fuzz corpus owner. The general `mise run fuzz` includes these alongside
parser fuzzing.

### Desktop simulator

The generic F20 simulator loads a native app module, presents its 320 x 240
RGB565 screen and forwards wheel/button events. It contains no music library,
theme selector or navigation model. UI experiments and mock media stay outside
the production repository. The host does not simulate the CPU, panel scanout,
audio hardware or SD controller.

Install SDL3 and build the optional host:

```sh
mise run build-sim
zig-out/bin/gain-sim --app /absolute/path/app.dylib --watch
```

`SDL_PREFIX=/opt/homebrew/opt/sdl3 mise run build-sim` selects a different SDL3
prefix on macOS. `mise run sim` also runs an app when `GAIN_SIM_APP` is set.
Firmware builds and the ordinary host tests do not require SDL3.

The framebuffer uses the production UI's geometry and RGB565 representation.
The host chooses the largest integer scale fitting the **physical renderer
pixels**, including Retina/fractional desktop densities, and letterboxes the
result. Texture filtering is nearest-neighbour. Pixels stay square and uniformly
sized; desktop DPI is not a claim about the F20's physical screen size.

| F20 input | Desktop input |
|---|---|
| Wheel backward/forward | Mouse wheel or Up/Down (K/J) |
| Play/centre | Enter or Space |
| Back | Esc or Backspace |
| Menu | M |
| Previous/Next | `[` / `]` |
| Volume up/down | `+` / `-` |
| Power | P |

Button events include press, release and repeat. Wheel fractions accumulate
rather than rounding every trackpad sample up. Focus loss releases held inputs;
keyboard aliases release only after their final source. F5 reloads the current
module. `--watch` reloads rebuilt module files after their size/time stamp settles.

Apps export `gain_app_api`, returning `simulator.Api` from
[src/simulator.zig](src/simulator.zig). Its ABI version, structure size, geometry,
format and callbacks are validated before activation. `init` and `input` receive
monotonic milliseconds; `frame` writes native pixels and reports whether they
changed. Optional paired `save`/`restore` callbacks preserve app state up to
64 KiB. Save must leave the running app intact; restore validates its own state
format, including an empty snapshot if save returns zero. A rejected, oversized
or incompatible snapshot retains the running app.
Snapshots must serialize data rather than retain pointers into the old module.
Apps without snapshot callbacks restart on reload. Optional `deinit` releases
app-owned resources before unloading, including candidates whose restore failed.

An app using gain's renderer should import **one** module rooted at
`src/ui_api.zig`, then use that module's `.ui` and `.simulator` exports. This
avoids duplicate ownership/type identities for the shared UI sources. Apps that
only need the pixel/input contract may import `src/simulator.zig` directly. The
module ABI is desktop development tooling, independent of any future firmware
extension system.

For source-triggered rebuilds, the stdlib-only Python helper runs an argument
list without a shell and preserves the old app after build/reload failures:

```sh
python3 tools/sim.py run --app /absolute/path/app.dylib \
  --project /path/to/app-project --watch /path/to/app-project/src \
  --build mise exec -- zig build
```

Watch all relevant source/asset paths with repeated `--watch`; build files and
assets are not inferred. Compiler outputs and caches are excluded. Host source
changes require rebuilding and restarting the host.

The native host prints its private control directory. `--control-dir PATH`
chooses a **new** directory explicitly; an existing directory is rejected so two
instances cannot consume the same commands. Commands and screenshots do not
require accessibility permission:

```sh
python3 tools/sim.py control --directory /printed/session input --button volume_up
python3 tools/sim.py control --directory /printed/session input --button select --phase press
python3 tools/sim.py control --directory /printed/session input --button select --phase release
python3 tools/sim.py control --directory /printed/session capture --path '/tmp/native screen.bmp'
python3 tools/sim.py control --directory /printed/session capture --window --path /tmp/window.bmp
python3 tools/sim.py control --directory /printed/session reload
python3 tools/sim.py control --directory /printed/session quit
```

Requests/responses are atomic UTF-8 JSON with explicit success/failure and
geometry in physical pixels. There is one in-flight request per instance. A
retry with the same request ID repeats the last response without applying the
input twice; retry before issuing a different command. Failures are never
reported as successful captures or reloads. Module copies live in the instance
directory and are removed when unloaded. The final response remains readable
after clean shutdown; the Python run helper owns and cleans its temporary tree.

`--headless --capture FILE.bmp` captures one native frame and exits. Native
captures exclude window scaling; `--window` captures the composed renderer,
including letterboxing. These are UI pixels, not a simulation of LCD timing.

`mise run sim-check` tests real dynamic module loading, every input/phase,
request retry IDs, rejected ABI/entry points, transactional restoration failures,
actual changed-code reload, independent instances, Unicode paths, capture errors
and exact pixel scaling using an every-pixel RGB pattern. It runs headlessly
with SDL3. `zig build test-sim -Dsim-visible=true` repeats qualification with a
native window and its actual display density. The SDL-independent policies and
Python transport/watcher tests also run in `mise run check`; `mise run fuzz-sim`
fuzzes bounded JSON requests with at least 100,000 generated cases.

`mise run bench-ui-f20` runs a RAM-only physical UI qualification and returns to
the ROM USB loop. Use `GAIN_SKIP_SPL=1` only when DRAM is already initialized.
`GAIN_USBBOOT` selects the host USB tool, and `GAIN_UI_REPORT` optionally saves
its report. The host reader rejects incomplete campaigns, pixel mismatches and
performance regressions: full rendering/live slides at most 3 ms, full snapshot
preparation at most 5 ms, region rendering plus preparation at most 3 ms, and
full-frame DMA at most 18 ms. These are isolated-job ceilings, not an end-to-end
animation or concurrent audio guarantee. The runner writes no persistent
storage and leaves ROM USB untouched during the bounded campaign.

`mise run bench` measures FLAC decoding, PCM packing and LPC reconstruction on
the host. `mise run bench-f20` runs the corresponding benchmarks and the
physical SD read-ahead path on a connected F20 in the mask-ROM USB loop. Device
results include the minimum, median, p95 and maximum time as a fraction of a
16,384-frame 192 kHz playback interval. The performance target is at most 70%
for the maximum refill, with 75% as the enforced release ceiling. The default
device suite is read-only and returns to the ROM USB loop after every case.
Cached-output and synchronous sustained-SD probes are opt-in because they test
cache coherency and the superseded blocking storage path.

After one successful suite, the F20 remains in the ROM USB loop with DRAM
initialized. All hardware runners inspect the PHY and skip training when DRAM
is already warm. `GAIN_SKIP_SPL=1` additionally refuses cold training for an
explicitly warm-only benchmark invocation; an unexpected PHY state is rejected.

The build places these images in `zig-out/bin`:

| Image | Purpose |
|---|---|
| `gain-spl.bin` | X1000 ROM image with a 2 KiB boot header |
| `gain-spl.raw` | Unwrapped TCSM code |
| `gain-stage2.bin` | Flat DRAM image loaded at `0x80004000` |

## Automatic USB transfer

Connecting to a USB host automatically stops playback and exposes the microSD
as a standard USB mass-storage disk, including in Finder. Player, decoder and
storage workers finish before the host can read or write sectors. The device
shows “USB CONNECTED”; eject the disk on the computer to return to the player.
Playback stays stopped. Volume and the deepest surviving folder/selection are
preserved. Paths are resolved by name against a fresh FAT32 mount, never by old
cluster numbers or cached directory entries.

The cable can remain connected after eject: the device returns to normal use
and USB power remains available. Charging enable, target voltage and current
settings are preserved; a full battery can report no active charging. Gain does
not yet negotiate a different charging-current policy. Charger-only connections
leave the player usable. A USB bus reset or suspend does not release ownership.
After eject, host polling and bus resets cannot automatically re-export the
card; unplug and reconnect the cable to transfer again. Eject before unplugging
so the host can flush its own filesystem cache.

The implementation uses a pinned TinyUSB device/MSC/DWC2 subset and Zig board
hooks and callbacks. The F20 port uses high-speed USB with bounded 4 KiB sector
buffers and CPU FIFO transfers; it does not depend on USB DMA cache coherence.
SD writes wait for programming completion and CMD13 card-ready status before
acknowledgement. Failed card I/O latches an unavailable medium until the next
ownership transition. `0xa108:0x1002` is a development USB identity; a distributed
hardware product needs an assigned identity.

`mise run test-usb` exercises the production class, callbacks, storage policy,
fragmented I/O, injected faults and eject status ordering in Debug and
ReleaseFast. The default host suite includes these tests. On macOS, with an F20
in mask-ROM mode, run:

```sh
GAIN_USBBOOT=/path/to/usbboot mise run check-usb-f20 -- --output /path/outside/gain/usb-check
```

This path has passed the complete qualification on an F20 V2.7: real SD-fed
playback stopped, no host bytes transferred before worker shutdown, both eject
cycles remounted cleanly, device and fresh-host readback agreed, test files were
removed, and USB power/charging enable remained set.

The RAM-only qualification executable first plays an existing supported track
(at least 2 MiB, at very low volume) and verifies that USB configuration stops
playback and joins its workers before any host sector access. It then exposes
the real SD card. Its host runner
checks USB identity, physical port, card capacity and filesystem before creating
a new `.gain-usb-check` directory; an existing directory is refused. It copies a
1 MiB pattern, tests Unicode create/rename/delete, ejects, verifies the file
through the device’s freshly mounted FAT reader, reconnects and verifies SHA256
on a fresh host mount, removes only its own test files and ejects again. It
checks the ownership latch, live player loop, USB power and charging enable,
then returns to ROM. On failure, it leaves evidence and any test files for
inspection rather than deleting unknown data. No formatting or flash writes
occur. Narrow diagnostic control requests are linked only into this separate
qualification image, not the release player.

## Hardware boundary

The source keeps SoC and board knowledge separate without a runtime HAL:

| Source | Responsibility |
|---|---|
| `src/x1000.zig` | Typed X1000 MMIO registers, fields and peripheral primitives |
| `src/f20_v27.zig` | F20 V2.7 wiring, panel data and verified LPDDR profile |
| `src/f20.zig` | Compile-time F20 device facade used by product code |
| `src/sd.zig` | Native X1000 SD controller |
| `src/fat32.zig` | Portable allocation-free FAT32 reader |
| `src/wav.zig` | Portable bounded RIFF/WAVE parser |
| `src/pcm.zig` | Portable allocation-free WAV PCM to DMA frame conversion |
| `src/flac.zig` | Portable allocation-free native FLAC frame decoder |
| `src/flac_pcm.zig` | Portable FLAC stream to fixed DMA chunk conversion |
| `src/audio.zig` | Native AIC, ES9018K2M and linked-PDMA output |
| `src/media_decoder.zig` | Shared WAV/AIFF/FLAC/MP3/AAC/ALAC/Vorbis/Opus producer and canonical PCM contract |
| `src/input_stream.zig` | Bounded storage producer, codec consumer and acknowledged seeks |
| `src/executive.zig` | Portable task priorities, event latching and deadlines |
| `src/task_dispatch.zig` | Shared context and trap transitions |
| `src/codec_pool.zig` | Caller-owned bounded C decoder allocations |
| `src/playback.zig` | Portable buffer lifecycle and descriptor state machine |
| `src/f20_media.zig` | Shared playback status and control types |
| `src/f20_player.zig` | F20 task wiring, memory factory, cancellation, output and control ownership |
| `src/spl.zig` | Ordered clock and DRAM initialization flow |
| `src/ui.zig` | Bounded declarations, text ownership, clipping, themes and live slide rendering |
| `src/player_view.zig` | Portable browser/player views and hybrid browser damage |
| `src/player_presenter.zig` | Portable initial preparation and asynchronous playback update coordination |
| `src/presentation.zig` | Portable DMA source ownership, geometry expansion and snapshot packing |
| `src/display_phase.zig` | Tested scanline projection and conservative F20 region windows |
| `src/f20_display.zig` | F20 panel I/O, calibration and LCD DMA adapter |
| `src/file_browser.zig` | Shared folder navigation, filtering, selection and rendering |
| `src/player_screen.zig` | Shared playback input and view controller |
| `src/task_stack.zig` | Stack bounds, fences and optional high-water measurement |
| `src/main.zig` | Device behavior and diagnostics |

Small register and pin operations are explicitly inlined. Fixed LPDDR writes
use compact data tables, while waits, read-modify-write operations and ordering
boundaries remain imperative. Opaque panel and DRAM values are kept together
as named, board-specific profiles.

The SPL has a 10 KiB code limit imposed by both the linker and image packer.
Stage two has a 2 MiB link region. `src/f20_memory.zig` owns the physical RAM
reservations for firmware, display, storage, decoder scratch, PCM and task stacks.
Linker assertions reject code/BSS overflow; compile-time region checks reject
overlap, including cached/uncached aliases.

## Simulation

Simulation targets portable policy and feeds the same modules used on device:

| Test | Boundary |
|---|---|
| `tests/playback_sim.zig` | DMA/FIFO timing, refill interleavings, descriptor wraps and frame order through `src/playback.zig` |
| `tests/storage_sim.zig` | MBR, fragmented FAT32 files and WAV chunks through `src/fat32.zig` and `src/wav.zig` |
| `tests/media_pipeline_sim.zig` | Fragmented WAV input, irregular reads, exact PCM frames, partial EOF and buffer recycling through the complete portable media path |
| `tests/flac_sim.zig` | 24-bit/192 kHz decoding, exact F20 buffer bounds, measured decode deadlines and missed-event rejection |
| `tests/flac_pipeline_sim.zig` | FAT32 FLAC input, SD DMA alignment, bounce buffering, exact PCM chunks and captured device timing |
| `src/presentation.zig` tests | Four captured LCD truncation images, delayed FIFO drain/ACK, source lifetime, faults, timeout, timer wrap and event pressure |
| `src/player_presenter.zig` tests | The actual player coordinator against deterministic delayed DMA, concurrent volume/progress updates, priority/coalescing and failure propagation |
| `src/player_view.zig` tests | Every slide offset against independent pixel composition, region/full render equivalence, selection damage, themes and bounded maximum metadata |
| `src/ui.zig` tests | Relocatable text, capacity failure atomicity, widget/surface clipping and canaries |
| `tests/codec_stream_tests.zig` | 32 fixtures; independent PCM references, trim/seek/reset, fragmented reads, cancellation, card removal and allocation cleanup |
| `tests/codec_pipeline_sim.zig` | Production buffered input, decoders, PCM reservoir and DMA packing under three seeded storage schedules per fixture |
| `tests/container_fuzz.zig` | MP4 atoms, offsets, sample cursors, Ogg pages/continuations and output canaries |
| `tests/ui_fuzz.zig` | Generated even-width expansion, packed row correctness and destination canaries |
| Inline source tests | Register encodings, clock ratios, descriptors and other pure hardware facts |

`mise run test-codecs` checks the shared producer in ReleaseSafe and ReleaseFast
and links every engine for freestanding MIPS. `zig build check-codecs-f20` runs
that compile/link gate alone; its image has no hardware startup and is never
installed or deployed.
`mise run test-pipeline` checks executive/input/output policy in Debug and
ReleaseFast. `mise run fuzz-codecs` runs separate 100,000-case campaigns for
PCM/WAV/AIFF, MP4 and Ogg. Ordinary `mise run check` includes the fixed fuzz
corpora; extended fuzzing is explicit.

The shared multi-codec path is enabled in the device player. Scheduler/FPU,
codec fixtures and SD/UI concurrency also have RAM-only hardware qualification.
Host simulations control event order; they do not emulate CPU instruction timing
or establish battery consumption. Longer field use and power measurements remain
separate qualification work.

The tests do not emulate the X1000. MMIO sequencing is checked by compiling
the concrete F20 specializations and by RAM-only tests on the physical device.

## RAM boot

The development boot uses the X1000 mask ROM and a compatible `usbboot` host
tool. It does not modify storage. Run the SPL command only after a cold reset;
never retrain DRAM while reusing a warm ROM USB session.

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

gain is released under the [MIT License](LICENSE). Vendored code retains its
upstream notices; pinned sources and local changes are listed in `vendor/sources.json`.
