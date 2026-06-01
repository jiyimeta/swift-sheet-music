# Custom metronome click — runtime WAV→SF2 (cross-platform)

**Status:** draft (2026-06-01)
**Worktree:** `.claude/worktrees/custom-metronome-click` (branch `worktree-custom-metronome-click`, off `main` HEAD `7eda971`)
**Related memory:** `project_android_audio_ci`, `project_aumidisynth_program_change`

## Goal

Let the metronome click with arbitrary host-supplied WAV samples (strong /
weak) instead of the General MIDI percussion patch it uses today. The current
implementation loads the same GM SoundFont used for the score and triggers
note 76 (Hi Wood Block) / note 77 (Low Wood Block) on AUMIDISynth (Apple) and
FluidSynth (Android); there is no way to swap the click sound.

The library consumer (the host app) must be able to override the click by
supplying strong / weak WAV file URLs, and that override interface must look
like **one** interface across Apple and Android.

## Chosen approach — runtime WAV→SF2 generation (one shared mechanism)

Both Apple AUMIDISynth and Android FluidSynth are SF2-based synths, and both
are already wired into the existing timing plumbing (tempo curve, rate, loop
wrap, offline export) — Apple through `AVAudioSequencer`, Android through the
poll loop. If we reduce "swap the click sound" to "load a different SF2", we
avoid touching any of that delicate timing plumbing.

We add a Foundation-only **WAV→SF2 builder** in `SheetMusicAudioCore`
(Android-compatible). It takes strong / weak click PCM and emits SF2 bytes that
map **strong → note 76 / weak → note 77 in a bank-128 (GM percussion) preset**.

- **Apple**: hand the generated SF2 to the existing AUMIDISynth. The
  `MetronomeController` / sequencer / export plumbing is effectively unchanged.
- **Android**: hand the generated SF2 to FluidSynth. The `MetronomeMixer` /
  poll plumbing is effectively unchanged.
- Notes 76 / 77 match the current metronome-track generation (Apple
  `metronomeTrack`, Android `MetronomeMixer.fire`), so the **track-generation
  code on both platforms is unchanged**.

### Alternatives considered and rejected

- **Apple plays WAV directly via `AVAudioPlayerNode.scheduleBuffer`** — drops
  out of the sequencer clock, forcing a reimplementation of tempo / rate /
  loop / export scheduling. Rejected; the metronome stays a MIDI instrument
  node.
- **Apple `AVAudioUnitSampler.loadAudioFiles` (WAV direct), Android-only SF2
  (hybrid)** — `loadAudioFiles` auto-splits the keyboard across files, making
  it fragile to land the intended notes (76/77). Since the WAV→SF2 writer must
  exist for Android anyway, sharing it lets Apple change only the SF2 URL and
  makes the click sound identical on both platforms. Hence the shared-writer
  approach (this spec) was chosen.
- **Ship a pre-built SF2 in the library** — cannot satisfy "drop in arbitrary
  WAVs" (the app would have to author its own SF2). Rejected.

### Performance

A click is typically 20–100 ms (≈9 KB/click at 44.1 kHz / 16-bit, ≈18 KB for
both). SF2 generation is in-memory RIFF-chunk assembly plus a PCM memcpy:
sub-millisecond to a few ms. Loading the SF2 into the synth
(`kMusicDeviceProperty_SoundBankURL` on Apple, FluidSynth on Android) is at the
low end of the "tens of ms" the codebase notes for the full GM SF2 (>100 MB) —
a few ms at most for a ~20 KB file. It happens **once when the click source is
set or changed** (the generated SF2 is cached to a temp/caches file), never per
score, per beat, or in the render loop. There is no performance concern.

## Non-goals

- **Bundling a default click in the library product.** Like the GM SF2 today,
  the click is host-supplied. If the provider returns no click source, the
  metronome **falls back to the current GM drum-kit path** (fully backward
  compatible). The example app bundles `click_strong` / `click_weak`.
- **Changing metronome rhythm / accent logic.** The tick positions, velocity,
  and downbeat detection are unchanged. Only the timbre (sample) is swapped.
- **Mapping to notes other than 76 / 77.** The generated SF2 is fixed to 76/77
  to preserve the existing track generation.
- **Resampling the WAV.** SF2 stores a per-sample sample rate, so the input
  WAV's sample rate is written into the SF2 sample header verbatim.
- **Compressed click input (MP3 / OGG).** Input is PCM WAV only.
- **Switching to AVAudioUnitSampler.** Apple keeps the existing AUMIDISynth.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ SheetMusicAudioCore  (Foundation-only, Android-compatible)       │
│                                                                   │
│  WavPcmReader.swift          — RIFF/WAVE → (Int16 mono PCM, rate) │
│  ClickSoundFontBuilder.swift — (strong PCM, weak PCM) → SF2 Data  │
│  MetronomeClickSource.swift  — enum (value type of the seam)      │
│  MetronomeClickProvider.swift— protocol (host returns the source) │
└─────────────────────────────────────────────────────────────────┘
        ▲                                          ▲
        │ Apple                                    │ Android (JNI)
┌───────┴────────────────────────┐   ┌─────────────┴──────────────────┐
│ SheetMusicAudioApple           │   │ SheetMusicAndroidJNI            │
│  MetronomeController.swift     │   │  Audio/ClickSoundFontCodec.swift│
│   (resolve click source →      │   │   nativeBuildClickSoundFont(    │
│    generate/cache SF2 URL →    │   │     strongWav, weakWav          │
│    existing                    │   │   ) -> sf2 bytes                │
│    prepare(soundfontURL:))     │   └─────────────┬──────────────────┘
│  PlaybackEngine+Export.swift   │                 │ JNI
│   (export resolves same SF2)   │   ┌─────────────┴──────────────────┐
└────────────────────────────────┘   │ SheetMusicAudioAndroid (Kotlin) │
                                      │  AndroidPlaybackEngine          │
                                      │   resolve click source → JNI    │
                                      │   for SF2 bytes → temp file →   │
                                      │   FluidSynth load               │
                                      │  MetronomeMixer (SynthDriver     │
                                      │   loads the click SF2)          │
                                      └─────────────────────────────────┘
```

## Components

### 1. `WavPcmReader` (Foundation-only, AudioCore)

Parses PCM WAV bytes and returns `(samples: [Int16], sampleRate: UInt32)`.

- Supported formats: **16-bit PCM** and **32-bit IEEE float**, both normalized
  to Int16 internally.
- Channels: mono / stereo. Stereo is down-mixed to mono via `(L + R) / 2`.
- RIFF parse: `RIFF`/`WAVE` header → `fmt ` chunk (`audioFormat` 1=PCM /
  3=float, `numChannels`, `sampleRate`, `bitsPerSample`) → `data` chunk.
  Unknown chunks are skipped.
- Unsupported formats (8/24-bit, compressed) throw an error.
- Operates on `Data` (not just a URL) so the Android JNI path can pass raw WAV
  bytes; a URL convenience reads the file into `Data` first.

### 2. `ClickSoundFontBuilder` (Foundation-only, AudioCore)

Generates SF2 `Data` from
`(strong: [Int16], strongRate: UInt32, weak: [Int16], weakRate: UInt32)`. A
minimal SF2:

- `RIFF 'sfbk'`
  - `LIST 'INFO'`: `ifil` (version 2.1), `isng` ("EMU8000"), `INAM` (name)
  - `LIST 'sdta'`: `smpl` (strong PCM + weak PCM concatenated, with the
    spec-mandated 46 zero sample-points of guard after each sample)
  - `LIST 'pdta'`: `phdr`, `pbag`, `pmod`, `pgen`, `inst`, `ibag`, `imod`,
    `igen`, `shdr` (each section includes its terminal sentinel record)
- preset: **bank 128 / preset 0** (GM percussion). AUMIDISynth / FluidSynth
  auto-select this bank on channel 9.
- One instrument, two sample zones:
  `keyRange 76..76 → sample 0` (strong, unlooped, rootKey 76),
  `keyRange 77..77 → sample 1` (weak, unlooped, rootKey 77).
- Generators: `sampleModes = 0` (no loop), `overridingRootKey = 76/77`,
  `keyRange`. Accent is carried by the track's velocity, so the zones pass it
  through.

SF2 binary layout uses a small **little-endian** writer
(the existing `SheetMusicMIDI/IO/BinaryEncoder` is big-endian for MIDI, so it
is not reused; a new LE helper is added for SF2 / RIFF).

### 3. `MetronomeClickSource` / `MetronomeClickProvider` (the override seam)

Leave the existing `SoundfontResolver` untouched; add a separate seam (backward
compatible).

```swift
public enum MetronomeClickSource: Sendable {
    case clickSamples(strong: URL, weak: URL)  // WAV files
    case soundFont(URL)                        // host-supplied .sf2, used as-is
    case defaultGM                             // keep the current GM drum-kit
}

public protocol MetronomeClickProvider: Sendable {
    /// Returning .defaultGM (or no provider at all) falls back to the
    /// current GM drum-kit behavior.
    func metronomeClickSource() -> MetronomeClickSource
}
```

`PlaybackEngine.init` / `AndroidPlaybackEngine`'s constructor gain an optional
provider (absent → `.defaultGM`-equivalent = fully backward compatible).

### 4. Apple integration (`SheetMusicAudioApple`)

- Add a "click source → SF2 URL" resolution step before
  `MetronomeController.prepare(soundfontURL:)`:
  - `.clickSamples(strong, weak)` → read both WAVs with `WavPcmReader`, build
    the SF2 with `ClickSoundFontBuilder`, write it to the caches dir, return
    that URL. Reuse the generated file when the input URL pair is unchanged
    (caching).
  - `.soundFont(url)` → use `url` as-is.
  - `.defaultGM` → current behavior:
    `resolver.soundfontURL(forBank:0, program:0, isDrums:true) ?? defaultGMSoundfontURL`.
  - Hand the resolved SF2 URL to the existing `prepare(soundfontURL:)`
    (**AUMIDISynth unchanged**).
- Export: add the resolved metronome SF2 URL to
  `PlaybackEngine.exportEngineSnapshot`, and have `buildMetronomeSampler` load
  it (replacing the direct `resolver.soundfontURL(...)` call).

### 5. Android integration (`SheetMusicAndroidJNI` + `SheetMusicAudioAndroid`)

- Expose the Swift writer through JNI (same single-source pattern as
  GMInstrument):
  `nativeBuildClickSoundFont(strongWav: Data, weakWav: Data) -> Data`, which
  calls `WavPcmReader` + `ClickSoundFontBuilder` (Foundation runs on Android).
- `AndroidPlaybackEngine`: resolve the click source → for `.clickSamples`, get
  SF2 bytes via JNI → write them to a temp file once → `MetronomeMixer`'s
  `SynthDriver` loads that SF2. `.soundFont` / `.defaultGM` branch likewise.

## Caching

The generated SF2 is built **once per click source** (keyed by the WAV URL
pair) and written to a temp/caches file. Apple's existing
`MetronomeController.loadedSoundfontURL` guard prevents redundant synth
reloads; Android caches the temp file path the same way.

## Testing

- **`WavPcmReader`** (Foundation-only, also runs on Android): fixture WAVs
  (16-bit mono / 16-bit stereo / 32-bit float mono) → assert sample count,
  sample rate, and mono down-mix values. Unsupported formats throw.
- **`ClickSoundFontBuilder`** (Foundation-only): parse the generated SF2 and
  assert its RIFF structure (chunk IDs / size consistency / preset in bank 128
  / two sample headers).
- **Apple synth load** (`#if !os(Android)`): load the generated SF2 into
  AUMIDISynth and render notes 76 / 77, asserting non-silence (a few buffers in
  offline manual-rendering mode).
- **Backward compatibility**: with no provider, the GM drum-kit still sounds.
- **Round-trip**: a `PlaybackEngine` given `.clickSamples` offline-exports a few
  beats; assert non-silence around the beat ticks.
- Android tests verify the SF2 load path within the existing `MetronomeMixerTest`
  scope (apply `Scripts/gate-android-tests.sh` to new test files).

## Open questions

None (host-supplied, 16-bit/32-bit float input, shared writer, notes 76/77
fixed — all settled).
