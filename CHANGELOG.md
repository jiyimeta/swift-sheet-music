# Changelog

All notable changes to this project are documented in this file. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `EditIntent` and `ScoreEditSession` let a host relay a scalar edit — a
  note write, a duration change, a delete, or several bundled into one
  undo step — to a second copy of the score, so an Android host can keep
  a mirror session in step with its own authoritative one.
  `Score.stableFingerprint` is a deterministic 64-bit digest of the
  mutable musical content, for confirming two copies agree.
- `ScoreEditSession.lastRefusalReason` reports why the last `apply` call
  returned `false` — the only diagnostic available when a mirror session
  and its authoritative counterpart disagree.
- Seven JNI entry points expose an edit session to Android:
  `nativeBeginEditSession`, `nativeApplyEditIntent`, `nativeEditUndo`,
  `nativeEditRedo`, `nativeEndEditSession`, `nativeScoreFingerprint`, and
  `nativeEngineVersionStamp`.
- `HandleTable.replace` swaps the value behind an existing handle and
  reports whether the write landed, so a handle released mid-edit is
  told apart from one that isn't.
- `SheetMusicEngine.version` and `SheetMusicEngine.versionStamp` provide
  a build identity. On Android two separately linked images of the
  engine coexist in one process — the host app's and its library's —
  and a mismatch (a stale `.so`) can cause silent score divergence.
  `versionStamp` lets a host compare its own compiled-in stamp against
  the one it reads from the library over JNI before opening an edit
  session, so it can refuse to open one on a mismatch instead of risking
  a corrupted score. No host does this comparison yet; that is
  downstream work this library only makes possible.

### Changed

- `ScoreEditor` is no longer `@MainActor`. **Source-breaking:** a
  `@MainActor final class` is implicitly `Sendable`, and `ScoreEditor` no
  longer is, so a consumer storing one in a `Sendable` type, or
  capturing it in a `@Sendable` closure or a detached `Task`, will now
  fail to compile. The Android JNI process pumps no main run loop, so a
  main-actor hop from an entry point would be scheduled and never
  resumed; the editor has to be drivable synchronously from whatever
  thread calls in.

## [1.8.0] - 2026-08-02

### Added

- `Score.effectiveMeasureDuration(at:measureIndex:)` resolves what a
  `.measure` duration means in one measure on one staff. It reads that
  staff's own measure list, because `actualLength` — unlike the time
  signature — is per-measure and can differ between staves, and falls
  back to 4/4 for an out-of-range staff or measure. It walks the whole
  list, so a loop should keep using `effectiveMeasureDurations()` and an
  index.

### Fixed

- A PDF containing a tuplet exports an `.mscz` that can be reopened. The
  importer recognized the tuplet and baked the ratio into each member's
  duration, but emitted no `Tuplet` span. The MSCX encoder un-scales a
  member through its enclosing tuplet, so a member with none around it
  fell through to `<durationType>measure</durationType>`, which the Chord
  decoder refuses. Both scaling sites now record the ratio and voice
  assembly groups consecutive same-ratio members into a span — which also
  gets the bracket and number engraved. The breakage went unseen until
  imported PDFs started being written to disk as scores.

- Writing a note into an empty bar no longer produces a chord spelled
  `.measure`. `InputNote` built the new chord with the full-measure
  rest's own duration, and `.measure` is a rest-only spelling: layout
  resolved it against the bar and drew the note correctly, so the score
  looked right while `MSCXEncoder` trapped on save — a crash landing far
  from the edit that caused it. The bar's actual length is resolved on
  the way in instead; the inverse still restores the `.measure` rest as
  it was spelled, so undo leaves the empty bar exactly as it found it.

## [1.7.0] - 2026-08-02

### Added

- `FontMetricsProvider.leading(font:)` reports the extra vertical space a
  face asks for between consecutive lines, on top of `ascent + descent`.
  Only multi-line text consults it. The requirement ships with a default
  of 0, so existing conformers — the stub and Android's
  `SMuFLMetricsTable`-backed provider — keep compiling unchanged;
  `AppleFontMetricsProvider` returns `CTFontGetLeading`.

### Fixed

- Annotation text no longer runs past the end of a system. Nothing in the
  layout had ever moved an element horizontally: placement put a
  `<StaffText>` at its tick column plus the author's `<offset>` without
  consulting its width, so a text anchored near the final barline
  overflowed the page and the host clipped it. The new
  `HorizontalClampPass` pulls `.staffText` / `.systemText` / `.tempo` /
  `.rehearsalMark` back inside the system's bounds, shifting only as far
  as the overflow demands, and runs before the vertical pass so X is
  final when collisions are measured. Lyrics and `.harmony` are out of
  scope. Text that already fits is untouched.

- Multi-line annotations are measured line by line.
  `LayoutElementShape.textRect` handed a multi-line payload straight to
  `typographicWidth`, which laid every line out on one `CTLine`: the box
  came out as wide as the concatenation and one line tall, while the
  renderers stack the lines. The width is now the widest line and the
  height the whole stack, which also corrects the skyline's vertical box
  for those annotations.

- Seeking no longer flattens the mixer on the injected-backend path.
  `PlaybackEngine.seek(to:)` — and therefore `skip(by:)`, which every
  seek bar, lock-screen scrubber, and ±N-second button routes through —
  repositioned the transport without re-asserting the mixer. A backend
  seek resets the synth's channels to their GM defaults, and the tick-0
  CC 7 / programChange that would otherwise be chased back are stripped
  for mixer-managed channels precisely so the mixer stays the sole
  authority, so the user's per-staff volume, mute, solo, and program
  silently reverted on every seek until the next `play()` re-applied
  them. Every other backend-seek site already re-asserted; this one is
  now consistent with them.

- `SwiftySynthBackend` no longer drops the whole-score tuning on a seek.
  `MidiFileSequencer.seek` resets the synthesizer before it chases, just
  as `sequencer.play` does in `loadSequence`, so the RPN pair carrying
  the A4 calibration and the transpose was wiped with nothing in the SMF
  to restore it — a lock-screen skip or a loop wrap quietly returned
  playback to concert pitch. `setTuning` is contracted to persist across
  transport operations; the backend now re-asserts it after a seek, the
  same way `loadSequence` already did.

## [1.6.0] - 2026-07-29

### Added

- Tuplet marks are read from PDF. The importer detects a bracketed mark
  from its number and arms, anchors a beamed mark to its narrowest beam,
  and scales the members inside a detected mark's span — read before
  lyrics and before metric reconciliation, so a tuplet member is never
  re-valued afterwards and its digits are not mistaken for a lyric.

- `PlaybackEngine.timedPosition` pairs the current playback position with
  the host-clock instant it corresponds to, in a single read. Sampling a
  node's `lastRenderTime` next to a separately-read position admits up to
  one IO buffer (~23 ms) of unknown error; this has no interval between
  two reads to be wrong about, so a host aligning an independently
  captured recording against playback can project the score's time-0
  instant onto the shared host clock exactly. `nil` — never a wrong
  number — whenever a pairing is unavailable.

- `LayoutMeasure.hasSameRenderContent(as:)` reports whether two layout
  measures would draw identically once placed, ignoring their horizontal
  origin. A renderer that caches per-measure drawing uses it to decide
  between reusing, repositioning, and rebuilding.

- `PdfParseResultWire.playableElementCount` — how many chord/rest elements
  the PDF importer actually reconstructed, across every staff and voice.
  A PDF outside the importer's scope (a Chrome "print to PDF", a scan)
  still yields staff lines and measure cells, so the resulting `Score` is
  structurally valid and completely empty; a host that only checked "did
  the parse throw" would show the reader a playable transport that runs
  one second and plays silence. The count is reported as a fact, not a
  verdict — the host decides what is worth playing. Additive and
  defaulted, so existing construction sites are unaffected.

### Changed

- Note entry on a large score is roughly 9× faster end to end. On a
  1300-measure × 6-staff score in horizontal (no-wrap) layout, a
  one-note edit went from ~216 ms to ~24 ms per keystroke in a Release
  build; a cold layout of the same score went from 335 ms to 38 ms
  horizontally and from 427 ms to 36 ms vertically. Two independent
  causes:
  - `LayoutEngine`'s spacing pass was O(measures²).
    `aggregatedTickWeights` re-derived one measure's effective duration
    by walking its staff's entire measure list, once per measure — 97 %
    of a one-note edit's layout time on a 1300-measure score. The
    durations are now computed once per layout call and carried on the
    render context. The per-measure `LayoutCache` entry additionally
    shares one tick aggregation between the width pass and the placement
    pass instead of computing it twice.
  - Editing one note rebuilt the entire `CALayer` tree. Each measure's
    layers now live in their own container layer, and `ScoreView`
    rebuilds only the measures whose drawn content changed, repositioning
    the ones that merely shifted horizontally. An edit no longer calls
    the full system builder at all.

  Rendered output is unchanged: a layout digest over every bundled
  fixture and the rendered reference images are both byte-identical
  across the change.

### Fixed

- The per-measure layout cache could serve stale note positions. Its key
  covered a measure's own content but not the prevailing measure
  duration, which carries forward from earlier measures — so editing a
  time signature could leave a later measure containing a full-bar rest
  laid out against the old bar length.

- The Android AAR is published again. `android-publish.yml` triggered
  only on `v*` tags, but the tag prefix was dropped after 1.2.2, so no
  Android artifact was published for 1.2.3 through 1.5.1. The workflow
  now matches both spellings.

- PDF import accuracy, across several passes:
  - Text from a simple font is decoded through the font's own encoding
    rather than assumed Latin-1, and a CMap text run's origin is recorded
    at its start instead of one advance past it.
  - Lyrics snap by comparing syllable and notehead **centres**, and the
    candidate gate now uses the same centre the snap does, so the two
    can no longer disagree.
  - A staccato dot is no longer read as an augmentation dot; a lone whole
    rest is read as a measure rest rather than a whole note; fractional
    beams narrower than 4 pt are accepted; and the leading key/time
    region ends at content rather than at the first notehead.
  - Tier 4 shape matching measures a glyph against the staff, not just
    its own silhouette.

- `AVAudioSequencer.hostTimeForBeats:error:` raises an Objective-C
  exception — rather than populating its `NSError **` — in a window right
  at playback start, where `isPlaying` reports `true` before the
  underlying `MusicPlayer` is actually playing. Swift cannot catch an
  NSException and no pre-call guard closes the race, since `isPlaying` is
  itself the check that lies. The call now goes through a small
  Objective-C shim that folds the raising path and the documented
  error-pointer path into one failure result.

- The playback cursor skipped a centered rest based on a tick count; it
  now keys on `.measure` duration, which is what actually centers it.

## [1.5.1] - 2026-07-27

### Fixed

- `SheetMusicPDF` is now exported as a library product on Android as well
  as Apple. 1.5.0 made the importer buildable for Android but left the
  product inside the Apple-only block, so a cross-compiling consumer got
  *"product 'SheetMusicPDF' … not found in package 'swift-sheet-music'"*
  and could not reach `parseUsingSwiftReader`,
  `parseWithGeometryUsingSwiftReader` or `summaryUsingSwiftReader` at all.
  The target's Android shape already excludes every Apple-only file and
  depends only on Core + Layout, so exporting it pulls in no Apple
  framework.

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

- A tiered glyph-classification cascade for PDF import. The importer no
  longer depends on a PDF naming its glyphs the way MuseScore's Bravura
  export does: it extracts the embedded font program and encoding from
  the font dictionary, resolves a simple font's character codes to real
  glyph IDs, and classifies through a glyph-name table before falling
  back to shape matching against rasterized Bravura exemplars. Tier 4
  (shape matching) is **off by default** behind
  `PDFImportOptions.enableShapeMatching`; a per-font music-font gate
  keeps it from firing on text fonts. `RawGlyph` is replaced by the
  format-neutral `GlyphGeometry`, and glyphs are classified at front-end
  emission rather than downstream.

- MuseScore's skyline autoplace, ported as a system layout pass.
  `LayoutShape`, `Skyline` (north/south lines with a staff-line filter)
  and `AutoplaceRules` (distance and ignore tables) replace the four
  per-measure autoplace approximations, and autoplaced element shapes are
  now measured from font metrics.

- Android: transposed notation and playback, with drum staves exposed to
  hosts; count-in (pre-roll) before playback; and the metronome's MIDI is
  now shared, with Android's click rendered from it rather than from a
  parallel implementation.

- A corpus annotation-collision detector under `Tools`, which walks
  system spanners and uses true 2D AABB overlap.

### Fixed

- Layout: a hairpin no longer collides with the dynamic at its own
  start/end tick; a hidden mid-measure voice no longer draws a full-width
  bar; melismas bucket by their own row offset rather than raw Y; SMuFL
  runs are measured by glyph ink rather than the Bravura em box; the
  tempo beat glyph's ink is centred on its origin as `ScoreLayerBuilder`
  draws it; and grace chords are no longer double-shifted.

- PDF import: Tier 2 no longer reads ordinary digits as time-signature
  digits; the classifier cache is keyed by glyph ID as well as codepoint;
  a simple-font text run is placed at its start rather than its end; and
  `GlyphClassifier` gate races and full-Bravura rejection are fixed.

- Android: count-in sounds with the metronome switched off, and the
  metronome plays off a transport instead of firing clicks directly.

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

[Unreleased]: https://github.com/jiyimeta/swift-sheet-music/compare/1.8.0...HEAD
[1.8.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.7.0...1.8.0
[1.7.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.6.0...1.7.0
[1.6.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.5.1...1.6.0
[1.5.1]: https://github.com/jiyimeta/swift-sheet-music/compare/1.5.0...1.5.1
[1.5.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.4.0...1.5.0
[1.4.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.3.0...1.4.0
[1.3.0]: https://github.com/jiyimeta/swift-sheet-music/compare/1.2.6...1.3.0
[1.2.6]: https://github.com/jiyimeta/swift-sheet-music/compare/1.2.5...1.2.6
[1.2.5]: https://github.com/jiyimeta/swift-sheet-music/compare/1.2.4...1.2.5
[1.2.4]: https://github.com/jiyimeta/swift-sheet-music/compare/1.2.3...1.2.4
[1.2.3]: https://github.com/jiyimeta/swift-sheet-music/compare/v1.2.2...1.2.3
[1.2.2]: https://github.com/jiyimeta/swift-sheet-music/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/jiyimeta/swift-sheet-music/compare/v1.2.0...v1.2.1
[1.1.1]: https://github.com/jiyimeta/swift-sheet-music/releases/tag/v1.1.1
[1.0.0]: https://github.com/jiyimeta/swift-sheet-music/releases/tag/v1.0.0
