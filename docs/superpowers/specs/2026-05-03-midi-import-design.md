# MIDI Import Design

Date: 2026-05-03
Status: Approved (pre-implementation)

## Overview

Add a MIDI (`.mid` / SMF) import path to `SheetMusicMIDI`, producing
the existing `Score` model so any consumer that already handles MSCX /
MusicXML imports gains MIDI support transparently. MIDI files carry no
layout information, so layout fields default; the score title comes
from SMF Track 0 by convention or, failing that, the source filename.

Quantization is the central design problem. We adopt a conservative
onset-grid fitting strategy ("D'") that supports tuplets at multiple
time scales (eighth-triplet through half-triplet, plus quintuplets
and septuplets) including unequal-duration members within a single
tuplet — but not literal nested tuplets (a tuplet inside another
tuplet). Swing is detected statistically and surfaced via a
delegate-style resolver; the library itself never silently
re-interprets swing.

## Scope

**In scope (v1):**

- SMF Format 0 and Format 1, PPQ (metrical) division only.
- Track → Part assignment with GM channel-10 drumset isolation.
- Time-signature-driven barlining (no anacrusis detection).
- Single-voice voicing with tie generation across simultaneous-onset
  but different-offset note groups.
- D' quantize with `(3,2)`, `(5,4)`, `(7,4)` tuplet detection.
- Pitch-bend → `Glissando` detection (narrow / round-trip-only,
  fixed 12-semitone bend range).
- Statistical swing detection with caller-supplied resolver
  (sync + async closure variants).
- Tempo / key signature / time signature meta event ingestion.
- Title from Track 0 trackName (SMF convention) with filename
  fallback.
- Example app integration: open `.mid` from existing file picker.

**Out of scope (v1, deliberately YAGNI):**

- SMF Format 2.
- SMPTE timecode division.
- Velocity → `Dynamic` mapping (waits for `Dynamic` reading
  infrastructure).
- Pitch-bend RPN sensitivity tracking (assume fixed 12 semitones).
- Polyphonic voice splitting (multi-voice). v1 collapses to single
  voice + ties.
- Anacrusis (pickup measure) detection.
- Nested tuplets (tuplet inside tuplet).
- Tuplet ratios outside `{(3,2), (5,4), (7,4)}`.
- Tuplets that cross beat / bar boundaries.
- Continuous controllers (CC, program change after the first event,
  expression, modulation) — discarded.
- Multi-staff parts (e.g., piano grand staff): each ImportTrack
  produces exactly one staff.
- Bundled `.mid` sample in the example app.
- MIDI export menu in the example app.

## Architecture

```
Sources/SheetMusicMIDI/
├── IO/
│   ├── BinaryEncoder.swift            (existing)
│   ├── VariableLengthQuantity.swift   (existing)
│   ├── MidiWriter.swift               (existing)
│   └── MidiReader.swift               NEW — SMF bytes → MidiFile
├── Import/                              NEW directory
│   ├── MidiImportOptions.swift        NEW — public options + types
│   ├── MidiImporter.swift             NEW — public façade
│   ├── MidiImporter+Tracks.swift      NEW — track partition / drum split
│   ├── MidiImporter+Meta.swift        NEW — bar segment / meta routing
│   ├── MidiImporter+Swing.swift       NEW — swing analysis
│   ├── MidiImporter+Quantize.swift    NEW — D' grid / tuplet fit
│   ├── MidiImporter+Voicing.swift     NEW — single-voice + tie gen
│   └── MidiImporter+Pitchbend.swift   NEW — D'_glissando detection
├── Model/   (existing, unchanged)
└── Render/  (existing, unchanged)
```

The 300-line file cap (per `CLAUDE.md`) requires `MidiImporter.swift`
to stay a thin façade; logic lives in the extension files.

`SheetMusic` (umbrella) gains four new entry points:

```swift
public extension SheetMusic {
    static func loadScore(
        midiData: Data,
        options: MidiImportOptions = .init(),
        sourceFilename: String? = nil
    ) throws -> Score

    static func loadScore(
        midiData: Data,
        options: MidiImportOptions,
        sourceFilename: String? = nil
    ) async throws -> Score

    static func loadScore(
        midiURL: URL,
        options: MidiImportOptions = .init()
    ) throws -> Score

    static func loadScore(
        midiURL: URL,
        options: MidiImportOptions
    ) async throws -> Score
}
```

The URL overloads pass `url.deletingPathExtension().lastPathComponent`
as `sourceFilename` for the title fallback.

## Public API

```swift
public struct MidiImportOptions: Sendable {
    /// Smallest binary subdivision the quantizer will produce.
    /// Onsets finer than this snap to this grid (or to a tuplet).
    public var quantizeGrid: NoteDuration = .sixteenth

    /// Onset fit tolerance in ticks. `nil` → `division / 16`.
    public var onsetTolerance: Int? = nil

    /// Tuplet ratios to attempt, in priority order. Empty disables
    /// tuplet detection entirely.
    public var tupletRatios: [(actual: Int, normal: Int)] =
        [(3, 2), (5, 4), (7, 4)]

    /// Pitch-bend → Glissando detection. Bend range is fixed at 12
    /// semitones (matching `MidiRenderer`'s pitch-bend range header).
    public var detectGlissando: Bool = true

    /// Sync resolver, used by the non-async parse path.
    public var resolveSwing:
        (@Sendable (SwingDetection) -> SwingResolution)? = nil

    /// Async resolver, used by the async parse path. Falls back to
    /// `resolveSwing` if `nil`.
    public var resolveSwingAsync:
        (@Sendable (SwingDetection) async -> SwingResolution)? = nil

    public init() {}
}

public struct SwingDetection: Sendable {
    public let trackIndex: Int
    public let measureRange: Range<Int>
    public let estimatedRatio: Double
    public let confidence: Double
    public let sampleSize: Int
}

public enum SwingResolution: Sendable {
    case treatAsSwing
    case treatAsWritten
}

public enum MidiImporter {
    public static func parse(
        _ midiData: Data,
        options: MidiImportOptions = .init(),
        sourceFilename: String? = nil
    ) throws -> Score

    public static func parse(
        _ midiData: Data,
        options: MidiImportOptions,
        sourceFilename: String? = nil
    ) async throws -> Score
}
```

The sync path consults `resolveSwing` only; the async path prefers
`resolveSwingAsync` and falls back to `resolveSwing`. Both `nil`
implies `.treatAsWritten`.

## Pipeline

```
Data
  │ Pass 1: MidiReader.read(_:)
  ▼
MidiFile
  │ Pass 2: TrackPartitioner.partition
  ▼
[ImportTrack]
  │ Pass 3: SwingAnalyzer.analyze (resolver invoked here)
  ▼
[ImportTrack]
  │ Pass 4: BarSegmenter.segment
  ▼
[[ImportMeasure]]
  │ Pass 5: MeasureQuantizer.quantize  ← D' core
  ▼
[[QuantizedMeasure]]
  │ Pass 6: ScoreAssembler.assemble
  ▼
Score
```

### Pass 1 — `MidiReader`

Parses SMF bytes into the existing `MidiFile` model. Supports VLQ,
running status, SysEx, all standard text meta events. Unknown meta
or SysEx is silently skipped (mirroring the MSCX parser's permissive
posture). Format 2 and SMPTE division throw
`SheetMusicError.unsupportedFeature`.

### Pass 2 — `TrackPartitioner`

Internal type:

```swift
struct ImportTrack {
    var trackIndex: Int          // original SMF track index
    var trackName: String?       // first FF 03 in the track
    var isDrums: Bool            // ch10 isolated track
    var programChange: Int?      // first program change (any channel)
    var events: [TimedMidiEvent]
}
```

- **Format 1**: each SMF track yields one or more ImportTracks based
  on channel content:
  - Track contains only ch10 (drum) events → 1 ImportTrack with
    `isDrums = true`.
  - Track contains only non-ch10 events → 1 ImportTrack with
    `isDrums = false`.
  - Track mixes ch10 and non-ch10 events → 2 ImportTracks (the
    non-drum events keep the original `trackName`; the drum split
    inherits the same name with `" (drums)"` appended).
- **Format 0**: the single track is split the same way (1 or 2
  ImportTracks depending on whether ch10 is present).
- Tracks containing only meta events (typical Format 1 Track 0
  tempo map) produce no ImportTrack but feed Pass 4's meta routing.

### Pass 3 — `SwingAnalyzer`

Per ImportTrack: collects triples of consecutive note onsets
`(t0, t1, t2)` where `t0` lies on a beat boundary, `t2` lies on the
next beat boundary, and `t1` falls between them — i.e. the two
intervals sum to one beat. Computes per-triple ratio
`(t2 - t1) / (t1 - t0)` (back-eighth length divided by front-eighth
length). Detection fires when:

- sample count ≥ 8
- mean ratio ∈ [1.4, 2.5]
- standard deviation < 0.15

Builds a `SwingDetection`, calls the resolver. On `.treatAsSwing`,
rewrites tick offsets within the detected measure range so the back
eighth lands on the beat midpoint (straight). On `.treatAsWritten`
or no resolver, the track is unchanged.

### Pass 4 — `BarSegmenter`

Builds a global tick → measure-index map from time-signature meta
events (default 4/4 if none). Splits each ImportTrack's events into
per-measure `ImportMeasure` records. Notes whose noteOn falls in
measure N and noteOff falls in measure N+k (k ≥ 1) are stored on
each affected `ImportMeasure` with a `crossingNote` flag so Pass 6
can emit tied chords across the bar boundary.

### Pass 5 — `MeasureQuantizer` (D' core)

Per measure:

1. **Candidate spans**: try the full measure first, then split into
   halves of the measure, then quarters of the measure (which equal
   a beat in 4/4), then half-beats. Each subdivision is a
   power-of-two split anchored at the measure start. Span sizes
   that don't divide evenly into the current time signature
   (e.g. 3/4 has no clean half-measure split into two 2-beat spans)
   skip that level and continue at the next finer subdivision.
2. **Binary fit**: for each span, attempt grid sizes
   `[quantizeGrid_ticks, quantizeGrid/2, ...]` that divide the span.
   All onsets in the span must lie within `onsetTolerance` of a grid
   point.
3. **Tuplet fit**: if binary fit fails, try each `(actual, normal)`
   in `tupletRatios`. The tuplet grid is `span / actual`. If all
   onsets fit, the span is a tuplet of that ratio.
4. **Recurse**: if neither fits, subdivide and retry. At the
   smallest span (half-beat) any unfit onset is force-snapped to the
   nearest `quantizeGrid` point.
5. **Member duration**: for a confirmed tuplet of `(actual, normal)`
   on span `S`, each onset `o` maps to position `(o - span_start) /
   (S / actual)` (a tuplet-unit count). Member durations are written
   as the underlying `NoteDuration` (e.g. `.half`, `.quarter`); the
   `Voice.tuplets` entry carries the `(actual, normal)` ratio that
   scales playback. This matches how `MidiRenderer` writes tuplets.

#### Worked example: half triplet with `half + quarter`

- Span: full measure, 1920 ticks at 480 PPQ (4/4).
- Onsets: `[0, 1280]`, with the second note's noteOff at `1920`.
- Binary fit fails (onset 1280 isn't on any binary 16th grid in
  `[0..1920]`).
- Try `(3, 2)`: `tuplet_unit = 1920 / 3 = 640`. Onsets `0` and
  `1280` map to tuplet positions `0` and `2` exactly. Fit succeeds.
- Members: position 0 → 2 units (half), position 2 → 1 unit
  (quarter).
- Output: two `VoiceElement.chord(...)` with durations `.half` and
  `.quarter`, and a `Tuplet(normalNotes: 2, actualNotes: 3,
  startIndex: i, endIndex: i+1)`.

#### Conservative posture

A span confirmed as a tuplet must have *every* onset on the tuplet
grid. Mixing a tuplet member with a "regular" 16th in the same span
makes the span fail the tuplet test, which forces the quantizer to
re-split and treat each beat independently. This is a deliberate
loss: triplet + 16th mixes are rare and ambiguous.

### Pass 6 — `ScoreAssembler`

For each `QuantizedMeasure` produces a `Voice`:

```
sustained: [pitch: NoteSlot]   // currently held pitches
output:    [VoiceElement]
cursor:    Int = measure.startTick

for each grid_position g (sorted union of all event ticks):
    ending  = pitches in `sustained` whose noteOff tick == g
    arriving = pitches with NoteOn at g

    gap = g - cursor
    if gap > 0:
        if sustained.isEmpty:
            output.append(.chord(Chord(duration: tickToDuration(gap),
                                       notes: [])))   // rest
        else:
            // emit a chord carrying every currently held pitch
            output.append(.chord(Chord(duration: tickToDuration(gap),
                                       notes: <held pitches with
                                              tieBack from prior
                                              chord, tieForward iff
                                              still held after g>)))

    sustained.subtract(ending)
    sustained.formUnion(arriving)
    cursor = g

if !sustained.isEmpty: emit final chord with tieForward across bar
```

Rests are unified-representation `Chord(notes: [])` per
`VoiceElement.swift`. The `.rest(duration:)` static helper is
equivalent and may be used internally.

Tie generation:

- Same pitch carries from chord N to chord N+1 within a bar →
  `Note.tieForward = 1` on N, `Note.tieBack = 1` on N+1.
- noteOn in measure M, noteOff in measure M+k → Pass 6 emits a
  tied chord at the start of each intervening bar.

Tuplet ranges from Pass 5 are translated from tick ranges to
`elements` index ranges and appended to `Voice.tuplets`.

Drum tracks (`isDrums = true`):

- `Instrument.useDrumset = true`.
- `Note.headType` populated from a hard-coded GM drum-pitch table
  (35 → bass-drum head, 42 → cross / hi-hat, etc.).
- Glissando detection skipped on the track.

Meta events are routed onto the first staff: tempo, time signature,
and key signature land at the head of the corresponding measure's
voice 0 as `VoiceElement.tempo` / `.timeSignature` / `.keySignature`.

Title resolution (in priority order):

1. **Format 1, conventional case**: SMF Track 0 contains no note
   events but has a track-name meta → that string becomes
   `metaTags["workTitle"]`. The Track 0 name is *not* used as a
   `Part.trackName` (Track 0 produces no ImportTrack in this case).
2. **Format 1, Track 0 has notes**: out-of-convention. The Track 0
   name is treated as a part name (kept on the resulting Part),
   and the title falls through to `sourceFilename`.
3. **Format 0**: the single track's name (if present) becomes both
   `metaTags["workTitle"]` and the produced Part's `Part.trackName`.
4. **Otherwise**: `sourceFilename` (with extension stripped) becomes
   `metaTags["workTitle"]`. The key is omitted entirely if
   `sourceFilename` is `nil`.

## Pitch-bend → Glissando (D'_glissando)

Run during Pass 6 if `options.detectGlissando == true`, and only on
non-drum tracks.

For each held note `(pitch p, channel c, on=tStart, off=tEnd)`,
collect pitch-bend events on channel `c` in `[tStart, tEnd]`. Detect
a glissando candidate when:

- The bend sequence is monotonic (counted exceptions ≤ 5% of
  samples, accommodating quantization noise).
- The final bend value, divided by `8192/12` (= ticks per semitone
  at the assumed 12-semitone range), is within ±15 % of an integer
  number of semitones `s ≠ 0`.
- The next chord on the same channel begins with a note whose pitch
  equals `p + s`.

When all three hold, attach
`Glissando(style: .portamento, visualType: .straight)` to the source
note. Otherwise the bend stream is silently discarded.

This is intentionally narrow: it round-trips our own
`MidiRenderer`-produced glissando MIDI faithfully (since that
renderer writes the exact pattern above), and ignores arbitrary
pitch-bend usage (vibrato, expressive bends, portamento setup).

## Errors

Permissive posture; `unsupportedFeature` is reserved for cases the
library cannot represent at all.

| Situation | Behaviour |
|---|---|
| Invalid SMF header / truncated MThd | `malformedScore(reason:)` |
| Format 2 | `unsupportedFeature(name: "MIDI format 2", ...)` |
| SMPTE division | `unsupportedFeature(name: "SMPTE timecode division", ...)` |
| Unknown meta / SysEx | silently skipped |
| `noteOn` velocity 0 | treated as `noteOff` |
| Orphan `noteOff` | ignored |
| `noteOn` with no matching `noteOff` before EOF | force-close at track end |
| Same-pitch `noteOn` while pitch already held | force-close prior, restart with new |
| Quantize fails to fit any onset | force-snap to `quantizeGrid`, parse succeeds |
| Tuplet detection fails | binary fit fallback, parse succeeds |
| Pitch-bend detection criteria not met | bend ignored, parse succeeds |
| Swing resolver `nil` | swing not applied, parse succeeds |

## Testing

Add `Tests/SheetMusicTests/MidiImportTests.swift` using Swift
Testing (`@Test`, `#expect`). Suites:

1. **`MidiReader`** — Format 0/1 round-trip with existing renderer
   output; Format 2 / SMPTE → throws; VLQ edges; running status;
   unknown meta skipped.
2. **`TrackPartitioner`** — Format 1 mixed drum / non-drum track →
   2 ImportTracks; Format 0 → 1–2 ImportTracks; track names plumbed.
3. **`BarSegmenter`** — fixed 4/4; mid-piece time-sig change;
   missing time-sig → 4/4; cross-bar notes flagged.
4. **`MeasureQuantizer` (D')** — straight 16ths fit binary; eighth
   triplet → `Tuplet(2,3)` with three eighths; quarter triplet →
   `Tuplet(2,3)` over two beats; **half triplet with `half+quarter`
   members → `Tuplet(2,3)` with members `[half, quarter]`**;
   quintuplet `(5,4)`; mixed triplet + 16th in one beat falls back
   to binary; tolerance edge cases.
5. **`Voicing` / Tie** — simultaneous on, simultaneous off → single
   chord; simultaneous on, staggered off → tie continuation; cross-
   bar note → tieForward + tieBack pair across bar boundary;
   sustained empty + gap → empty-chord rest; drum track →
   `headType` populated, `useDrumset = true`.
6. **Meta** — tempo change → `VoiceElement.tempo` on staff 0; key
   sig → `VoiceElement.keySignature`; Format 1 title from Track 0
   name; Format 0 title from sole track name (also as
   `Part.trackName`); URL-only fallback to filename.
7. **Pitch-bend / Glissando** — round-trip a glissando-bearing
   `Score` through `MidiRenderer` → `MidiImporter`, expect
   `Glissando` reconstructed; vibrato bend ignored; mismatched
   target pitch ignored.
8. **Swing** — straight 8ths → resolver not invoked; 2:1 swung
   eighths → resolver invoked with ratio ≈ 2.0;
   `.treatAsSwing` → straightened onsets; `.treatAsWritten` →
   triplet-quarter+eighth pairs in output; async API uses
   `resolveSwingAsync`.
9. **Round-trip with `MidiRenderer`** — for the existing
   `MidiExportTests` mscx fixtures: parse → render → reparse →
   re-render → byte (or `MidiSemanticComparison`) equality.
10. **Errors** — truncated MThd → `malformedScore`; Format 2 →
    `unsupportedFeature`; orphan noteOff → silently dropped, parse
    OK.

## Example app integration

Three small edits, no project regen:

- `Example/SheetMusicExample/ScoreFileType.swift` — add `case midi`,
  add `UTType.midi` to `allUTTypes`, add `"mid" / "midi"` to
  `detect(url:)`.
- `Example/SheetMusicExample/Shared/ScoreLoader.swift` — extend the
  `switch ScoreFileType.detect(url:)` with
  `case .midi: return try SheetMusic.loadScore(midiURL: url)`.
- No swing-resolver wiring in v1: example uses the default
  `.treatAsWritten` behaviour. A swing-aware UI can be added in a
  follow-up.

## Naming and conventions

- Public types live in `SheetMusicMIDI`; the umbrella `SheetMusic`
  re-exports via existing `@_exported import`.
- Internal types (`ImportTrack`, `ImportMeasure`, `QuantizedMeasure`)
  are file-private or `internal`, never public.
- File-length cap: 300 lines per file (split with
  `MidiImporter+<Aspect>.swift` extensions, mirroring the existing
  `MidiRenderer+<Aspect>.swift` layout).
- Reference comments to the matching `MidiRenderer` code where the
  import logic inverts an export step (e.g., glissando detection
  notes that it inverts `MidiRenderer+Glissando.swift`).
