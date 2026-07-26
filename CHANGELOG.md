# Changelog

All notable changes to this project are documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.5.0] - 2026-07-27

### Added

- The PDF importer's geometry side-car is now available on Android, so a
  host can draw a playback cursor on the original imported PDF and
  resolve taps on it back to score positions. Previously only the Apple
  front-end could produce it: `parseWithGeometry` lived in the
  PDFKit-gated entry point, and Android could only ask for a bare
  `Score`.
  - `PDFImporter.parseUsingSwiftReader(pdfData:options:)`,
    `parseWithGeometryUsingSwiftReader(pdfData:options:)` and
    `summaryUsingSwiftReader(pdfData:)` are the Foundation-only entry
    points driven by the pure-Swift PDF reader. They are compiled on
    **both** platforms — Android uses them as its only front-end, and on
    Apple they stay reachable so the test suite exercises the exact code
    Android runs. `PDFImporter+AndroidEntry` is now a thin re-export of
    them.
  - `PDFDocumentSummary` (page count + `/Title`) reads a PDF's metadata
    without decoding any notation, so a library can name an imported
    file without paying for a parse.
  - JNI: `nativeLoadScoreWithGeometryFromPDF`, `nativePdfCursorRect`,
    `nativePdfHitTest`, `nativePdfPageSizes` and
    `nativeReleasePdfGeometry`, with `PdfRectWire`, `PdfPageSizesWire`,
    `PdfDiagnosticWire` and `PdfParseResultWire` as their wire types.
    The geometry stays behind an opaque handle — only a rectangle or a
    cursor ever crosses the boundary, so cursor lookup and hit-testing
    are not re-implemented per platform. Every rectangle leaving and
    every point arriving is converted between PDF user space (y-up) and
    top-left page space on the Swift side, so a caller works in one
    convention.
  - Kotlin: `PdfScoreHandle` (score handle + geometry handle +
    importer diagnostics, releasing both on `close()`) and
    `PdfDiagnostic`.

### Fixed

- `LayoutOptionsWire`'s `transposeSemitones` field, added in 1.4.0, left
  two test call sites constructing the old memberwise initializer, which
  broke the `SheetMusicTests` target's compile.

## [1.4.0] - 2026-07-25

### Added

- `Part.isVisibleInScore` — MuseScore's `<Part><show>` "hide instrument
  in the main score" flag is now decoded and modelled. It is read
  identically from MuseScore 3 (id-less `<Part>`, `<Staff id="N">`) and
  MuseScore 4 (`<Part id="N">`, id-less `<Staff>`) files, where `<show>`
  sits at the same position as a direct child of `<Part>`; absent or
  `<show>1</show>` decodes as visible. The encoder round-trips it,
  emitting `<show>0</show>` only for hidden parts (matching MuseScore,
  which omits it when visible). The flag is display-only: hosts drive
  the actual hiding through `Score.filtered(hidingStaves:)`, so the part
  stays in the model and in playback and a reader can reveal it.

### Fixed

- `Score.filtered(hidingStaves:)` mishandled brackets that span several
  single-staff parts (e.g. a five-part vocal group under one section
  bracket). It re-spanned brackets within a single part, clamping the
  span to that part's staff count — so hiding a staff below the group
  collapsed the whole bracket onto its anchor staff, and hiding the
  anchor's part dropped the bracket entirely. Bracket survival, span,
  and anchor are now recomputed over the global (flattened) staff order,
  so a cross-part bracket contracts correctly around hidden staves and
  re-anchors onto the first surviving staff when its own anchor is
  hidden. Staff- and part-dropping semantics are unchanged.

## [1.3.0] - 2026-07-24

### Added

- Fall, doit, plop and scoop — MuseScore's `<ChordLine>` — are now
  imported, laid out, drawn and exported. They previously vanished on
  import: the element was not modelled anywhere, so the MSCX decoder's
  permissive skip dropped it silently and nothing downstream could draw
  it. Covers all twelve palette variants (the default curved shapes, the
  straight "slide in/out" forms, and the wavy "rough" forms, which use
  the SMuFL `brassFallRoughShort` / `brassLiftShort` glyphs), on the
  SwiftUI Canvas renderer, the CALayer renderer and the Android draw
  program. `Chord.chordLines` carries them; both the `<Chord>`-level and
  `<Note>`-nested MSCX forms round-trip, including a user-dragged
  `<Path>`. Geometry is ported from MuseScore 4's
  `TLayout::layoutChordLine` and verified against its own PDF output.
  MIDI is deliberately unaffected — MuseScore's SMF export ignores chord
  lines too.
- Chord lines take part in horizontal spacing, mirroring upstream: a
  line widens the gap to its neighbour only when the two shapes
  vertically intersect, and never against a barline.

### Fixed

- `MSCXEncoder`'s chord rebuild in `encodeChord` no longer drops
  chord-attached fields it does not name explicitly.

## [1.2.6] - 2026-07-22

### Fixed

- Staves voiced through SF2 note-on modulators — most visibly
  MuseScore_General's Acoustic Grand Piano — no longer render near-silent on the
  SwiftySynth backend. Bumps swiftysynth 0.1.2 → 0.2.0 and enables
  `SynthesizerSettings.enableModulators`, so the synth applies each region's
  note-on velocity/key modulators (attenuation, filter cutoff/Q, pitch/LFO/
  envelope depths, tune, reverb/chorus sends) once at note start. swiftysynth's
  MeltySynth port had discarded these, collapsing the piano's velocity-crossfade
  layering; the ON-path loudness now matches FluidSynth 3.5.5 within ~0.2 dB.

## [1.2.5] - 2026-07-22

Fixes another defect in the injected-`SynthBackend` playback path introduced in
1.2.0, when live playback moved from AUMIDISynth to SwiftySynth. Hosts on the
built-in AUMIDISynth path were not affected.

### Fixed

- `PlaybackEngine.skip(by:)` now works on the injected `SynthBackend` path. It
  guarded on the AUMIDISynth `sequencer`, which is never built when a backend is
  injected (`play` returns early into `backendPlay`), so every relative seek was
  a silent no-op — a host's seek bar, the lock-screen scrubber
  (`changePlaybackPositionCommand`), and the ±N-second skip buttons were all
  dead. `skip(by:)` now routes its resolved target frame through `seek(to:)` when
  a backend is injected, reusing the same count-in pre-roll drop, loop snap, and
  `currentCursor` update as an absolute seek.

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
