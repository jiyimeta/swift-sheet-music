# PDF Import — PAUSED (2026-05-03)

> Status: feature is implemented end-to-end behind an INTERNAL API on
> branch `feat/pdf-import`, but the recovery quality on real-world
> MuseScore PDFs is too low to ship. Work is suspended pending an
> unrelated breaking refactor that will likely touch
> `SheetMusicCore.Score` types this importer depends on. **Do not
> resume until that refactor lands.**

## Why paused

End-to-end smoke works on synthetic round-trip (`MSCXParser →
PDFExporter → PDFImporter` recovers parts/staves/measures structurally
on `midi01.mscx`), but importing real MuseScore PDFs surfaces a deep
content-recovery gap:

| Source PDF | Real staves | Recovered staves | Recovered notes/clef/rest |
|---|---|---|---|
| `~/Desktop/test.pdf`  (MS3, 10p)  | 6 | 1 | 0 |
| `~/Desktop/test_msc4.pdf` (MS4, 26p) | (multi)| 1 | 0 |

The 1-staff number is misleading: the staff-line detector finds *some*
horizontal-line cluster on each page, but the layout pass collapses
them into one logical staff slot, and the rhythm/pitch passes return
empty because **no `RawGlyph` is ever constructed from real PDFs** —
all SMuFL music glyphs flow into `[TextGlyph]` instead.

### Root cause of the content-recovery gap

The walker (`PDFImporter+ContentStream+Operators.swift`'s
`decodeString`) decodes Tj/TJ byte payloads as UTF-8/Latin-1 and emits
`TextGlyph`. For MuseScore exports the Tj operands are 2-byte CIDs
into a custom-encoded Bravura/Leland font, with the codepoint→PUA
mapping carried in the font's `/ToUnicode` CMap stream (`U+E0xx`
etc.). We never parse that CMap, so CIDs decode to mojibake instead
of SMuFL PUA codepoints, and `op_Tj` chooses the `TextGlyph` branch.
Downstream, `smuflSemantic` is never called on those glyphs and pitch
decoding has nothing to chew on.

This is the wall flagged in the original plan (Task 3 §implementation
note, Task 15 §Phase 2). It is the single biggest unblocker for real-
world recovery and it must be solved before re-publishing the API.

## Current branch state — `feat/pdf-import`

18 commits, **539 tests pass**, swiftlint silent. PDF import code is
held INTERNAL: nothing in `SheetMusicPDF`'s public surface mentions
the importer, the `SheetMusic` umbrella does not depend on
`SheetMusicPDF`, and the example app does not list `.pdf` as an
openable type.

```
85237a5 fix(pdf): drop lineWidth gate; admit real MuseScore staves
114c53a feat(example): open .pdf files from the picker          [REVERTED]
971efd7 feat(pdf): expose loadScore(pdfURL:) / (pdfData:)        [REVERTED]
e89be33 test(pdf): self-roundtrip golden across MSCX fixtures (loose v1)
30134ee feat(pdf): diagnostics callback for unknown codepoints + voicing collapse
c7137b0 feat(pdf): wire 12-stage import pipeline through façade
648ebf1 feat(pdf): title/composer extraction with metadata fallback
5f71860 feat(pdf): structural marks (repeats, voltas, rehearsals, jumps)
7ec9dce feat(pdf): lyric y-band clustering and syllable matching
688b260 feat(pdf): time-coverage multi-voice detection
6ecb672 feat(pdf): rhythm decoding (flag/dot) + chord assembly
810ffc7 feat(pdf): clef/key/accidental → pitch decoder
a0589a1 feat(pdf): clef/key/time/tempo extraction
1bbb721 feat(pdf): page→system→part→staff→measure layout
eeddf2b feat(pdf): staff-line detection from path + glyph
8a15a07 feat(pdf): content-stream walker (text + path segments)
2bf56c4 feat(pdf): SMuFL codepoint → semantic table
4b230da feat(pdf): scaffold PDFImporter façade and import options
```

The `[REVERTED]` lines indicate the API-exposure / example-app commits
that have since been backed out by a later "pause" commit. The
implementation files under `Sources/SheetMusicPDF/Import/` are
preserved.

## What's IN the tree right now (still compiling)

```
Sources/SheetMusicPDF/Import/
  Internal.swift
  PDFImportOptions.swift                    [internal]
  PDFImporter.swift                         [internal]
  PDFImporter+SMuFL.swift
  PDFImporter+ContentStream.swift
  PDFImporter+ContentStream+Operators.swift
  PDFImporter+StaffLines.swift              [lineWidth gate dropped 85237a5]
  PDFImporter+Layout.swift
  PDFImporter+ScoreState.swift
  PDFImporter+Pitch.swift
  PDFImporter+Rhythm.swift
  PDFImporter+Voicing.swift
  PDFImporter+Lyrics.swift
  PDFImporter+Structure.swift
  PDFImporter+Text.swift
  PDFImporter+Assemble.swift

Tests/SheetMusicTests/
  PDFImporter*Tests.swift   (14 suites)
  PDFImporterRoundTripTests.swift           (loose comparator, midi01)
  Helpers/PDFFixtureBuilder.swift
  Helpers/PDFRoundTripComparison.swift
```

All test targets reach the importer via `@testable import
SheetMusicPDF`, so they remain green even with the API held internal.

## What's OUT (reverted from public surface)

- `Sources/SheetMusic/SheetMusic.swift`: no `@_exported import
  SheetMusicPDF`; no `loadScore(pdfURL:)` / `loadScore(pdfData:)`
  overloads. A breadcrumb comment marks the intended re-exposure
  point.
- `Package.swift`: `SheetMusic` umbrella target's deps no longer list
  `SheetMusicPDF`. The library product `SheetMusicPDF` itself still
  exists (for `PDFExporter`, which is unrelated).
- `Tests/SheetMusicTests/SheetMusicFacadeTests.swift`: the two PDF
  umbrella tests are removed.
- `Example/SheetMusicExample/ScoreFileType.swift`: no `.pdf` case in
  the enum, no `.pdf` UTType in `allUTTypes`, no "pdf" branch in
  `detect(url:)`.
- `Example/SheetMusicExample/Shared/ScoreLoader.swift`: no `.pdf`
  branch in the format switch.
- `Example/Info.plist`: PDF entry removed from `CFBundleDocumentTypes`.

The example app's `.xcodeproj` is gitignored; regenerating with
`xcodegen` after the resume will pick up changes automatically.

## Resume checklist

When the breaking refactor is done and `SheetMusicCore` has stabilised:

1. **Adapt internal call sites** — most likely points of breakage:
   - `PDFImporter+Pitch.swift`: `Note(pitch:tpc:)` constructor and
     `Clef(concertClefType:)` strings.
   - `PDFImporter+ScoreState.swift`: `KeySignature(concertKey:)`,
     `TimeSignature(numerator:denominator:)`, `Tempo(beatsPerSecond:)`.
   - `PDFImporter+Rhythm.swift`: `Chord(duration:notes:)`,
     `ChordNotes`, `NoteDuration` cases & `.dotted(_:)`, `Fraction`.
   - `PDFImporter+Voicing.swift`: `Voice(elements:)`, `VoiceElement`
     case shape (currently relies on rest = empty-notes Chord).
   - `PDFImporter+Structure.swift`: `BarLine.subtype` strings,
     `Marker.Kind`, `Jump` field shape, `Spanner(kind:rawType:...)`,
     `RehearsalMark(text:)`.
   - `PDFImporter+Lyrics.swift`: `Lyric(text:syllabic:)`, `Syllabic`
     cases.
   - `PDFImporter+Text.swift`: `ScoreFrame(heightSp:texts:)`,
     `FrameText(style:text:)`, `FrameText.Style` cases.
   - `PDFImporter+Assemble.swift`: `Score(division:parts:staves:...)`,
     `Part(id:trackName:instrument:staffDeclarations:)`,
     `Instrument(id:...)`, `StaffDeclaration(staffType:group:...)`,
     `StaffContent(id:measures:)`, `Measure(voices:)`.
2. **Run `swift test`** — the 14 PDF importer test suites should
   keep the importer honest as types move underneath.
3. **Solve the CMap wall** before re-exposing the API. Concretely,
   under `PDFImporter+ContentStream+Operators.swift::decodeString`:
   - Capture each font's `/ToUnicode` CMap from the page's font
     dictionary at `Tf` time. Parse via `CGPDFDocumentRef`'s
     font-dict traversal (`CGPDFPageGetDictionary` →
     `/Resources/Font/<Fname>/ToUnicode`).
   - Replace the identity stub `ToUnicodeCMap` with a real CID→Unicode
     lookup. MuseScore exports use CIDs that match the SMuFL PUA
     codepoint; a faithful CMap parse should be enough.
   - Switch `op_Tj`/`op_TJ` to: decode each CID via the active CMap,
     then route SMuFL PUA codepoints to `RawGlyph` and remaining
     scalars to `TextGlyph`.
4. **Re-expose the public API**:
   - Restore `public` on `PDFImporter`, `PDFImportOptions`,
     `PDFImportDiagnostic`.
   - Re-add `SheetMusicPDF` to the `SheetMusic` umbrella target's
     dependency list in `Package.swift`.
   - Restore `@_exported import SheetMusicPDF` in
     `Sources/SheetMusic/SheetMusic.swift` and the two
     `loadScore(pdfURL:)` / `loadScore(pdfData:)` overloads at the
     bottom of the `SheetMusic` enum.
   - Restore the two umbrella tests at the bottom of
     `SheetMusicFacadeTests.swift` (use the snippet in commit
     `971efd7`'s diff).
   - Restore `.pdf` in `ScoreFileType` (`case pdf`, `allUTTypes`,
     `detect(url:)`); restore the `.pdf` switch branch in
     `ScoreLoader.swift`; restore the `<dict>` block in
     `Example/Info.plist` (snippet in commit `114c53a`'s diff).
   - `cd Example && xcodegen` to regenerate the project.
5. **Tighten the round-trip comparator** in
   `PDFRoundTripComparison.swift` — it's currently the loose v1
   (parts/staves/measures ≥ 1). Once CIDs decode correctly, the
   stricter pitch / duration / lyric checks become tractable.

## Known shortcomings (in the importer code itself, separate from CMap)

These are real bugs even after CIDs decode, surfaced during
exploratory runs on `~/Desktop/test.pdf`:

- **Multi-staff collapse**: a 6-staff piano score collapses to 1
  `StaffContent`. Suspected cause: `firstSystem.parts` is used as
  the global part shape, but for some inputs the first system isn't
  representative. Investigate `PDFImporter+Assemble.swift::partShape`
  and `appendSystem`'s `zip(slots, importPart.staves)` — the silent
  truncation when later systems carry more staves than the first
  needs to become either an error or a re-shape.
- **Spurious measure inflation**: 956 measures from a 10-page MS3
  fixture and 861 from a 26-page MS4 fixture are an order of
  magnitude too high. Likely cause: `Layout` is treating every
  vertical path that crosses a staff y-band as a barline, including
  stems / clef arms / decorative lines. Tighten
  `barlineCandidates` in `PDFImporter+StaffLines.swift` —
  candidates should be stand-alone vertical paths whose y-extent
  *spans* the staff height (not just *intersects* it).
- **Beam-based rhythm decoding** is not implemented (Task 8 stub);
  flag-based path only. Quarter-with-a-beam = quarter, not eighth.
- **Tempo VoiceElement** isn't inserted in `assembleScore` (MVP
  shortcut). Tempo events from `scoreStateEvents` are dropped.
- **Marker / Jump / Volta / RehearsalMark application** to the
  output `Score` is not wired in `assembleScore` (the producers
  exist but the consumer is empty).
- **BarLine subtype application** — trailing barlines never carry
  their detected subtype into the output `Measure`.
- **Cross-octave accidental non-propagation** test deferred (Task 7
  TODO).

## Why it's safe to leave the code in the tree during the breaking refactor

Every `Sources/SheetMusicPDF/Import/*.swift` is now `internal`.
No external package depends on the importer. The umbrella does not
re-export it. The example app does not reference it. The library
product `SheetMusicPDF` exists for `PDFExporter` — pre-existing,
unrelated to this work.

If `SheetMusicCore` types change, the importer will surface compile
errors that need fixing in lockstep, just like any other internal
consumer of those types. The 14 PDF importer test suites act as a
canary while you work — but they won't blockingly fail downstream
consumers of `SheetMusicCore`/`SheetMusicMSCX`/`SheetMusicMIDI`.

If you want to skip the importer entirely during the refactor, the
nuclear option is `swift test --skip PDFImporter` — but the cheaper
path is to keep it honest as you go.

## Files touched at "pause time"

- `Sources/SheetMusic/SheetMusic.swift` — removed `@_exported import
  SheetMusicPDF` + 2 overloads; added a breadcrumb comment.
- `Sources/SheetMusicPDF/Import/PDFImporter.swift` — `public enum →
  enum`, `public static → static` ×2; doc comment updated.
- `Sources/SheetMusicPDF/Import/PDFImportOptions.swift` — `public
  struct/enum/let/var/init → internal` (default).
- `Package.swift` — removed `"SheetMusicPDF"` from `SheetMusic`
  target's deps; added a breadcrumb comment.
- `Tests/SheetMusicTests/SheetMusicFacadeTests.swift` — dropped 2
  umbrella PDF tests.
- `Example/SheetMusicExample/ScoreFileType.swift` — dropped `.pdf`.
- `Example/SheetMusicExample/Shared/ScoreLoader.swift` — dropped
  `.pdf` branch.
- `Example/Info.plist` — dropped PDF `CFBundleDocumentTypes` entry.

`docs/superpowers/plans/2026-05-03-pdf-import.md` (the original
spec / plan) is unchanged — keep it as the canonical reference for
when work resumes.
