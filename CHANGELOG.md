# Changelog

All notable changes to this project are documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.4] - 2026-07-20

### Changed

- `PlaybackEngine.setMasterGain(_:)` no longer caps the gain at 3.0. Negative
  values are still clamped to zero; there is no upper bound. The ceiling was a
  product decision in the wrong layer: how loud playback should be depends on
  the synth backend's output level and on what the host is trying to sound
  like, neither of which the engine can judge. A host calibrating a quiet
  backend against a louder reference can legitimately need more than 3×, and
  the cap left it with no recourse. The downstream peak limiter still prevents
  hard clipping, so the host owns the loudness/limiting trade-off.

## [1.2.3] - 2026-07-20

Fixes four defects in the injected-`SynthBackend` playback path introduced in
1.2.0, when live playback moved from AUMIDISynth to SwiftySynth. Hosts on the
built-in AUMIDISynth path were not affected by any of them.

### Fixed

- Playback now stops when it reaches the end of the score, and a whole-score
  repeat now loops. The cursor poll compared a frame-snapped tick against
  offset-valued boundaries: `SwiftySynthBackend.currentTick` is a
  `PlaybackTimeline.frame(atTime:)` lookup, `frames` carries note onsets only,
  and `frame(atTime:)` clamps to the last one — so the polled tick saturated at
  the final onset while both boundaries (`totalTicks` and the loop end from
  `itemEndTicks`) sit strictly past it. Neither was ever reached, so the engine
  stayed `.playing` forever with the cursor parked on the last note, and a loop
  covering the whole score never wrapped. End-of-score detection now asks the
  transport (`SynthBackend.isAtEnd`) instead of comparing against the timeline,
  and the loop wrap compares in score-space seconds.
- The playback cursor now tracks the audio on scores with repeats or jumps.
  The transport plays the unrolled render (repeats expanded) but its position
  was looked up directly in the notated timeline, so from the second
  measure-play onward the cursor ran a full measure-play ahead, then froze on
  the last frame once the unrolled position passed the notated duration.
- `currentTimeSeconds` / `currentTimeSecondsContinuous` — what a host publishes
  as elapsed playback time — carried the same drift and freeze, and
  `currentTimeSecondsContinuous` was additionally quantized to note onsets
  despite documenting itself as interpolating within a frame. All three backend
  reads now share one derivation from the transport's own clock.
- Playback through the SwiftySynth backend is 6 dB louder.
  `Synthesizer.masterVolume` was left at MeltySynth's C# default of 0.5, so
  every voice was attenuated before the engine's own gain stage. It now runs at
  unity and lets `setMasterGain` own the level.

### Added

- `SynthBackend.isAtEnd`, the transport's own end-of-sequence signal, with a
  default of `false` for backends that cannot report one.
- `PlaybackUnroll.Span` and `.spans` are now public, so an unrolled↔notated
  seconds projection can be built from another module.

## [1.2.2] - 2026-07-20

### Fixed

- Single-note audition through an injected `SynthBackend` (e.g. SwiftySynth)
  now sounds at the correct instrument and volume. A preview drives the synth
  directly rather than through the sequencer, so — unlike playback — it never
  received the mixer's program / channel volume: the async SoundFont load
  leaves the synth's channels at General-MIDI defaults at `prepare` time, and
  a prior playback's sequencer resets them too, so an audition sounded on
  program 0 (piano) at the default volume (near-inaudible for many parts).
  `playPreview` / `previewNoteOn` now re-assert the staff channel's program +
  volume immediately before each note-on.
- An injected-backend audition no longer clicks off its release tail, and a
  prior audition's tail no longer bleeds into the next one. Parking the audio
  engine right after the preview's note-off froze a software synth's render
  thread mid-release; the park is now deferred until the release tail has
  rendered out (a newer preview cancels the pending park). The AUMIDISynth
  path was unaffected and is unchanged.

### Changed

- Bumped the SwiftySynth dependency 0.1.1 → 0.1.2.

## [1.2.1] - 2026-07-19

### Fixed

- Glissandi that cross a measure boundary are now drawn. A glissando on the
  last chord of a measure — whose target is the first note of the next
  measure — was silently dropped, because line emission ran per-measure and
  only paired a note with the next chord *within the same measure*. Glissando
  geometry now resolves in a post-pass (mirroring tie resolution), pairing a
  note with the next chord of its voice across measure — and system —
  boundaries.
- Glissandi that cross a system break render as two legible segments: a
  labelled departure stub at the source note and an arrival stub reaching the
  target note, each held to a bounded staff-relative (pitch-space) slope
  clamped to ±1.5 sp so the line can never plunge across neighbouring staves.

### Added

- Sustained tap-preview API on `PlaybackEngine`: `previewNoteOn(pitch:onStaff:velocity:)`
  starts a held preview note (e.g. a bar press-hold) and `previewNoteOff(pitch:)`
  releases it — distinct from the existing fixed-duration
  `playPreview(noteID:in:duration:velocity:)`. Works on both the built-in
  AUMIDISynth path and an injected `SynthBackend` (e.g. SwiftySynth), and
  correctly interleaves with an in-flight tap preview in either order.
- Asynchronous SoundFont loading in `SwiftySynthBackend`: `prepare(soundfontURL:)`
  now reads + parses the SoundFont (tens to hundreds of MB) off the main actor
  instead of freezing the UI. `SynthBackend` gained `isReady` / `onReadyChanged`
  (with a synchronous-backend default), and `PlaybackEngine` surfaces
  `isPreparingSoundfont` and defers a play requested mid-load until the synth is
  ready. A superseding reload / teardown cancels the prior in-flight load. The
  AUMIDISynth path stays synchronous and always ready.

### Changed

- Bumped the `swiftysynth` dependency to 0.1.1, which bulk-copies the SoundFont
  sample chunk (per-sample read loop → single `memcpy`) — orders of magnitude
  faster to load a large font, especially in unoptimized debug builds.

## [1.1.1] - 2026-07-19

### Added

- Android JNI anchor primitives for freehand annotation: `nativeResolveAnchor`
  (a document-millimetre point → its `ResolvedAnchor`) and
  `nativeAnchorReferencePoint` (batched `[AnchorIdentity]` → `[AnchorRefPoint]`,
  with an `spMm == 0` sentinel per unresolved anchor so the array stays
  positionally aligned), plus their `SheetMusicJNI` Kotlin facade. Thin,
  app-agnostic wrappers over the shipped `SheetMusicLayout.resolveAnchor` /
  `anchorReferencePoint`, mirroring the `nearestCursor` bridge — the affine bake
  stays in the consumer's shared code.

## [1.0.0] - 2026-07-10

First public release.

### Added

- MuseScore `.mscx` / `.mscz` import and export, targeting MuseScore 4
  (default) or MuseScore-3.6.2-flavoured output
  (`MSCXEncoderOptions(targetVersion: .v3)`).
- MusicXML `.musicxml` / `.mxl` import.
- A typed, `Sendable` value-type score model (`SheetMusicCore`) with
  parse diagnostics (`parseWithDiagnostics`).
- Score → Standard MIDI File rendering, verified against MuseScore's own
  `midiexport_tests.cpp` fixtures via semantic-equivalence comparison.
- A pure-geometry layout engine (`SheetMusicLayout`) with a
  `FontMetricsProvider` dependency-injection seam.
- SwiftUI notation viewer (`SheetMusicUI`) with a moving playback cursor,
  and PDF export (`SheetMusicPDF`).
- AVFoundation-backed playback and audio-file export (`SheetMusicAudio`),
  including a configurable count-in / pre-roll click.
- Experimental PDF-score import.
- Android: the Foundation-only subset cross-compiled via the Swift Android
  SDK, plus Kotlin AAR modules for JNI bridging and FluidSynth + Oboe
  playback.

[Unreleased]: https://github.com/jiyimeta/swift-sheet-music/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/jiyimeta/swift-sheet-music/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/jiyimeta/swift-sheet-music/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/jiyimeta/swift-sheet-music/releases/tag/v1.1.1
[1.0.0]: https://github.com/jiyimeta/swift-sheet-music/releases/tag/v1.0.0
