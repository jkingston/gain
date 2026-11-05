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
- music home, album Cover Flow, album track lists, now-playing and folder browsing;
- DAC hardware volume and bounded, priority-aware display updates;
- a watchdog-backed panic screen.

The player uses separate preemptive output, UI, control, codec and storage tasks.
Compressed input arrives in SD bursts, decoding publishes canonical Q1.31 PCM,
and output fills fixed-duration DMA periods. Only control performs DAC I2C.
Only the storage task reads the card during playback. The firmware has no NAND write path.
When audio is stopped, the application can overwrite existing, host-provisioned
cache/log allocations; it cannot allocate clusters, resize files or change FAT
directories. USB mode grants the computer exclusive raw SD access.

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

The music interface shares a portable controller, RGB565 rasterizer, font masks
and Cover Flow geometry with host adapters. The F20 adapter supplies display
presentation, library projections, artwork requests and measurements through
compile-time interfaces. Drawing never opens files or allocates memory. Folder
browsing retains its declarative renderer; choose Folders from Music and press
Menu to return.

Cover Flow uses seven perspective-projected covers, a 128 × 128 prepared front
cover, restrained reflections and centred captions. Storage prepares artwork
once into a twelve-slot column-major cache, prioritising the visible covers and
destination. Prepared entries include artwork identity, so retagged art reloads
without changing album selection. Bad tiles use a cached fallback and do not
block other covers; changed art or a remount permits another load.
Disk validation, unpacking and filtering yield in bounded chunks
when idle; during playback the executive preempts storage work for audio/UI.
Headers and captions retain their pixels between animation frames. The default
projection supports 8,192 tracks and 1,024 albums; a limit failure retains the
previous published view.

The font masks retain their original coverage, advances and layout boxes while
omitting transparent padding. Source fonts, OFL notices, rasterizer versions and
hashes are in `assets/fonts`, including the pinned Noto fallback bitmap. `tools/build_fonts.py` regenerates the atlas with
Pillow; normal builds use the committed masks. Unavailable glyphs use `?`.

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

## Library and diagnostics

The native application scans FAT32 after mounting the card or returning from USB.
Quick refresh compares paths, sizes and FAT modification stamps; verify rereads
metadata and artwork. FAT timestamps are coarse: use verify for edits that keep
both size and timestamp. Scans publish first at 32 tracks, then in batches of 128, at most once every
300 ms; completion publishes the final view. Selection follows stable track and
album identities through insertions. Display track order follows disc/track tags
and then natural filename order, independently of the path-sorted scan records.
A cancelled or incomplete enumeration keeps the previous catalogue. Selecting music or Folders interrupts an idle scan; the scan can
resume under storage ownership during playback. Preview and artwork references
are withdrawn before cancelled scan memory is reclaimed. Per-file parse failures retain previous known tags and record the error.
FAT starting clusters are mount-local locators, never persistent track identity.

Library tags currently cover MP4/AAC/ALAC and FLAC. Other decoded formats use
filename/folder fallbacks. Album grouping uses album artist, release identity and
edition folders; multi-disc folders share an album. Sidecar/embedded baseline
JPEG covers are streamed to bounded 112 × 112 RGB565 tiles. Progressive JPEG,
PNG, EXIF orientation and colour-profile conversion are not implemented by the
native artwork path. Playback codec support is listed separately below.

The catalogue has two checksummed generations, with payload committed before its
header. A failed save leaves the previous bank selected. Artwork tiles also
publish headers last. Cache sizes are fixed, and a missing/full cache disables
persistence rather than creating files in firmware. During playback, catalogue generations stay pinned until workers join, and the
scanner uses separate reserved memory. Background SD work requires at least
500 ms of buffered PCM. Artwork changes and catalogue writes wait for idle
storage ownership; a quick refresh then completes deferred artwork. Now Playing
and pending selections own their metadata independently of catalogue lifetimes.

To provision the files while the identified Gain SD card is mounted:

```sh
python3 tools/gain_metrics.py provision --sectors CARD_SECTOR_COUNT
```

This creates `.gain/catalog.bin` (12 MiB plus a 4 KiB prefix), `artwork.bin`
(16 MiB plus prefix) and `diagnostics.bin` (8 MiB plus prefix). Existing unknown
files and incomplete allocations are refused. It never formats or deletes music.

Diagnostics use a fixed 32 KiB RAM ring and 4 KiB checksummed binary pages.
Playback, indexing and USB transitions emit summaries. Power is sampled every
10 seconds and summarized once per minute; voltage/current validity is explicit.
Hardware coulomb deltas require unchanged ADC configuration and plausible counts.
Measurement enables battery/VBUS voltage and current ADC channels, preserving
the ADC rate, charging settings and rail voltages.
Repeated faults are coalesced, with at most 16 distinct fault records per boot.
The page header carries repeated/dropped counts. Logging stops for that mount on
write failure; decoder, interrupt and rendering paths never write log records.

Log writes occur after playback workers have joined, on idle checkpoints, or
before handing SD to USB. They never run while the host owns the card. The ring
uses alternating cursor sectors; its provisioning header is immutable. Inspect
valid pages even if the latest cursor update was interrupted:

```sh
python3 tools/gain_metrics.py logs /path/to/diagnostics.bin
```

Records contain a build identity, boot session, monotonic 6 MHz timestamps and
bounded numeric fields. Index summaries include track/album counts, parsed/reused
records, phase durations, physical SD reads/writes, I/O time, allocator usage,
cache preparation/reuse and changes. Playback summaries include startup, fill/UI/
interrupt maxima, FIFO minimum, underruns, heap peak and time attributed to each
task. PMIC current/coulomb measurements need hardware qualification; they are not
calibrated battery-life or instantaneous CPU power measurements.

`zig build instrumented -Dbuild-id=NUMBER` builds the same player with optional
RAM-development controls. `tools/gain_metrics.py status`, `quick`, `verify`,
`play --value TRACK_INDEX`, `stop`, `flush`, `reconnect` and `rom` allow bounded
semantic testing after eject. Commands commit only after their USB ACK. This
interface has no arbitrary memory write or execute operation; the normal release
build omits it. A zero build identity means unspecified; evidence should also
retain the image SHA-256. Experiments and captured reports belong outside this repo.
The development ROM handoff resets the controller and enters the ROM afresh;
the uploader waits for the X1000 identity and verifies every uploaded RAM byte
before starting the player. Detailed display traces exist only in instrumented
builds. Normal builds omit their recorder and maintenance controls.

RAM-only music/UI qualification (use a catalogue track longer than the scan):

```sh
mise run check-music-f20 -- --output /path/outside/gain --track TRACK_INDEX \
  --build-id BUILD_NUMBER --usbboot /path/to/usbboot
```

This exercises idle/playback/indexing Cover Flow, volume transitions, progressive
scan completion, deferred artwork, folder browsing and return to Music. It saves
image identity, exact RAM verification, frame traces, scan outcomes and pacing
gates outside the checkout. Active-animation timing keeps real stalls visible;
explicitly observed idle gaps are reported separately. Gates require enough
motion samples and constrain median, 95th-percentile and worst submission gaps.
The check may update Gain's preallocated cache/log files. It does not modify music
or NAND. Display submissions are measured; panel scanout and acoustic quality
still need separate observation.

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

The player app also exports `gain_player_environment(millivolts, charging, usb)`
for UI fixtures: `0` mV means unknown; USB `0` resumes music and `1..3` select
connecting, connected and finishing. This belongs to the player app, not the
simulator host. Battery fill uses four coarse voltage levels, not a calibrated
percentage; charging is indicated separately.

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

The production player UI is one optional app for this host. Build it separately;
the simulator itself has no player dependency:

```sh
mise run build-player-ui
python3 tools/mock_sd.py /tmp/gain-sd
GAIN_SD_ROOT=/tmp/gain-sd zig-out/bin/gain-sim \
  --app zig-out/lib/libgain-player-ui.dylib --watch
```

Use `.so` instead of `.dylib` on Linux. `GAIN_SD_ROOT` accepts any directory,
including a mounted SD card or a real music folder. The adapter reads it through
the production scanner and native tag readers, publishing progressive views on
a background worker. It does not write to the supplied root. Playback uses a
test transport clock; this app does not produce audio or emulate device timing.
Artwork currently uses the renderer's missing-cover fallback.

The mock-card generator uses synthetic encoded audio, fictional multilingual
tags, cover images, a playlist and preallocated firmware cache files. Generated
cards must be outside the repo. `--mount /path/to/files` can add real files or
folders through symlinks; the adapter still opens them read-only. No personal
paths, collection data or generated cards are needed by repository tests.
`GAIN_UI_CATALOG` optionally supplies external catalogue JSON when no SD root is
set; it is a fixture input, not the normal library-discovery path.

`mise run test-player-ui` tests the actual controller/app with a generated card
and mounted synthetic files, without SDL. An optional local collection check is:

```sh
python3 tools/check_player_ui.py --app zig-out/lib/libgain-player-ui.dylib \
  --sd-root /path/to/music
```

Start each new UI experiment from the current production player at a recorded
commit, in a disposable checkout. Run that app in the generic host and bring
proven changes back; a separate lab player is not a maintained reference UI.

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

`mise run bench-firmware` measures production library projection, cold/warm
in-memory scans, catalogue persistence, artwork lookup/preparation, text,
Cover Flow, display packing, PCM output and all 32 codec fixtures. It emits
newline-delimited JSON with nine trials per timing case, a warm-up, batched
repetitions and checksums. Scratch high-water measurements use a fixed allocator;
catalogue memory reports arena capacity. Inputs are synthetic and no SD root is
read or changed. This optional target does not enter the firmware build.

Run timing measurements alone on an idle host. Compile first with
`zig build build-bench-firmware`, then run `zig-out/bin/bench-firmware` separately. Compare repeated runs on the same machine/build mode; there are no
machine-dependent nanosecond thresholds in unit tests. Resident-cover player
rendering, scan-only header updates, satisfied cover-queue polls and cooperative
projection builds have separate cases. Batched times retain fractional nanoseconds
for very small steady-state operations. These host numbers do not
establish F20 frame rates, SD/USB throughput, audio deadlines or battery use.

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
hooks and callbacks. The F20 port uses high-speed USB with bounded 32 KiB sector
buffers and controller DMA. USB buffers occupy a reserved 128 KiB uncached
identity-mapped window: CPU pointers are physical addresses, and SD uses its
uncached alias of the same memory. Whole aligned sectors pass directly between
controllers; partial or foreign buffers use the bounded bounce path. One TLB
entry (31) is reserved while USB is initialized. The original entry and CP0
state are preserved, and the USB core is stopped and reset before restoring
the mapping for ROM handoff. Upstream C sources are unchanged; the mapping,
sector policy and bridges are Zig.
SD writes wait for programming completion and CMD13 card-ready status before
acknowledgement. Failed card I/O latches an unavailable medium until the next
ownership transition. `0xa108:0x1002` is a development USB identity; a distributed
hardware product needs an assigned identity.

`mise run test-usb` exercises the production class, callbacks, storage policy,
fragmented I/O, shared-buffer bounds, mapping lifecycle, reset timeouts,
injected faults and eject status ordering in Debug and
ReleaseFast. The default host suite includes these tests. On macOS, with an F20
in mask-ROM mode, run:

```sh
GAIN_USBBOOT=/path/to/usbboot mise run check-usb-f20 -- --output /path/outside/gain/usb-check
```

The qualification checks that real SD-fed playback stops before host sector
access, both eject cycles remount cleanly, device and fresh-host readback agree,
only the test files are removed, and USB power/charging enable remains set.
On an F20 V2.7, a 64 MiB run measured 8.41 MB/s writing and 10.51 MB/s reading
from a fresh host mount. SHA-256, independent native FAT readback, direct-buffer
counters and automatic ROM return passed. These are measured filesystem rates
for that card and run, not a USB bus-speed guarantee.

The RAM-only qualification executable first plays an existing supported track
(at least 2 MiB, at very low volume) and verifies that USB configuration stops
playback and joins its workers before any host sector access. It then exposes
the real SD card. Its host runner
checks USB identity, physical port, card capacity and filesystem before creating
a new `.gain-usb-check` directory; an existing directory is refused. It copies a
16 MiB position-varying pattern by default (`--transfer-mib 1|16|64`),
tests Unicode create/rename/delete, ejects, verifies the file
through the device’s freshly mounted FAT reader, reconnects and verifies SHA256
on a fresh host mount, removes only its own test files and ejects again. It
checks that DMA and direct-buffer reads/writes were exercised, the ownership
latch, live player loop, USB power and charging enable,
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
| `src/x1000_dma.zig` | Reserved uncached identity mapping with saved/restored CPU state |
| `src/usb_core_reset.zig` | Bounded USB DMA reset policy with deterministic driver tests |
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

Interactive library rebuilding services storage/UI between track batches and
sort comparisons. The published view remains immutable while the other slot is
prepared; cancellation never commits a partial sort. The native adapter can keep
compressed input supplied and service idle UI work at those points. Ordinary
non-cooperative builds erase the observer. Work-unit intervals are not a device
wall-clock guarantee; elapsed publication metrics include time spent servicing
other work.

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

## Language fonts

The player uses its embedded atlas for simple text and recovery screens. Other
metadata uses pinned HarfBuzz 15, FreeType 2.14.3, SheenBidi and utf8proc 2.11:
Unicode 17 bidi/script resolution, grapheme fallback, OpenType shaping and
hinted grayscale masks. Joining text is reshaped after ellipsis; RTL ellipsis
lands at the visual end. Original metadata is preserved. Emoji is monochrome.
The language pack contains Inter, Newsreader and 172 Noto families, covering
73,388 codepoints. This is broad practical coverage, not every Unicode glyph.
The exact font sources, checksums and notices are in `assets/fonts/languages.json`.

Fonts live at `.gain/fonts/fonts.bin`. Build the pack with Python and
`fonttools==4.61.1`; the source cache can be anywhere outside the repository:

```sh
python3 tools/build_font_pack.py --download --cache /tmp/gain-font-sources \
  --output /path/to/sd/.gain/fonts/fonts.bin
mise run build-text
cp zig-out/bin/engine.bin /path/to/sd/.gain/fonts/engine.bin
```

Keep the generated `LICENSES.txt` with the pack. Static font instances have
new internal family names and retain upstream notices. `--test-subset` builds
only the generic repository fixture; it is not an installed language pack.
The fixture is rebuilt with `--test-subset --retain-full NotoSansDuployan` to
retain a real, large-table memory regression case.
The simulator app opens the same pack under `GAIN_SD_ROOT`, or an explicit
`GAIN_FONT_PACK=/path/to/fonts.bin`. Its host remains independent of fonts/apps.
The cache's `locale` selects Japanese, simplified Chinese, traditional Chinese
or Korean Han forms; automatic uses Japanese forms where available, then the
coverage fallback. This affects glyph forms, not metadata or sorting.

The native text engine is a separate, fixed-address SD component. The core boot
image stays within its existing 2 MiB reservation. The loader validates the
component version, addresses, length and CRC before execution. The build gate
checks the ELF for memory bounds, OS syscalls, TLS and constructors. No OS
startup runs. All authored adapters and runtime helpers are Zig. Missing or
invalid packs retain the embedded text path and do not prevent boot/recovery.

Only the storage owner shapes and rasterises. Twelve immutable label slots,
two open font faces, a 128 KiB page cache, a resident coverage index and fixed
960 KiB / 232 KiB allocation pools bound memory use. Large layout tables use
the primary pool; small objects use the auxiliary gap above the LCD snapshot.
Faces share immutable tables across UI sizes, and unusually large tables
use transient faces that are released after each prepared label, preventing
fragmentation across size changes. Allocation failure is reported rather than
silently degrading shaping. Drawing only blends masks and copies
bounded cold requests. Worker publication invalidates the affected UI; stable
frames do not reshape text. Sparse FAT checkpoints bound warm font seeks to
64 cluster steps, including fragmented cards. Audio admission, cancellation
and watchdog hooks remain active during font I/O. Font and label memory have
explicit reservations checked against audio, catalogues, USB and task stacks.

`mise run test-text` runs the official Unicode 17 bidi/grapheme vectors, direct
HarfBuzz glyph/position comparisons, multilingual rendering, cancellation,
remount, clipping and fragmented FAT tests. `mise run test-player-ui` exercises
the real app's asynchronous font worker and stable-frame cache reuse on a
synthetic card. `mise run fuzz-text` fuzzes pack/request boundaries.
`mise run bench-firmware` includes six cached multilingual rows. For a complete
pack check and exported label masks:

```sh
python3 tools/check_text.py --app zig-out/lib/libgain-player-ui.dylib \
  --pack /path/to/fonts.bin --all-families --output /tmp/gain-text-results
```

Host timing does not establish F20 frame deadlines, SD latency or power use.
New text-engine loading, the revised DMA reservations and simultaneous audio /
font preparation still require physical-device qualification.

## License

gain is released under the [MIT License](LICENSE). Vendored code retains its
upstream notices; pinned sources and local changes are listed in `vendor/sources.json`.
Source fonts and compiled glyph masks retain their SIL OFL notices in `assets/fonts`.
