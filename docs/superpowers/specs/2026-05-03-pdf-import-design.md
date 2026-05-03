# PDF Import Design

Date: 2026-05-03
Status: Approved (pre-implementation)

## Overview

Add a PDF import path to `SheetMusicPDF`, producing the existing
`Score` model so any consumer that already handles MSCX / MusicXML /
MIDI imports gains PDF support transparently. The library targets
**vector PDFs produced by MuseScore 3.x and 4.x**, which embed
SMuFL-compliant music fonts (Bravura, Leland) so every notehead,
clef, accidental, rest, and time-signature digit comes through as a
positioned glyph with a known semantic meaning. No OCR, no neural
nets, no external dependencies — just structural extraction from the
PDF content stream via PDFKit / `CGPDFContentStream`.

The two MuseScore generations both emit identical SMuFL Private Use
Area codepoints (verified by inspecting the user's `test.pdf`
written by 3.6.2 and `test_msc4.pdf` written by 4.6.5), so a single
codepoint table covers both. Lyrics, tempo numerals, expression
text, instrument names, and titles arrive as ordinary Unicode and
are extracted as-is.

The design problem at the core is reconstructing musical structure
from the geometric layout: classifying glyphs into staves and
measures, recovering pitch from notehead y-position under a clef
and key context, recovering rhythm from beam / flag / dot
decoration, and partitioning chords into voices when the staff is
polyphonic.

## Scope

**In scope (v1):**

- Vector PDFs from MuseScore 3.x and 4.x (SMuFL fonts: Bravura,
  Leland, LelandText).
- Notes, rests, chords, ties.
- Time signature, key signature, tempo, barlines.
- Multi-staff parts (piano grand staff) and multiple parts per
  system.
- Structure marks: repeats (start-repeat / end-repeat barlines),
  voltas (1st / 2nd ending brackets), double barlines, rehearsal
  marks.
- Lyrics: multiple verses, hyphen continuation, melisma underscore.
- Tempo marking text and metronome equation (`♩ = 128`).
- Title, subtitle, composer, arranger — from frame text and PDF
  metadata fallback.
- Multi-voice (voice 1 / voice 2) when stem-direction and
  time-coverage analysis determines two voices coexist on a staff.
- System / page break preservation as `Measure.lineBreak` /
  `Measure.pageBreak`, controlled by `PDFImportOptions.preserveBreaks`
  (default `true`).
- Sync API only (`throws -> Score`). PDF parsing is CPU-bound; async
  callers wrap with `Task { ... }` themselves.
- Diagnostics callback for surfacing non-fatal recognition issues
  to the caller.
- Example app integration: open `.pdf` from existing file picker.

**Out of scope (v1, deliberately YAGNI):**

- Scanned / photographed (raster-only) PDFs. No OCR, no Vision
  framework, no Core ML. Future spec.
- PDFs from non-MuseScore engravers (Sibelius, Finale, Dorico,
  LilyPond). Many are SMuFL-compliant and may work incidentally,
  but v1 does not commit to supporting them.
- MuseScore 2 and earlier, or any PDF using Emmentaler / MScore
  (LilyPond-derived) fonts.
- Dynamics, slurs, articulations, ornaments, pedal marks, hairpins,
  ottava, fermatas, glissandi, tremolos, fingerings, bowings.
- Chord symbols and figured bass.
- Voices 3 and 4 (collapse into voice 1 / 2 silently with a
  diagnostic).
- Cross-staff beaming.
- Page numbers, headers, footers, copyright lines, and other
  page-chrome text — discarded.
- Tuplets nested inside tuplets.
- Anacrusis (pickup measure) detection. The first measure's
  duration is taken at face value from the detected note content;
  no special "shortened first measure" handling.
- Embedded raster images on otherwise vector PDFs (treated as PDF
  decoration and ignored).

## Architecture

```
Sources/SheetMusicPDF/
├── (existing) PDFExporter.swift, PageChromeRenderer.swift,
│   EngravingPage.swift, PDFPageView.swift, …  (export side, untouched)
└── Import/                                      NEW directory
    ├── PDFImportOptions.swift                   public options + diagnostics
    ├── PDFImporter.swift                        public façade (caseless enum)
    ├── PDFImporter+ContentStream.swift          CGPDFContentStream walking
    ├── PDFImporter+SMuFL.swift                  codepoint → semantic table
    ├── PDFImporter+StaffLines.swift             5-line staff extraction
    ├── PDFImporter+Layout.swift                 page→system→staff→measure
    ├── PDFImporter+Pitch.swift                  clef/key/accidental → pitch
    ├── PDFImporter+Rhythm.swift                 flag/beam/dot → duration
    ├── PDFImporter+Voicing.swift                multi-voice detection + assign
    ├── PDFImporter+Lyrics.swift                 lyric line clustering
    ├── PDFImporter+Structure.swift              repeats, voltas, marks
    ├── PDFImporter+Text.swift                   title / composer extraction
    └── Internal.swift                           shared internal types
```

The 300-line file cap (per `CLAUDE.md`) requires `PDFImporter.swift`
to stay a thin façade; logic lives in the extension files. The
plus-suffixed files mirror the MIDI import layout
(`MidiImporter+*`).

### Dependencies

- `SheetMusicPDF` already depends on `SheetMusicCore`. Import side
  additionally uses `PDFKit` (which transitively imports
  `CoreGraphics`). No new package dependencies.
- Apple platform availability: PDFKit ships on iOS 11+ and macOS
  10.13+, well within the existing minimum target.
- `Score` model is unchanged. All v1 features map to existing types
  (`Measure.lineBreak` / `pageBreak`, `Spanner.SubType.volta`,
  `BarLine.subtype`, `Marker`, `Jump`, `RehearsalMark`, `Lyric`,
  `Voice`, `Tempo`, `KeySignature`, `TimeSignature`).

### `SheetMusic` umbrella additions

```swift
public extension SheetMusic {
    static func loadScore(
        pdfURL: URL,
        options: PDFImportOptions = .init()
    ) throws -> Score

    static func loadScore(
        pdfData: Data,
        options: PDFImportOptions = .init()
    ) throws -> Score
}
```

Matches the MSCX / MSCZ / MusicXML overload pattern. Sync only;
async wrapping is the caller's responsibility (see Public API
section for rationale).

## Public API

```swift
public struct PDFImportOptions: Sendable {
    /// Preserve the source PDF's system and page breaks as
    /// `Measure.lineBreak` / `Measure.pageBreak`. When `false`,
    /// SheetMusicLayout reflows from scratch.
    public var preserveBreaks: Bool = true

    /// When the page-frame title text is missing, fall back to
    /// PDFDocument metadata (Title / Author / Subject) for
    /// `Score.title` / `Score.composer`.
    public var useMetadataAsFallback: Bool = true

    /// Non-fatal recognition issues are reported here. `nil`
    /// silently degrades.
    public var diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?

    public init() {}
}

public struct PDFImportDiagnostic: Sendable {
    public enum Severity: Sendable { case info, warning }
    public let severity: Severity
    /// Human-readable position, e.g. "page 3, system 2, measure 17".
    public let location: String
    public let message: String
    /// Extra context, e.g. an unknown SMuFL codepoint as hex.
    public let context: String?
}

public enum PDFImporter {
    public static func parse(
        pdfURL: URL,
        options: PDFImportOptions = .init()
    ) throws -> Score

    public static func parse(
        pdfData: Data,
        options: PDFImportOptions = .init()
    ) throws -> Score
}
```

`PDFImporter` is a caseless `enum` namespace, mirroring
`MidiImporter`. The work is purely CPU-bound (PDFKit /
`CGPDFContentStream` are sync APIs), so wrapping in `async` would
add no value — callers who need to keep the main thread free do
`Task { try PDFImporter.parse(pdfURL: url) }` themselves. This
matches the MSCX / MSCZ / MusicXML loaders. If a future use case
requires async (e.g., a remote-fetch overload), it can be added
non-destructively.

## Pipeline

```
URL/Data
  │
  ▼
[1] Open PDFDocument; enumerate pages.
  │
  ▼
[2] PDFImporter+ContentStream:
    walk each page's content stream via CGPDFContentStream,
    capturing every Tj/TJ glyph (codepoint, font, ctm-resolved
    position, glyph advance) AND every path operator
    (m/l/c/h/re) for staff and barline detection.
  │
  ▼
[3] PDFImporter+SMuFL:
    classify each glyph by (font, codepoint).
    → ClassifiedGlyph: notehead, clef, accidental, rest, flag,
      time-signature digit, repeat dot, articulation, …
    → TextGlyph: lyric, expression, tempo number, instrument
      name, title text, page chrome, …
  │
  ▼
[4] PDFImporter+StaffLines:
    distil straight horizontal path segments into 5-line staff
    bands. MuseScore renders staves either as a single
    `staff5Lines` glyph (U+E003) or as five separate path
    segments — both paths are honoured. Output: ordered list of
    `Staff(yLines: [Double; 5], xRange: Range<Double>)`.
    Vertical short segments inside the staff x-range are
    candidate barlines.
  │
  ▼
[5] PDFImporter+Layout:
    cluster `Staff` records by y-coordinate ranges into
    `System`s. Inside a system, group staves coupled by
    bracket/brace path elements into `Part`s (grand staff = 1
    part of 2 staves). Use barline x-positions to split each
    staff into measure cells. Output: a Page → System → Part →
    Staff → Measure tree with cross-staff measure alignment
    inside a system.
  │
  ▼
[5b] PDFImporter+Layout (continued — score-state extraction):
    before any pitch decoding, walk each staff once to extract
    the score-state events that other stages depend on, in the
    x-order they appear:
    - Clef glyphs (gClef U+E050, fClef U+E062, cClef U+E05C, …)
      → clef change events with measure index.
    - Time-signature digits (U+E080–U+E089) clustered into
      numerator / denominator pairs at staff start or after a
      double barline → `TimeSignature` events.
    - Key-signature: accidentals appearing before the first
      notehead of a measure (typically right after a clef or at
      the start of a system) → `KeySignature` event derived
      from the accidental count and direction.
    - Tempo markings: `LelandText` / `Edwin-*` text glyphs
      placed above the top staff of a system, optionally
      paired with a SMuFL note glyph and `=` and a number
      (e.g. `♩ = 128`) → `Tempo` event. Plain text marks like
      "Allegro" without BPM also produce a `Tempo` carrying
      only the text label.
  │
  ▼
[6] PDFImporter+Pitch:
    walk classified glyphs left-to-right per measure. Maintain
    a state machine for active clef, active key signature, and
    measure-local accidentals (per pitch class + octave;
    resets at every barline). Notehead y → diatonic step on
    staff → MIDI pitch + tonal pitch class.
  │
  ▼
[7] PDFImporter+Rhythm:
    for each notehead cluster, derive `NoteDuration` from:
    notehead glyph (whole / half / black), the presence and
    count of flag glyphs (single → 8th, double → 16th, …),
    horizontal beam path segments crossing the stem, and
    augmentation dot glyphs to the right of the notehead.
    Stacked noteheads sharing one stem path → `Chord`.
  │
  ▼
[8] PDFImporter+Voicing:
    detect multi-voice via time-coverage overlap (see
    "Voice detection" below). Assign chords to voice 1
    (stem up) or voice 2 (stem down) per measure, with rest
    y-position as a fallback when stems are absent.
  │
  ▼
[9] PDFImporter+Lyrics:
    cluster lyric `TextGlyph`s into y-bands directly under
    each staff (one band per verse). Match each syllable to
    the nearest notehead by x-position. Hyphen `-` → middle/
    end syllable; underscore `_` → melisma extension.
  │
  ▼
[10] PDFImporter+Structure:
     - Barline subtype from path geometry: thin/thin →
       `double`, thick+colon-dots → `start-repeat` /
       `end-repeat`.
     - Rectangular bracket path with internal `1.` / `2.`
       text spanning measures → `Spanner` (volta).
     - Capital letter inside a thin rectangle above a
       system's first measure → `RehearsalMark`.
     - Text "D.C." / "D.S." / "Fine" / "Coda" / "To Coda" →
       `Marker` / `Jump` adjacent to a barline.
  │
  ▼
[11] PDFImporter+Text:
     score-frame text extracted from upper page band:
     largest font → title, italic medium → subtitle,
     right-aligned → composer/arranger. Fallback to
     `PDFDocument` Title / Author metadata when
     `useMetadataAsFallback` is true.
  │
  ▼
[12] Assemble: build `Score` value. When
     `options.preserveBreaks` is true, set `lineBreak` on the
     last measure of each system and `pageBreak` on the last
     measure of each page. Empty-staff measures and partial
     pages are kept as-is (lenient).
```

### Voice detection — time-coverage overlap

**Naive approach (rejected):** assign voice purely by stem
direction. This breaks single-voice melodies that arch above and
below the staff middle line, where stem direction is
pitch-determined (high → down, low → up).

**Adopted approach:** within a measure, group consecutive beamed
notes into rhythmic units. A solo unbeamed chord is its own unit;
a solo rest is a unit. Each unit has a time interval `[x_start,
x_start + duration]` (duration converted from `NoteDuration` to
the measure's x-axis scale via the time signature). If any two
units' intervals overlap, the measure is multi-voice.

If single-voice: every chord and rest goes to voice 1, regardless
of stem direction.

If multi-voice: stem-up chords → voice 1, stem-down chords → voice
2. Stemless chords (whole notes) use staff-mid y-line as
discriminator. Rests use staff-mid y-line. Voices 3 and 4
collapse into voice 1 or 2 with a `PDFImportDiagnostic` warning.

## Failure modes

### Throws (`SheetMusicError`)

- File cannot be opened (corrupted, encrypted, missing).
- Page count is zero.
- No staff is detected on **any** page (verified-empty PDF, image-
  only PDF, or non-music PDF).
- Total glyph count across all pages is zero.

### Silent degrade (lenient — emits diagnostic if callback set)

- Unknown SMuFL codepoint → glyph ignored, `info` diagnostic.
- Out-of-scope notation (slur, hairpin, dynamic, …) → ignored,
  `info` diagnostic.
- Voices 3 / 4 → folded into 1 / 2, `warning` diagnostic.
- Unmatched tie endpoint → tie discarded, `warning` diagnostic.
- Path-band has only 3 or 4 horizontal lines → not recognised as a
  staff, `warning` diagnostic.
- Single-page recognition failure → that page's measures are empty
  in the output Score, `warning` diagnostic with `location: "page
  N"`. Other pages are unaffected. Throws only when **all** pages
  fail.

The "permissive parser" rule from `CLAUDE.md` applies: keep the
parts that parsed, drop the parts that didn't, and tell the caller
via diagnostics if they want to know.

## Example app integration

`Example/SheetMusicExample/`:

- `ScoreFileType.swift`: add `.pdf`.
- `ContentView.swift`: add `.pdf` to the file-picker content types.
- `Shared/ScoreLoader.swift`: branch on extension → `SheetMusic
  .loadScore(pdfURL:)`.
- `Info.plist`: add `com.adobe.pdf` to `CFBundleDocumentTypes`,
  matching the pattern established by the MIDI-import PR.

No bundled `.pdf` sample is shipped; users open their own files.

## Testing

Test fixtures live in `Tests/SheetMusicTests/Resources/pdf/` with
the same provenance discipline as the existing MuseScore-derived
fixtures:

- `Tests/SheetMusicTests/Resources/pdf/LICENSE` notes the source
  of any third-party PDFs (none in v1; only the user's own
  exports are used).
- `NOTICE` is updated if any externally-sourced PDF lands here.

### 1. Self-roundtrip golden test

For each `.mscx` fixture covered by `MidiExportTests`:

1. Parse with `MSCXParser` → `Score A`.
2. Render with `PDFExporter` → PDF data.
3. Parse the PDF data with `PDFImporter` → `Score B`.
4. Compare `Score A` and `Score B` for **musical-content
   equivalence**: same parts, staves, measures, voices, chords,
   notes (pitch + duration + tie), rests, key / time / tempo,
   barline subtypes, voltas, repeats, rehearsal marks, lyrics.
   Layout coordinates are excluded — they are PDF-side artifacts
   and SheetMusicLayout will recompute them on display.

This is the primary correctness contract: "the PDF I export is the
PDF I can re-import." MuseScore is not in the loop, so the test
runs in CI without external tools.

### 2. Component-level unit tests

Mirroring the MIDI import file split:

- `PDFImporterContentStreamTests`: glyph enumeration from a
  hand-crafted minimal PDF.
- `PDFImporterSMuFLTests`: every codepoint observed in the user's
  test PDFs maps to a defined semantic, and the inverse mapping
  table has no orphans.
- `PDFImporterStaffLinesTests`: synthetic path inputs produce the
  expected staff records, including the dual `staff5Lines`-glyph
  vs. five-segments path styles.
- `PDFImporterLayoutTests`: y-clustering of staves into systems,
  bracket-coupled grand-staff detection, barline-driven measure
  splitting.
- `PDFImporterPitchTests`: clef / key / accidental state-machine,
  with dense edge cases (mid-measure clef change, key change at
  barline, accidental propagation across the same pitch class +
  octave only, accidental reset at barline).
- `PDFImporterRhythmTests`: notehead + flag count + dot count →
  duration; beamed groups; multi-bar rests.
- `PDFImporterVoicingTests`: time-coverage overlap detection on a
  spread of single-voice / multi-voice / mixed cases (the
  beamed-eighths-vs-quarter-rest case is the canonical fixture).
- `PDFImporterLyricsTests`: y-band clustering, syllable-to-
  notehead matching, hyphen and melisma handling.
- `PDFImporterStructureTests`: repeat barlines, voltas with
  multiple measure spans, rehearsal-mark detection, jump
  markers.
- `PDFImporterFaçadeTests`: smoke test through `SheetMusic
  .loadScore(pdfURL:)`.
- `PDFImporterDiagnosticsTests`: an out-of-scope feature in a
  fixture (e.g., a slur) produces a warning when callback is set
  and is silent when callback is `nil`.

Each test file targets 100–200 lines, well under the 300-line cap.

### Performance target

A 26-page A4 PDF (the size of the user's `test_msc4.pdf`) parses
in **under 1 second** on contemporary Apple Silicon. This is a
loose target documented for awareness, not enforced as a CI
assertion (CI hardware variability would cause flakes).

## File layout summary (new)

```
Sources/SheetMusicPDF/Import/
  Internal.swift
  PDFImportOptions.swift
  PDFImporter.swift
  PDFImporter+ContentStream.swift
  PDFImporter+Layout.swift
  PDFImporter+Lyrics.swift
  PDFImporter+Pitch.swift
  PDFImporter+Rhythm.swift
  PDFImporter+SMuFL.swift
  PDFImporter+StaffLines.swift
  PDFImporter+Structure.swift
  PDFImporter+Text.swift
  PDFImporter+Voicing.swift

Sources/SheetMusic/SheetMusic.swift  (extended with two loadScore overloads)

Example/SheetMusicExample/
  ContentView.swift                  (.pdf added)
  Info.plist                         (com.adobe.pdf added)
  ScoreFileType.swift                (.pdf added)
  Shared/ScoreLoader.swift           (.pdf branch added)

Tests/SheetMusicTests/
  PDFImporterContentStreamTests.swift
  PDFImporterDiagnosticsTests.swift
  PDFImporterFaçadeTests.swift
  PDFImporterLayoutTests.swift
  PDFImporterLyricsTests.swift
  PDFImporterPitchTests.swift
  PDFImporterRhythmTests.swift
  PDFImporterRoundTripTests.swift    (the self-roundtrip golden)
  PDFImporterSMuFLTests.swift
  PDFImporterStaffLinesTests.swift
  PDFImporterStructureTests.swift
  PDFImporterVoicingTests.swift
```
