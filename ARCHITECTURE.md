# Architecture

This document captures the durable design decisions behind
`swift-sheet-music` — the reasoning a contributor needs before changing
the model, the parsers, the layout engine, or the audio path. It is a
companion to the per-library `README`s and the reference notes under
`docs/`.

## Goals and non-goals

- **Goal:** a typed, value-semantic Swift model of engraved music
  notation, with faithful import/export for MuseScore and MusicXML, MIDI
  rendering that matches MuseScore's own output, and Apple-native
  rendering, PDF export, and playback.
- **Goal:** a Foundation-only subset that cross-compiles to Android, so
  parsing, the model, MIDI, and layout geometry are reusable from Kotlin.
- **Non-goal:** an interactive notation-editor *UI*. Editing APIs do
  exist — the `EditCommand` set under `SheetMusicCore/Editing` (see
  `docs/edit-commands.md`) — but the model is immutable value types;
  editing is expressed as producing a new `Score`, not mutating a live
  object graph.
- **Non-goal:** runtime coupling to the MuseScore application. Behaviour
  is reproduced from studying MuseScore's source, not by shelling out to
  it.

## Library layout

The package is deliberately split into small, single-purpose products so
consumers pull in only what they need, and so the Foundation-only subset
stays cleanly separable for Android.

```
SheetMusic            umbrella + small convenience façade
  ├─→ SheetMusicCore     Score data model, SheetMusicError; no I/O
  ├─→ SheetMusicMSCX     .mscx / .mscz read + write
  ├─→ SheetMusicMusicXML .musicxml / .mxl import
  └─→ SheetMusicMIDI     in-memory MIDI model, render, SMF I/O

SheetMusicLayout      pure-geometry layout, Foundation-only, Android-compatible
SheetMusicLayoutApple CoreText font-metrics provider for Layout (Apple-only)
SheetMusicUI          SwiftUI notation viewer (Apple-only)
SheetMusicAudioCore   Foundation-only audio value types (Android-compatible)
SheetMusicAudioApple  AVAudioEngine playback + audio-file export (Apple-only)
SheetMusicPDF         PDF import (pure Swift, cross-platform) + PDF export (Apple-only)
SheetMusicOMRModel    bundled Core ML detector that lets PDF import read scanned pages (Apple-only, opt-in)
```

`SheetMusic` re-exports Core + MSCX + MusicXML + MIDI with
`@_exported import` and adds the façade. `Layout`, `UI`, `Audio`, and
`PDF` are **not** re-exported — consumers opt into them explicitly, which
keeps the default import surface (and Android build graph) minimal.

The dependency arrows only ever point "down" toward `Core`. There are no
back-pointers in the model; cross-references (e.g. which note a slur
targets) are resolved inside rendering passes, not stored in the types.

## Model conventions

- **Value types throughout.** Every `Score` / MIDI type is a `struct` or
  `enum`, `Sendable`, with no reference identity. This makes scores
  trivially shareable across concurrency domains and makes rendering a
  pure function of the input.
- **One responsibility per file** — SwiftLint warns past 400 lines.
  When a file outgrows its purpose it is split by concern
  (e.g. `MidiRenderer` → `MidiRenderer+Voice.swift`, `+Repeats.swift`,
  `+Header.swift`), not left to sprawl.
- **Errors via `throws`.** A single `SheetMusicError` enum; no `Result`
  types and no Optional-return-means-failure conventions. `SheetMusicError`
  deliberately does not conform to `LocalizedError` or
  `CustomStringConvertible`: its built-in English `developerDescription` is a
  diagnostic string for logs and tests, not locale-sensitive UI copy. Apps
  should switch over the enum cases and provide their own presentation and
  localization. Parser and container failures carry a `ScoreFault`, whose
  stable dotted `code` is the localization key and whose English `message` is
  log-only context. Editing failures carry an `EditRefusal`, whose typed
  `reason` lets hosts branch without string-matching prose.
- **Reference family.** Every score location a new `EditCommand` carries —
  a measure column, a part, a voice, a range — is a member of a closed
  family under `Sources/SheetMusicCore/Score/References/` (`MeasureRef`,
  `PartRef`, `VoiceRef`, `VoiceElementRange`, alongside the older
  `VoiceElementID` / `NoteID` / `RestID` / `TupletID` / `StaffAddress`),
  resolved only through the `Score` accessors in
  `Score/References/Score+References.swift` (`Score.canonicalStaff` names
  the staff — part 0, staff 0 — that measure-level flags such as layout
  breaks and repeat barlines live on, per MuseScore's own
  `writeSystemElements`). Each member's `SheetMusicEditWire` mirror is a
  **nested** wire struct even when it holds a single integer, because
  Wirelet can append an `Optional` field to a struct with zero byte
  movement but can never turn a bare scalar into a struct compatibly; each
  mirror reserves its next unassigned tag with a doc comment ("tag N is
  reserved for SP0's optional stable identity; do not assign it") against
  the day a stable identity needs to attach there. See
  `docs/superpowers/specs/2026-09-02-edit-command-parity-design.md` §2 for
  the full rationale.

## Parser policy (MSCX / MusicXML)

The importers are **permissive by design** — real-world files contain
elements newer or more exotic than any parser fully models, and refusing
to load them is worse than degrading gracefully. Unknown elements inside
a `<voice>` are silently skipped. For *known* elements with unknown or
missing values, decoders apply a three-way policy:

- **Structural** (pitch, voice structure, time signature, division):
  throw `SheetMusicError.malformedScore`. Without these the score cannot
  be represented coherently, so failing loudly is correct.
- **Embellishment** (tremolo subtype, articulation kind, ornament
  subtype, fermata / breath style, hairpin shape, glissando style): drop
  the single decoration and emit a `ScoreDiagnostic`. The score still
  loads; the ornament is simply absent. Surface these via
  `MSCXParser.parseWithDiagnostics(...)`.
- **Cosmetic** (color, offset, font, stroke style): silently fall back to
  the model's neutral default.

This lets a single malformed ornament coexist with a fully usable score,
while genuinely un-representable input still fails fast.

## MuseScore as a behavioural specification

MuseScore's MIDI export and engraving behaviour is the reference target —
the test suite runs MuseScore's own `midiexport_tests.cpp` fixtures and
compares for semantic equivalence. That fidelity is achieved by
**studying** the MuseScore C++ source (GPL-3.0) as a behavioural spec and
**reimplementing** the algorithms in Swift from scratch. No C++ source is
copied into `Sources/`. Where an algorithm mirrors a specific MuseScore
routine, the Swift code carries a nominative doc comment pointing at the
originating class/function (e.g. `Mirrors CompatMidiRender::renderArpeggio`)
for traceability — a citation, not a transcription.

See `docs/musescore-engraving-reference.md` for the recurring
coordinate-unit / offset / style-default findings that porting work keeps
needing.

## Layout and rendering

`SheetMusicLayout` is **pure geometry with no Apple dependency**. It talks
to fonts through a `FontMetricsProvider` dependency-injection seam:

- On Apple platforms, `SheetMusicLayoutApple` supplies a CoreText-backed
  provider (auto-installed transitively by `SheetMusicUI` / `SheetMusicPDF`).
- On Android, the host installs a Bravura-measured SMuFL metrics table
  (`BravuraMetricsBuilder.buildTable` →
  `SheetMusicJNI.nativeInstallSMuFLMetrics`); absent one, a
  `StubFontMetricsProvider` returns rectangle approximations so layout
  still produces sane geometry.

This DI seam is why the layout engine can be shared across platforms
without `#if os(...)` scattered through the geometry code.

`SheetMusicUI` ships two rendering back-ends over the same layout output —
a SwiftUI `Canvas` renderer and a `CALayer` renderer (`ScoreView` uses the
`CALayer` path). Any change to glyph/run handling (e.g. mixed-font text
runs that mix a PUA music glyph with plain text) must be applied to
**both** back-ends, or the un-updated one renders a missing glyph.

`SheetMusicPDF` reuses `SheetMusicUI`'s drawing pipeline through an
`ImageRenderer` → `CGPDFContext` bridge, so printed pages match the
on-screen layout exactly and glyphs stay vector.

## Audio

Audio is split so that the platform-neutral value types live in
`SheetMusicAudioCore` (Foundation-only, Android-compatible):
`PlaybackTimeline`, `MetronomeBeat`, `GMInstrument`, `MixerChannel`,
`LoopRange`, `PlaybackState`, `AudioFileFormat`, and friends. The timeline
is a pure function of the score; the platform engines only schedule it.

- **Apple** (`SheetMusicAudioApple`): an `AVAudioEngine` graph feeding
  two multi-timbral AUMIDISynth units (melodic + percussion — chosen
  over `AVAudioUnitSampler`, whose one-node-per-staff graph it replaced)
  behind an injectable `SynthBackend` seam;
  `SheetMusicAudioSwiftySynth` supplies the default stealing-free
  pure-Swift SoundFont backend. Driven by the shared timeline, exposing
  a chord-by-chord `currentCursor`. Audio-file export renders the same
  graph offline.
- **Android** (`Android/SheetMusicAudioAndroid/`, Kotlin): FluidSynth via
  VolcanoMobile's `.aar` + Oboe for low-latency PCM, mirroring the Apple
  `PlaybackEngine` API surface (looping, rate, per-staff program change,
  master tuning).

## Android strategy

The Foundation-only targets (Core / MSCX / MusicXML / MIDI / Loader /
Layout / AudioCore / EditWire / PDF import) cross-compile with the
official swift.org Android SDK. Kotlin
consumes them through a JNI bridge whose wire format is generated from
Swift `@WireFormat` types by the
[`swift-wirelet`](https://github.com/jiyimeta/swift-wirelet) Gradle plugin
— one source of truth for the Swift↔Kotlin codecs, no hand-maintained
parallel serialization. See `docs/development/android.md` for the toolchain
and contributor workflow, and the Android module READMEs for the consumer
story.

That bridge is split across two targets, and the seam is drawn by a
constraint rather than by taste:

- **`Sources/SheetMusicAndroidJNI`** holds the `native*` entry points and
  nothing else. swift-java's jextract scans exactly one directory —
  the target's own — so an entry point only becomes a JNI symbol if its
  source file physically lives here.
- **`Sources/SheetMusicBridgeCore`** holds everything those entry points
  call: the layout and draw-program bridge, the handle tables, the SMuFL
  metrics table and the wire codecs. It depends on neither `SheetMusicPDF`
  nor SwiftJava, which is what lets it build for WebAssembly — so a
  browser bridge reuses this implementation instead of growing a second
  one beside it. (`SheetMusicEditWire` *is* a dependency, and that is
  fine: it has built for wasm since Wirelet 0.4.1.)

The wirelet Gradle plugin scans `SheetMusicBridgeCore/Metadata`,
`SheetMusicBridgeCore/Audio` and `SheetMusicBridgeCore/Draw`, plus
`SheetMusicEditWire/Path` and `SheetMusicEditWire/Geometry`, for the
`@WireFormat` types it turns into Kotlin codecs.

`SheetMusicUI` remains Apple-only, as does `SheetMusicPDF`'s *export*
half; the PDF *importer* is a pure-Swift reader that ships on Android
too. Android rendering draws from the layout geometry plus the
Bravura-measured SMuFL metrics table the host installs.
