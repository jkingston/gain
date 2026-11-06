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

The native player boots on a physical F20 V2.7 through the preserved factory
SPL/U-Boot and a Gain SD loader in the normal kernel slot. The build provides:

- an X1000 ROM-loadable Zig SPL;
- LPDDR initialization and a gain-owned stage-two handoff;
- a freestanding Zig runtime with exception vectors;
- a 320 x 240 RGB565 display driver;
- all buttons and both wheel directions;
- identified AXP192 power, battery/USB voltage, current telemetry and power-off;
- configured headphone/line jack inputs with debouncing support;
- native SD initialization, raw sector reads and host-exclusive writes at up to 50 MHz;
- allocation-free FAT32/exFAT traversal, seeking, long names, WAV and AIFF parsing;
- native FLAC decoding and bounded C backends for MP3, AAC, ALAC, Vorbis and Opus;
- identified ES9018K2M, filters, de-emphasis, mute and output routing;
- linked-PDMA PCM playback with source-validated buffer ownership;
- a single-column Home, album Cover Flow, artists, songs and playlists;
- occurrence-aware queue editing, song/album shuffle, repeat and related navigation;
- paused session restore, typed favourites and first-discovery album history;
- headphone-unplug pause, sleep timer and paused-idle power-off;
- DAC hardware volume and bounded, priority-aware display updates;
- a watchdog-backed panic screen.

The player uses separate preemptive output, UI, control, codec and storage tasks.
Compressed input arrives in SD bursts, decoding publishes canonical Q1.31 PCM,
and output fills fixed-duration DMA periods. Only control performs DAC I2C.
Only the storage task reads the card during playback. The firmware has no NAND write path.
The sole storage owner can overwrite existing, host-provisioned allocations
while idle or from admitted playback slack. It cannot allocate clusters, resize
files or change FAT directories. USB mode grants the computer exclusive raw SD access.

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
compile-time interfaces. Drawing never opens files or allocates memory. The
retained folder-browser component is not a Home menu destination.

Cover Flow uses seven perspective-projected covers, a 128 × 128 prepared front
cover, restrained reflections and centred captions. Storage filters loaded artwork
into a twelve-slot column-major cache, prioritising the visible covers and
destination. Prepared entries include artwork identity, so retagged art reloads
without changing album selection. Bad tiles use a cached fallback and do not
block other covers; changed art or a remount permits another load.
Replacement consumes empty slots first, then the least recently requested
unprotected entry. Obsolete loads stop at bounded read/preparation checkpoints.
The atlas reader reuses sparse seek checkpoints; exFAT contiguous streams keep
their direct seek path. The cache retains recent covers, not an entire library.
Loading prioritises the selected album and predicts the next held-button repeat
from the same navigation policy that will execute it. A smoothed completed-load
estimate bounds lookahead and avoids starting side-cover work just before a
jump. All seven visible covers stay protected, with at most three speculative
requests. Raw release/reversal updates requests without waiting for a repaint;
wheel motion uses destination priority without guessing future wheel events.
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

## SD filesystems

The player and SD loader read FAT32 and exFAT on 512-byte-sector cards, including
256 GB SDXC cards. Superfloppy, MBR and checksummed GPT layouts are supported.
exFAT supports FAT-chained and contiguous streams, UTF-16 names, its on-volume
case mapping, boot-region fallback and zero-filled reads beyond valid data.
Only revision 1.00, one FAT and the existing 32-bit media-file offsets are supported;
files larger than 4 GiB and names exceeding 192 UTF-8 bytes are omitted. This is
independent of card capacity. No formatting or filesystem allocation runs on Gain.

Cache/log overwrites require existing, fully valid sector-aligned files. exFAT
checks allocation bits, sets both boot-region dirty flags before data writes and
clears them only after sync. A dirty/damaged mount or failed write disables
further writes; playback can remain read-only. USB still grants the host exclusive
raw-card ownership and remounts from fresh directory entries after eject.

`mise run test-filesystems` exercises sparse 256 GiB images, MBR/GPT checksums,
cluster boundaries, fragmented/contiguous seek/read equivalence, valid lengths,
write faults, allocation bits and boot payload validation in three build modes.
A separate read-only inspector works with externally formatted raw images:

```sh
zig build build-filesystem-check
zig-out/bin/check-filesystem /path/to/card.img "Music/Album/Track.flac"
```

The installed loader must also support exFAT before changing card format; updating
the player SD image alone does not upgrade an older FAT32-only NAND loader.
The native driver has also read checksum-verified multilingual synthetic files
from an independently macOS-formatted 256 GiB exFAT image. Physical 256 GB card
qualification is separate from these filesystem and addressing checks.

## Library and diagnostics

The native application scans FAT32 or exFAT after mounting the card or returning from USB.
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

Library tags cover MP4/AAC/ALAC, FLAC comments, ID3v2.2/2.3/2.4 and ID3v1,
Vorbis/Opus comments, WAV INFO and AIFF text/embedded ID3. Common fields include
title, artist, album artist, album, disc/track, date, genre, compilation, artist
sort tags and ReplayGain. Missing tags use filename/folder fallbacks. Metadata
parsers bound text, tag size and traversal work; malformed files retain previous
known tags. MPEG properties require consecutive compatible frame headers;
duration remains unknown without a frame count rather than guessing from size.
Quick refresh also rereads legacy extension-only metadata for the newly supported
formats once; unchanged MP4/FLAC records remain reusable.
Opus R128 gains use the ReplayGain reference (+5 dB relative to R128); the codec
already applies OpusHead gain. Album grouping uses album artist, release identity and
edition folders; multi-disc folders share an album. Sidecar/embedded baseline
JPEG and PNG covers are streamed to bounded 112 × 112 RGB565 tiles. PNG supports
palette, grayscale, 16-bit samples, transparency and Adam7 interlacing. It uses
bounded row/pool storage and checks checksums; source dimensions are limited to
4096 × 4096, compressed input to 16 MiB, retained ancillary data to 256 KiB and
chunk traversal to 1024. Transparent pixels use a white matte in the opaque
RGB565 atlas. The upstream PNG decoder is libspng 0.7.4 with zlib 1.4; all custom
stream/allocation/resizing code is Zig. Progressive JPEG,
EXIF orientation and colour-profile conversion are not implemented by the
native artwork path. Playback codec support is listed separately below.

The catalogue has two checksummed generations, with payload committed before its
header. A failed save leaves the previous bank selected. Artwork tiles also
publish headers last. Cache sizes are fixed, and a missing/full cache disables
persistence rather than creating files in firmware. During playback, catalogue generations stay pinned until workers join, and the
scanner uses separate reserved memory. Background SD work requires at least
500 ms of buffered PCM. Artwork changes and catalogue writes wait for idle
storage ownership; a quick refresh then completes deferred artwork. Now Playing
and pending selections own their metadata independently of catalogue lifetimes.
Completed views borrow tracks and artwork from the same new catalogue. A scan
publishes that view before retiring the old catalogue, so playback transitions
and scan completion do not rebuild an unchanged view. Cancelling an unchanged
scan needs no rollback; withdrawing a published preview services the UI while
preparing its replacement.

To provision the files while the identified Gain SD card is mounted:

```sh
python3 tools/gain_metrics.py provision --sectors CARD_SECTOR_COUNT
```

This creates `.gain/catalog.bin` (12 MiB plus a 4 KiB prefix), `artwork.bin`
(16 MiB plus prefix), `diagnostics.bin` (8 MiB plus prefix), `settings.bin`
(8 KiB), `session.bin` (512 KiB), `activity.bin` (260 KiB), and
`playlists.bin` (1,284 KiB). Sizes include the prefix except where stated. Existing unknown
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
RAM counters include successful scan-view preparations, cover reads/cancellations/
evictions, and worst preparation and post-playback handoff time. Timer fields use
6 MHz hardware ticks and include time spent servicing other work; they are not
isolated CPU costs. Handoff measures catalogue finish, log flush, input resync
and display reset, excluding worker join and decoder startup. These aggregate
counters add no per-frame SD logging.
Instrumented cover traces distinguish ready covers, pending loads and completed
negative cache entries. `analyse_display_trace.py` reports readiness only for
inspected moving scenes; those are render samples, not panel captures or FPS.
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

## Playback controls and queue

Choosing a song captures the displayed album, artist or All Songs order as
stable IDs and starts at that song. Browsing elsewhere or adding albums during a
scan does not replace that queue. Next/previous and natural completion follow the
captured order; removed tracks are skipped and retags use current metadata.
The Queue view shows that captured order; selecting a queued track keeps the
queue intact. Missing entries remain visible as unavailable and are skipped by
next/previous. View publication prepares a sorted ID index, so painting queued
rows never searches the entire catalogue.
Each repeated song has its own occurrence identity. Play Next inserts an ordered
batch after the current admitted audio; Add to Queue appends. Upcoming entries
can be removed or moved next. Edits cannot reorder already buffered tracks.
Capacity failures leave the queue intact and display a message. Another explicit
song choice replaces the queue. Shuffle Albums randomises albums while retaining
disc/track order. Direct development commands and folder playback retain their
local navigation behaviour.

Provisioned sessions restore paused: canonical membership, realised playback
order, duplicate occurrence, shuffle/repeat and sample position are validated
against the mounted source. Two payload-first/header-last banks keep the preceding
queue after interrupted writes. Alternating small position sectors refer to one
queue generation; position is checkpointed every 30 seconds while playing and
at pause, track changes, USB and shutdown. A changed encoding resets its position.
Missing songs remain in the queue and available songs are resolved only after a
complete library view. Paint and input never perform persistence I/O.

Play on Now Playing toggles pause. Pause retains decoder/PCM state while emitting
silence to keep the DAC clock locked. Already queued periods complete before the
hold; the displayed cursor advances only for completed audio frames, never paused
wall time. Resume continues the retained stream. Worker ownership, cancellation
and USB handoff are unchanged. Deterministic seeded tests cover paused periods,
DMA wraps, frame order and cursor accounting.

Settings offers optional Track/Album ReplayGain, disabled by default. Album mode
falls back to track tags. Gain is computed once per track, applied in Q24 at final
output and peak-limited; missing peak data never authorizes a digital boost.
Hardware volume remains independent. Music playback uses 24-bit output to retain
precision through normalization. Changes apply at the next track start; these
settings are saved to the owned settings journal.

Natural same-rate track boundaries keep the output engine, decoder pool, PCM
reservoir and DMA running. Numeric stream markers apply per-track gain at the
exact sample boundary and update metadata after completed audio. Short tracks
share output periods. Native sample-rate changes drain and reopen; repeat wraps
and exhausted bounded lookahead also use a controlled handoff. No resampling or
silence detection is used to disguise an unknown encoder trim.

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
Every format shares stop/pause/resume/previous/next/volume controls. Mono duplicates into
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

PCM and MP4 use direct sample lookup. FLAC uses validated native seek points,
bounded frame search and opportunistic anchors; MPEG uses frame checkpoints with
decoder preroll. Ogg uses CRC-validated page/granule seeking, with a sequential
fallback for unsupported chain layouts. Three source-stamped codec and FAT seek
caches retain recent files without applying the font component's size limit to
music. Hold Previous/Next on Now Playing to preview a position and release to commit.
Seeking joins the existing workers before restarting at the requested frame;
pause remains paused across a seek. MP4/Ogg title parsing is available to decoder callers. Metadata and artwork support is described in the library section. Analogue
noise/distortion, switching quality and battery savings require separate
measurement or listening tests.

PMIC telemetry does not fabricate measurements when an ADC is disabled or I2C
fails. Jack GPIOs are explicitly configured as inputs before their levels are
used. The charge-current API can only reduce the existing setting; it does not
negotiate a USB current budget or change battery voltage settings. Bluetooth
transport/A2DP, USB audio, RTC, PWM brightness and suspend are not implemented.
Automatic native USB mass storage is described below.

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

The player app also exports `gain_player_environment(millivolts, charging, usb, external_power)`
for UI fixtures: `0` mV means unknown; USB `0` resumes music and `1..3` select
connecting, connected and finishing. This belongs to the player app, not the
simulator host. Battery fill uses four coarse voltage levels, not a calibrated
percentage. A bolt indicates charging; a plug indicates external power without
active charging. External power is supplied independently of USB storage mode.

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

Home provides Albums, Artists, Songs, Shuffle Songs, Playlists, Favourites,
Recently Added and Settings; Now Playing appears when a session exists. Lists
use one column with an overflow thumb. Artists retain both their complete song
list and individual albums. Shuffle Songs starts the entire song library;
collection actions retain their narrower scope.

Press Menu for actions; hold it for 500 ms to return Home. Back closes actions
or restores the preceding screen and selection. Collection actions offer Play
All, Shuffle Songs, Play Next and Add to Queue; long lists also offer Jump.
All Songs also offers Shuffle Albums. Now Playing actions contain Queue,
Shuffle (Off/On), Repeat (Off/All/One), Go to Artist/Album, Favourite and Save Queue
when the corresponding owned persistence allocation is available. Play selects a row and toggles
pause on Now Playing. Previous/Next scroll menus with hold-repeat and acceleration.
On Now Playing, a tap skips on release; a 400 ms hold previews an accelerating
seek, committed once on release. Paused seeks remain paused. Holding Back for
500 ms opens the captured Queue directly; a short Back retains normal navigation.
The selected queue row includes the artist. Volume buttons repeat after 200 ms,
then every 50 ms, without catching up missed repeats in a burst. A tap adjusts
0.5 dB; rapid same-direction taps within 250 ms ramp to 1 dB, then cap at 2 dB.
Pausing or reversing restores fine adjustment. A held button uses 1 dB repeats,
reaching the 2 dB cap after 350 ms. A full-range hold takes about two seconds. The volume bar has no numeric
percentage. Its 113 fine positions span -64 dB to -8 dB; fractional animation
targets preserve a distinct bar position for every half-decibel code.

Settings > Themes offers one cohesive built-in Gain theme with Light and Dark
appearances, plus an optional Custom theme. Retired built-in theme tags migrate
to Gain without reinterpreting old settings. Theme documents lower into validated native
plans: resolved geometry, RGB565 colours, widget indexes and damage masks. Painting
performs no JSON parsing or filesystem work. The selected palette also applies to
USB mode and battery chrome. The transport bar is square; volume temporarily
replaces time labels with a fading speaker icon and has no numeric percentage.

An optional `.gain/theme.json` provides a Custom entry using the same schema as
`src/themes/*.json`. The source is limited to 32 KiB and parsed in a bounded
scratch arena. Invalid edits retain the last valid plan. Native firmware reads it
while idle after mounting; the desktop app checks edits every 500 ms outside
painting. Theme files contain data, not executable code. Run `mise run themes`
after changing bundled JSON; tests compare the generated plans with runtime parsing.

Theme, appearance, volume, ReplayGain, display timeout and paused-idle timeout are saved after one
second without changes, and flushed before shutdown or USB handoff. Persistence
requires the host-provisioned 8 KiB `.gain/settings.bin`; existing provisioning
creates it without changing music. Two independently checksummed journal sectors
preserve the preceding settings if a write is interrupted. Drawing and input do
not write the card; playback saves use its sole storage owner. Missing or corrupt
settings use defaults, and an I/O failure disables saves until the next mount.

Settings > Display offers 15, 30 (default), 60 seconds or Always On. Automatic
sleep turns off the backlight while audio and indexing continue. Ordinary input
wakes and performs its action; a short Power press only wakes. A short Power press
while awake locks controls and turns off the backlight. Short Power again unlocks;
held keys remain suppressed until released. Long Power retains the existing
1.5-second hardware shutdown. Neither feature changes panel power sequencing.

Settings also offers a nonpersistent 15/30/60-minute sleep timer and a
5/15/30-minute or disabled paused-idle timeout. Activity restarts the idle timer.
A confirmed headphone removal pauses headphone playback, never automatically
resuming on insertion; line-out follows the settled hardware route. USB entry
cancels the sleep timer, checkpoints and releases card ownership before host access.

Imported M3U/M3U8 playlists retain repeated and missing references. Eight internal
saved queues use separate source-bound journal banks and preserve realised order.
They do not allocate or rename FAT/exFAT files. Export them to ordinary M3U8 on
the host with `python3 tools/gain_metrics.py export-playlists CARD_ROOT OUTPUT_DIR`.
Song and album favourites use distinct identities and keep unavailable records.
Recently Added lists albums by first discovery sequence, not unreliable FAT dates;
the initial library is a quiet baseline, and stable track anchors preserve age
through ordinary retags and moves. Prepared view columns keep these lists free
of filesystem work and mutable-state searches during painting.

Starting a collection captures its membership and resets playback modes.
Selecting a song starts that collection at the chosen song. Queue selections
retain the queue. Shuffle changes future order without restarting the current
song, and disabling it restores canonical order. Repeat All wraps that queue;
Repeat One affects automatic completion, while manual skips still advance.
Browsing and progressive library updates do not replace a listening session.

The retained folder-browser component uses filesystem names from the scanner's
directory snapshot, with
folders first and natural filename sorting. Preview tracks can introduce new
folders before a scan finishes. Folder playback includes only direct children;
subfolders are not played recursively. All browsing and context-menu rendering
remain free of filesystem I/O. Files awaiting usable index metadata are marked
Pending or Unavailable rather than entering a separate player.

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
a background worker. Artwork uses the production image decoder and cover cache
on a separate read-only worker. Playback uses a test transport clock; this app
does not produce audio or emulate device timing. The app saves listening state only
to existing, validated owned `.gain` allocations. Set `GAIN_UI_READ_ONLY=1` to
disable writes when browsing an external root.

The mock-card generator uses synthetic encoded audio, fictional multilingual
tags, cover images, a playlist and preallocated firmware cache files. Generated
cards must be outside the repo. `--mount /path/to/files` can add real files or
folders through symlinks; the adapter still opens media read-only. Artwork decoding runs on a separate
read-only worker using the production image decoder and cover cache. Persistence
writes only existing, validated owned allocations; `GAIN_UI_READ_ONLY=1`
disables these writes for external-root qualification. No personal
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
Stage two has a 2.5 MiB code region and a separate 128 KiB zero-initialized
globals region. The 8192-frame conversion batch and twelve Cover Flow cache
slots have explicit, independent reservations. `src/f20_memory.zig` owns the physical RAM
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

## SD boot and recovery

Normal boot preserves the factory ROM, SPL/U-Boot and recovery. U-Boot starts
`gain-loader.uimage` from the normal kernel slot; the native, read-only loader
then validates and runs `.gain/firmware.f20` on the card. Hold Back while booting
to prefer `.gain/previous.f20`. A missing or invalid candidate falls back to the
other slot. Board, addresses, lengths and both CRCs must pass before execution.
This detects corruption; it is not a signed-image security system.

`mise run build` produces `firmware.f20`, `gain-loader.bin` and
`gain-loader.uimage`. `mise run test-boot` tests partial copies, mutation,
fragmented reads, fallback and boot-attempt acknowledgement in three build modes.
The loader relocates above the player, preserves active DRAM training, clears
only the factory boot-attempt marker after validation and owns fresh ROM recovery.
It cannot write the card or NAND. On SD boot failure it displays the reason and
allows Play to retry; MENU held during reset retains processor USB recovery.

Ordinary player updates replace only the SD image. Keep a validated previous
image, write and flush a temporary current image, verify it, then rename it to
`firmware.f20` and eject the card cleanly. Never leave `update.upt` at the root
for an ordinary SD update.

For initial installation, the packaging tool can create a kernel-only factory
update, using `version.txt` from the matching F20 V2.7 stock firmware package:

```sh
python3 tools/pack_firmware.py update zig-out/bin/gain-loader.uimage /tmp/gain.upt \
  --version-file /path/to/stock/version.txt
python3 tools/pack_firmware.py restore /path/to/stock/uimage.bin /tmp/restore.upt \
  --version-file /path/to/stock/version.txt
```

Packaging requires `xorriso`. It writes host artifacts only; it never installs,
stages or flashes them. The manifest targets only the normal kernel partition.
The factory bootloader, recovery, logo, root filesystem and data are excluded.
Keep the matching stock package and independent device archive available for
recovery. The installed kernel path has been read back and cold-boot tested on
F20 V2.7; other board revisions are not qualified.

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
image stays within its 2.5 MiB reservation. The loader validates the
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
The font worker claims the most recently requested label first, while retaining
older labels for retained screen bands and return journeys. Font-source polls
may service covers between card transactions. A nonrecursive pump and scoped
yield bindings preserve cancellation and the sole storage owner; SD keep-alive
callbacks never start this storage work.

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
