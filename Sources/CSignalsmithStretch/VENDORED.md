# Vendored: Signalsmith Stretch and Signalsmith Linear

Both libraries are MIT-licensed and header-only. Their license texts sit beside their headers.

| Library | Upstream | Tag | Commit | Files taken |
| --- | --- | --- | --- | --- |
| Signalsmith Stretch | https://github.com/Signalsmith-Audio/signalsmith-stretch | `1.4.0` | `a670068d9aeb64913331d5cc29337b19a457a7df` | `signalsmith-stretch.h`, `LICENSE.txt` |
| Signalsmith Linear | https://github.com/Signalsmith-Audio/linear | `0.6.4` | `de55e6a50ffcf6f8f43f649692d94691c7025151` | `fft.h`, `stft.h`, `platform/fft-accelerate.h`, `LICENSE.txt` |

Linear `0.6.4` is the version Stretch `1.4.0` pins in its `CMakeLists.txt`. (The header itself still says
`version = {1, 3, 2}`; the tag is `1.4.0`.)

The files are byte-for-byte upstream's. Only the layout differs. Upstream Linear keeps its headers at the repository
root and forwards to them from `include/signalsmith-linear/*.h`; here the real files sit directly in
`signalsmith-linear/`, so `#include "signalsmith-linear/stft.h"` in `signalsmith-stretch.h` resolves through the
target's `headerSearchPath(".")`. Of Linear, only what Stretch includes with `SIGNALSMITH_USE_ACCELERATE` defined is
here: `stft.h` → `fft.h` → `platform/fft-accelerate.h`.

To update, clone both repositories at their new tags outside this repository, copy the same files over, update the
table, and run `SignalsmithStretcherTests` and `RecordingStretcherRenderTests`.

## Build settings

- `SIGNALSMITH_USE_ACCELERATE` selects Accelerate's vDSP FFT. The target links `Accelerate`.
- No optimization flag of its own. Upstream recommends optimizing even Debug builds, as the unoptimized stretcher
  is up to 10× slower, but `-O2` needs `unsafeFlags`, which SwiftPM refuses in a package resolved by version, as
  folino resolves this one. A Debug build therefore runs the stretcher unoptimized. Audio QA runs a Release build.
- Measured on 2026-10-30 in thread CPU time, 48 kHz stereo, rate 0.7, one pair with both instances processing (a
  crossfade), 512-frame calls: a jump's `seek` takes 9–18 ms of CPU unoptimized (`-O0`, a SwiftPM or Xcode Debug
  build), against 0.6–1.4 ms at `-Os` (Xcode Release) and 0.5–1.2 ms at `-O2`. That is more than one 512-frame
  render callback (10.67 ms), so a Debug build can drop out at a jump — a seek, a loop wrap, a cut between segments, a
  retune — while recordings play away from 100 % or transposed. The pair costs 150–158 ms of CPU per second of audio
  unoptimized against 10.7–12.3 ms at `-Os`. A dropout heard in a Debug build is not evidence; audio QA uses a
  Release build.
- No `cxxLanguageStandard`: the headers need C++11, and the toolchain default is newer.

## The C shim

`include/csignalsmith_stretch.h` and `shim.cpp` give Swift a C API, stereo only, so no Swift/C++ interop mode is
needed. `SheetMusicAudioSignalsmith` is the only target that imports it.

`csignalsmith_stretch_seek` differs from upstream's `seek`. Upstream's only replaces the input history, so after a
`reset()` the output rises from silence over a block. The shim's seek also runs one block of output through the
stretcher and discards it (upstream's `outputSeek` does the same with less pre-roll). The next output is then aligned
and at full level. `csignalsmith_stretch_seek_length` is upstream's `seekLength()` plus that block's input at the given
rate.

## Real-time safety

`csignalsmith_stretch_create` / `destroy` allocate and free; they run on the main actor. Every other call is made on
the render thread. Read for this version, those calls allocate nothing once the stretcher is configured:

- `configure` (from `presetDefault`) sizes every buffer: the STFT's ring buffers, spectra and window products, the
  band arrays, `tmpProcessBuffer` (a block plus an interval) and `tmpPreRollBuffer`. The FFT plans are made there too.
- `process` and `seek` call `tmpProcessBuffer.resize(n)` only with `n` at most the size `configure` gave it, which
  never reallocates. `stashedInput = stft.input` and `stashedOutput = stft.output` go through `vector::assign` between
  vectors of equal size, which reuses the capacity.
- `reset()` uses the same `assign` calls, and `_channelBands.assign(size, Band())` keeps the size.
- `setTransposeSemitones` assigns `nullptr` to an empty `std::function`, which frees and allocates nothing.
- The FFTs work in buffers sized when the STFT is configured (their `resize`). The vDSP one uses the split buffers
  allocated with its plan.

The one growth point is `peaks.emplace_back` in `findPeaks`, which runs while a track is transposed. `configure`
reserves `bands / 2` entries, and a spectrum can hold at most `ceil(bands / 2)` peaks, because every peak is followed
by at least one band that is not. So with an odd band count, a spectrum that alternates above and below its own
smoothing at every other band from band 0 could add one entry, once. After that the capacity stays.

`SignalsmithStretcherTests` checks this with `malloc_zone_statistics`. It takes the blocks and bytes in use before and
after a run of `process` and `seek` calls on a warmed stretcher. The check sees growth, but not a `malloc` freed
inside the same call: zone statistics count what is in use, not how many allocations were made. The reading above is
the guarantee for the second kind.
