# PDF Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a PDF → `Score` import path to `SheetMusicPDF` that handles vector PDFs from MuseScore 3.x / 4.x by structurally extracting SMuFL glyphs and path geometry — no OCR.

**Architecture:** A 12-stage pipeline behind `PDFImporter.parse(...)` (caseless enum façade, mirrors `MidiImporter`). Each pipeline stage lives in one `PDFImporter+<Stage>.swift` extension under `Sources/SheetMusicPDF/Import/`, all under the 300-line cap. The flow is: `CGPDFContentStream` walk → SMuFL classify → staff-line distillation → page/system/part/staff/measure layout → score-state extraction (clef/key/time/tempo) → pitch decode → rhythm decode → voicing → lyrics → structural marks → text/title → `Score` assembly. Diagnostics are surfaced through an optional callback on `PDFImportOptions`.

**Tech Stack:** Swift 6.2, Swift Testing (`@Test`, `#expect`), `PDFKit` + `CoreGraphics` (already platform-bundled), no new package dependencies. Tests live in `Tests/SheetMusicTests/`.

**Pre-flight:**
- Verify spec is at `docs/superpowers/specs/2026-05-03-pdf-import-design.md` and approved.
- Work on a feature branch (e.g. `feat/pdf-import`); the example app's `.xcodeproj` is gitignored — regenerate via `cd Example && xcodegen` after editing `project.yml` or example sources.
- Build/test loop:
  - `swift build` (whole package)
  - `swift test --filter PDFImporter` (this work's tests)
  - `swift test` before each commit on a phase boundary (full suite must stay green; existing 12-suite/48-test count must hold or grow only).
  - `swiftlint --quiet Sources Tests` before each commit (zero warnings target).

---

## File Structure

**New (production):**

```
Sources/SheetMusicPDF/Import/
  Internal.swift                       shared internal types (Glyph, ClassifiedGlyph, Staff, …)
  PDFImportOptions.swift               public PDFImportOptions + PDFImportDiagnostic
  PDFImporter.swift                    public caseless-enum façade — sync parse(pdfURL/pdfData)
  PDFImporter+ContentStream.swift      CGPDFContentStream walker → [RawGlyph], [PathSegment]
  PDFImporter+SMuFL.swift              codepoint+font → SMuFLSemantic table
  PDFImporter+StaffLines.swift         path segments → [Staff]
  PDFImporter+Layout.swift             page → system → part → staff → measure tree
  PDFImporter+Pitch.swift              clef/key/accidental state machine
  PDFImporter+Rhythm.swift             flag/beam/dot/notehead → NoteDuration; chord assembly
  PDFImporter+Voicing.swift            time-coverage overlap multi-voice detection + assignment
  PDFImporter+Lyrics.swift             lyric y-band clustering + syllable-to-notehead matching
  PDFImporter+Structure.swift          repeat barlines, voltas, rehearsal marks, jumps/markers
  PDFImporter+Text.swift               title/subtitle/composer extraction + metadata fallback
```

**New (tests):**

```
Tests/SheetMusicTests/
  PDFImporterContentStreamTests.swift
  PDFImporterSMuFLTests.swift
  PDFImporterStaffLinesTests.swift
  PDFImporterLayoutTests.swift
  PDFImporterScoreStateTests.swift
  PDFImporterPitchTests.swift
  PDFImporterRhythmTests.swift
  PDFImporterVoicingTests.swift
  PDFImporterLyricsTests.swift
  PDFImporterStructureTests.swift
  PDFImporterTextTests.swift
  PDFImporterFaçadeTests.swift
  PDFImporterDiagnosticsTests.swift
  PDFImporterRoundTripTests.swift      self-roundtrip golden, @MainActor (PDFExporter is)

Tests/SheetMusicTests/Resources/pdf/
  LICENSE                              provenance notice (no third-party fixtures in v1)
```

**Modified:**

```
Package.swift                          add SheetMusicPDF as a SheetMusic umbrella dep
Sources/SheetMusic/SheetMusic.swift    @_exported import SheetMusicPDF + 2 loadScore overloads
Example/SheetMusicExample/ScoreFileType.swift     add .pdf
Example/SheetMusicExample/ContentView.swift       add PDF UTType to picker
Example/SheetMusicExample/Shared/ScoreLoader.swift   add .pdf branch → loadScore(pdfURL:)
Example/Info.plist                     add com.adobe.pdf to CFBundleDocumentTypes
```

The umbrella currently only depends on `SheetMusicCore`/`MSCX`/`MusicXML`/`MIDI`. Adding `SheetMusicPDF` pulls in `SheetMusicLayout` and `SheetMusicUI` transitively — that is the same dependency graph the example app already has, so nothing new ships beyond what the example already consumes.

---

## Internal Types Map (defined in `Internal.swift`, used across extensions)

```swift
import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

/// Raw glyph captured from one Tj / TJ operator. Position is the
/// text origin in PDF page coordinates (origin = bottom-left).
struct RawGlyph: Equatable {
    var codepoint: UInt32       // Unicode scalar (often a SMuFL PUA codepoint)
    var fontName: String        // PostScript name as reported by PDFKit
    var fontSize: CGFloat       // points
    var origin: CGPoint
    var advance: CGFloat        // horizontal advance to the next glyph in points
    var pageIndex: Int
}

/// One straight or rectangular path segment captured from m/l/re
/// content-stream operators. Used by staff-line and barline detection.
struct PathSegment: Equatable {
    enum Kind { case horizontal, vertical, rectangle }
    var kind: Kind
    var rect: CGRect            // collapsed bounding box; horizontal/vertical degenerate rects are 1-D
    var lineWidth: CGFloat
    var pageIndex: Int
}

/// Semantic interpretation of a RawGlyph (PDFImporter+SMuFL).
enum SMuFLSemantic: Equatable {
    case noteheadBlack, noteheadHalf, noteheadWhole, noteheadDoubleWhole
    case stem, flag8thUp, flag8thDown, flag16thUp, flag16thDown,
         flag32ndUp, flag32ndDown, flag64thUp, flag64thDown
    case augmentationDot
    case rest(NoteDuration)
    case clefG, clefF, clefC, clefPercussion
    case accidentalSharp, accidentalFlat, accidentalNatural,
         accidentalDoubleSharp, accidentalDoubleFlat
    case timeSignatureDigit(Int)        // 0-9
    case timeSignatureCommon, timeSignatureCutTime
    case staff5Lines                    // U+E003 (when MuseScore renders the staff as one glyph)
    case repeatBarlineDots
    case segno, coda, dalSegno, daCapo, fine, toCoda
    case fermata                        // out of scope but classified so it can be ignored cleanly
    case dynamic, articulation, ornament  // out of scope buckets
    case unknown(UInt32)                // emits info-diagnostic
}

/// A glyph with its semantic. Stage [3] output.
struct ClassifiedGlyph {
    var raw: RawGlyph
    var semantic: SMuFLSemantic
}

/// A non-music-glyph text run (lyrics, tempo text, title, …).
/// Captured as ordinary Unicode by the content-stream walker.
struct TextGlyph {
    var text: String
    var fontName: String
    var fontSize: CGFloat
    var origin: CGPoint
    var bbox: CGRect
    var pageIndex: Int
}

/// Output of stage [4]. One staff (5-line band) on a page.
struct Staff {
    var pageIndex: Int
    var yLines: [CGFloat]               // five y-coordinates (top → bottom or bottom → top, fixed by detector)
    var xRange: ClosedRange<CGFloat>
    /// Vertical path segments inside `xRange` whose y-extent covers
    /// the full staff height. These become barline candidates.
    var barlineCandidates: [PathSegment]
}

/// Output of stage [5]. The page → system → part → staff → measure tree.
struct ImportSystem {
    var pageIndex: Int
    var yRange: ClosedRange<CGFloat>
    var parts: [ImportPart]
}

struct ImportPart {
    var staves: [ImportStaff]
}

struct ImportStaff {
    var staff: Staff
    var measures: [ImportMeasure]
}

struct ImportMeasure {
    /// Page-coordinate x range of this measure cell, used for x→time
    /// conversion in the voicing pass.
    var xRange: ClosedRange<CGFloat>
    var glyphs: [ClassifiedGlyph]       // glyphs whose origin falls in xRange
    var leadingBarline: PathSegment?    // path on the left edge
    var trailingBarline: PathSegment?   // path on the right edge
}

/// Stage [5b] output — score-state events, in x-order, per staff.
enum ScoreStateEvent {
    case clefChange(Clef, atMeasureIndex: Int)
    case timeSignature(TimeSignature, atMeasureIndex: Int)
    case keySignature(KeySignature, atMeasureIndex: Int)
    case tempo(Tempo, atMeasureIndex: Int)
}
```

The exact spelling of `Clef`, `KeySignature`, `TimeSignature`, `Tempo` mirrors what already exists in `Sources/SheetMusicCore/Score/`. If a constructor mismatch surfaces (e.g. `KeySignature.init(fifths:)` vs `KeySignature.init(accidentals:)`), use whatever constructor `MidiImporter` or `MSCXDecoder` is using today — do not invent a new init.

---

## Task 1: Project skeleton, options, internal types

**Goal:** Compile a do-nothing `PDFImporter` so subsequent tasks can extend it. No semantic behaviour yet — the façade throws `SheetMusicError.malformedScore` until later tasks wire stages in.

**Files:**
- Create: `Sources/SheetMusicPDF/Import/Internal.swift`
- Create: `Sources/SheetMusicPDF/Import/PDFImportOptions.swift`
- Create: `Sources/SheetMusicPDF/Import/PDFImporter.swift`
- Create: `Tests/SheetMusicTests/PDFImporterFaçadeTests.swift` (just the smoke tests for now)

- [ ] **Step 1: Write the failing façade smoke tests**

`Tests/SheetMusicTests/PDFImporterFaçadeTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicPDF
import Testing

@Suite struct PDFImporterFaçadeTests {
    @Test func emptyDataThrows() {
        #expect(throws: SheetMusicError.self) {
            _ = try PDFImporter.parse(pdfData: Data())
        }
    }

    @Test func nonPDFDataThrows() {
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        #expect(throws: SheetMusicError.self) {
            _ = try PDFImporter.parse(pdfData: junk)
        }
    }

    @Test func optionsHaveSensibleDefaults() {
        let opts = PDFImportOptions()
        #expect(opts.preserveBreaks == true)
        #expect(opts.useMetadataAsFallback == true)
        #expect(opts.diagnostics == nil)
    }
}
```

- [ ] **Step 2: Run the test — confirm it fails to compile (no `PDFImporter`, no `PDFImportOptions`)**

Run: `swift test --filter PDFImporterFaçadeTests`
Expected: build error — `PDFImporter` and `PDFImportOptions` undeclared.

- [ ] **Step 3: Add `PDFImportOptions.swift`**

```swift
import Foundation

/// Non-fatal recognition issues surfaced from `PDFImporter`.
public struct PDFImportDiagnostic: Sendable {
    public enum Severity: Sendable { case info, warning }
    public let severity: Severity
    public let location: String   // e.g. "page 3, system 2, measure 17"
    public let message: String
    public let context: String?

    public init(
        severity: Severity, location: String,
        message: String, context: String? = nil
    ) {
        self.severity = severity
        self.location = location
        self.message = message
        self.context = context
    }
}

public struct PDFImportOptions: Sendable {
    public var preserveBreaks: Bool = true
    public var useMetadataAsFallback: Bool = true
    public var diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?

    public init() {}
}
```

- [ ] **Step 4: Add `Internal.swift` with the type map above**

Copy the full **Internal Types Map** from the top of this plan into `Sources/SheetMusicPDF/Import/Internal.swift`. All types are `internal` (default), used cross-extension within `SheetMusicPDF`.

- [ ] **Step 5: Add `PDFImporter.swift` — caseless enum stub**

```swift
import Foundation
import PDFKit
import SheetMusicCore

/// Public façade for parsing vector PDFs (MuseScore 3.x/4.x exports)
/// into `Score`. Mirrors the `MidiImporter` shape — a caseless enum,
/// sync only.
public enum PDFImporter {
    public static func parse(
        pdfURL: URL,
        options: PDFImportOptions = .init()
    ) throws -> Score {
        let data = try Data(contentsOf: pdfURL)
        return try parse(pdfData: data, options: options)
    }

    public static func parse(
        pdfData: Data,
        options: PDFImportOptions = .init()
    ) throws -> Score {
        guard !pdfData.isEmpty else {
            throw SheetMusicError.malformedScore("PDFImporter: empty data")
        }
        guard let document = PDFDocument(data: pdfData) else {
            throw SheetMusicError.malformedScore("PDFImporter: not a valid PDF")
        }
        guard document.pageCount > 0 else {
            throw SheetMusicError.malformedScore("PDFImporter: zero pages")
        }
        // Pipeline wired in later tasks. Until Task 13 lands, throw so
        // the caller is not handed an empty Score silently.
        throw SheetMusicError.malformedScore(
            "PDFImporter: pipeline not yet wired (\(document.pageCount) pages)"
        )
    }
}
```

(Use whatever `SheetMusicError` case the project uses for parse failures — match `MSCXParser` / `MidiImporter`. If the canonical case is `.parseFailed(String)` not `.malformedScore`, substitute it.)

- [ ] **Step 6: Run the tests — they should now pass**

Run: `swift test --filter PDFImporterFaçadeTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Run lint + full build**

Run: `swiftlint --quiet Sources Tests` and `swift build`
Expected: zero lint warnings; clean build.

- [ ] **Step 8: Commit**

```bash
git add Sources/SheetMusicPDF/Import Tests/SheetMusicTests/PDFImporterFaçadeTests.swift
git commit -m "feat(pdf): scaffold PDFImporter façade and import options"
```

---

## Task 2: SMuFL codepoint table

**Goal:** Map every SMuFL codepoint observed in MuseScore 3.x/4.x exports to a `SMuFLSemantic`. Unknown codepoints produce `.unknown(UInt32)` so stage [3] can decide whether to emit a diagnostic.

The codepoint set comes from the SMuFL spec ranges:
- Notehead block: U+E0A0–U+E0FF (most-used: `noteheadBlack` U+E0A4, `noteheadHalf` U+E0A3, `noteheadWhole` U+E0A2, `noteheadDoubleWhole` U+E0A1).
- Clefs: gClef U+E050, fClef U+E062, cClef U+E05C, percussion clef U+E069.
- Time-signature digits: U+E080–U+E089. Common time U+E08A. Cut time U+E08B.
- Accidentals: sharp U+E262, flat U+E260, natural U+E261, double-sharp U+E263, double-flat U+E264.
- Flags: 8thUp U+E240, 8thDown U+E241, 16thUp U+E242, 16thDown U+E243, 32ndUp U+E244, 32ndDown U+E245, 64thUp U+E246, 64thDown U+E247.
- Rests: maxima U+E4E0, longa U+E4E1, breve U+E4E2, whole U+E4E3, half U+E4E4, quarter U+E4E5, 8th U+E4E6, 16th U+E4E7, 32nd U+E4E8, 64th U+E4E9.
- Augmentation dot: U+E1E7.
- Repeat dots (barline): U+E043.
- Staff lines (whole-staff glyph): U+E003.
- Segno U+E047, Coda U+E048, fermata U+E4C0.

**Files:**
- Create: `Sources/SheetMusicPDF/Import/PDFImporter+SMuFL.swift`
- Create: `Tests/SheetMusicTests/PDFImporterSMuFLTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicPDF
import Testing

@Suite struct PDFImporterSMuFLTests {
    @Test func classifiesNoteheads() {
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A4) == .noteheadBlack)
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A3) == .noteheadHalf)
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A2) == .noteheadWhole)
    }

    @Test func classifiesClefs() {
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE050) == .clefG)
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE062) == .clefF)
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE05C) == .clefC)
    }

    @Test func classifiesTimeSignatureDigits() {
        for digit in 0...9 {
            let cp = UInt32(0xE080 + digit)
            #expect(PDFImporter.smuflSemantic(codepoint: cp) == .timeSignatureDigit(digit))
        }
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE08A) == .timeSignatureCommon)
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE08B) == .timeSignatureCutTime)
    }

    @Test func classifiesAccidentals() {
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE262) == .accidentalSharp)
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE260) == .accidentalFlat)
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE261) == .accidentalNatural)
    }

    @Test func classifiesFlags() {
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE240) == .flag8thUp)
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE241) == .flag8thDown)
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE242) == .flag16thUp)
    }

    @Test func classifiesRestsByDuration() {
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E3) == .rest(.whole))
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E4) == .rest(.half))
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E5) == .rest(.quarter))
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E6) == .rest(.eighth))
        #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E7) == .rest(.sixteenth))
    }

    @Test func unknownCodepointReportsAsUnknown() {
        // U+E999 is not a SMuFL-assigned glyph
        if case let .unknown(cp) = PDFImporter.smuflSemantic(codepoint: 0xE999) {
            #expect(cp == 0xE999)
        } else {
            Issue.record("expected .unknown")
        }
    }

    @Test func nonPUACodepointReportsAsUnknown() {
        // ASCII 'A' is not a SMuFL glyph
        if case .unknown = PDFImporter.smuflSemantic(codepoint: 0x41) {
            // OK
        } else {
            Issue.record("expected .unknown for ASCII")
        }
    }
}
```

- [ ] **Step 2: Run — confirm failure**

Run: `swift test --filter PDFImporterSMuFLTests`
Expected: FAIL — `smuflSemantic` not defined.

- [ ] **Step 3: Implement the table**

`Sources/SheetMusicPDF/Import/PDFImporter+SMuFL.swift`:

```swift
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Map a SMuFL codepoint to its semantic. Unrecognised codepoints
    /// → `.unknown(codepoint)` so callers can emit a diagnostic.
    /// Visibility: package-internal but exposed for unit tests via
    /// `@testable import` (test target uses `@testable`).
    static func smuflSemantic(codepoint cp: UInt32) -> SMuFLSemantic {
        switch cp {
        // Staff
        case 0xE003: return .staff5Lines

        // Repeat dots
        case 0xE043: return .repeatBarlineDots

        // Segno / Coda
        case 0xE047: return .segno
        case 0xE048: return .coda

        // Clefs
        case 0xE050: return .clefG
        case 0xE05C: return .clefC
        case 0xE062: return .clefF
        case 0xE069: return .clefPercussion

        // Time-signature digits + common/cut
        case 0xE080...0xE089: return .timeSignatureDigit(Int(cp - 0xE080))
        case 0xE08A: return .timeSignatureCommon
        case 0xE08B: return .timeSignatureCutTime

        // Noteheads
        case 0xE0A1: return .noteheadDoubleWhole
        case 0xE0A2: return .noteheadWhole
        case 0xE0A3: return .noteheadHalf
        case 0xE0A4: return .noteheadBlack

        // Augmentation dot
        case 0xE1E7: return .augmentationDot

        // Flags
        case 0xE240: return .flag8thUp
        case 0xE241: return .flag8thDown
        case 0xE242: return .flag16thUp
        case 0xE243: return .flag16thDown
        case 0xE244: return .flag32ndUp
        case 0xE245: return .flag32ndDown
        case 0xE246: return .flag64thUp
        case 0xE247: return .flag64thDown

        // Accidentals
        case 0xE260: return .accidentalFlat
        case 0xE261: return .accidentalNatural
        case 0xE262: return .accidentalSharp
        case 0xE263: return .accidentalDoubleSharp
        case 0xE264: return .accidentalDoubleFlat

        // Rests
        case 0xE4E0: return .rest(.maxima)
        case 0xE4E1: return .rest(.longa)
        case 0xE4E2: return .rest(.breve)
        case 0xE4E3: return .rest(.whole)
        case 0xE4E4: return .rest(.half)
        case 0xE4E5: return .rest(.quarter)
        case 0xE4E6: return .rest(.eighth)
        case 0xE4E7: return .rest(.sixteenth)
        case 0xE4E8: return .rest(.n32nd)
        case 0xE4E9: return .rest(.n64th)

        // Fermata
        case 0xE4C0: return .fermata

        default:
            return .unknown(cp)
        }
    }
}
```

If `NoteDuration` does not have a `.maxima` / `.longa` / `.breve` / `.n32nd` / `.n64th` case, drop those rest entries (they fall through to `.unknown` and are out-of-scope for v1 anyway). Verify with `grep -n "case " Sources/SheetMusicCore/Score/NoteDuration.swift` before keeping/dropping each.

- [ ] **Step 4: Run tests, then full suite**

Run: `swift test --filter PDFImporterSMuFLTests` → PASS
Run: `swift test` → no regressions

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+SMuFL.swift Tests/SheetMusicTests/PDFImporterSMuFLTests.swift
git commit -m "feat(pdf): SMuFL codepoint → semantic table"
```

---

## Task 3: Content-stream walker

**Goal:** Given a `PDFDocument`, extract `[RawGlyph]`, `[TextGlyph]`, and `[PathSegment]` per page. This is the lowest-level read — every later stage consumes its output.

Use `CGPDFContentStream` + `CGPDFOperatorTable` to register callbacks for `Tj`, `TJ`, `Tf` (font), `Tm`/`Td`/`TD`/`T*` (text matrix), `cm` (CTM), `m`, `l`, `re`, `h`, `S`, `f`. Maintain a small interpreter that tracks CTM stack (`q`/`Q`), text matrix, current font (PostScript name + size), and current path. PDFKit gives us the page's `CGPDFPage`; pass it to `CGPDFContentStreamCreateWithPage`.

Notes:
- For text strings whose font is a custom CID-encoded SMuFL font, the bytes in the Tj operand are CID codes, **not** Unicode. We need the PDF's ToUnicode CMap to resolve them. PDFKit exposes `PDFSelection.string` for ASCII text but not raw CID. Plan: use `CGPDFFontGetGlyphAdvances` + the page's font dictionary to extract the ToUnicode CMap from the font dictionary's `/ToUnicode` stream and decode CIDs. Alternatively, since MuseScore 3.6.2/4.x both write a Identity-H or Custom encoding with a ToUnicode CMap that maps CID → SMuFL PUA codepoint, treat the CMap as the source of truth.
- Hide all PDFKit/CoreGraphics ugliness behind one struct `ContentStreamWalker` with a single public method `walk() throws -> Output`. Output is `(glyphs: [RawGlyph], texts: [TextGlyph], paths: [PathSegment])`.

**Files:**
- Create: `Sources/SheetMusicPDF/Import/PDFImporter+ContentStream.swift`
- Create: `Tests/SheetMusicTests/PDFImporterContentStreamTests.swift`
- Create: `Tests/SheetMusicTests/Helpers/PDFFixtureBuilder.swift` (synthetic PDF generator)

- [ ] **Step 1: Write the synthetic-PDF fixture builder helper**

`Tests/SheetMusicTests/Helpers/PDFFixtureBuilder.swift`:

```swift
import CoreGraphics
import CoreText
import Foundation

/// Builds a single-page PDF in memory. Used to stand in for
/// real MuseScore PDFs in unit tests of the content-stream walker
/// and downstream stages.
@MainActor
enum PDFFixtureBuilder {
    struct GlyphPlacement {
        var unicodeScalar: UnicodeScalar    // SMuFL PUA codepoint or ASCII
        var fontName: String                // "Bravura", "Leland", "Helvetica", …
        var fontSize: CGFloat
        var origin: CGPoint
    }

    struct PathPlacement {
        enum Kind { case horizontal(width: CGFloat), vertical(height: CGFloat), rect(size: CGSize) }
        var origin: CGPoint
        var kind: Kind
        var lineWidth: CGFloat = 0.5
    }

    /// Draw glyphs and path segments on a fresh A4 page.
    /// Returns PDF data.
    static func build(
        size: CGSize = CGSize(width: 595, height: 842),
        glyphs: [GlyphPlacement] = [],
        paths: [PathPlacement] = []
    ) -> Data {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: pdfData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            return Data()
        }
        ctx.beginPDFPage(nil)

        for path in paths {
            ctx.setLineWidth(path.lineWidth)
            ctx.beginPath()
            switch path.kind {
            case let .horizontal(w):
                ctx.move(to: path.origin)
                ctx.addLine(to: CGPoint(x: path.origin.x + w, y: path.origin.y))
                ctx.strokePath()
            case let .vertical(h):
                ctx.move(to: path.origin)
                ctx.addLine(to: CGPoint(x: path.origin.x, y: path.origin.y + h))
                ctx.strokePath()
            case let .rect(s):
                ctx.stroke(CGRect(origin: path.origin, size: s))
            }
        }

        for g in glyphs {
            let font = CTFontCreateWithName(g.fontName as CFString, g.fontSize, nil)
            let attr: [NSAttributedString.Key: Any] = [.font: font]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(g.unicodeScalar), attributes: attr)
            )
            ctx.textPosition = g.origin
            CTLineDraw(line, ctx)
        }

        ctx.endPDFPage()
        ctx.closePDF()
        return pdfData as Data
    }
}
```

(SMuFL fonts may not be installed on the test host; tests must use whatever the OS does install — fall back to "Helvetica" + ASCII for tests that only verify the *walker*, not classification. Tests that need actual SMuFL glyphs to round-trip can use `PDFExporter` instead — see Task 15.)

- [ ] **Step 2: Write failing content-stream tests**

`Tests/SheetMusicTests/PDFImporterContentStreamTests.swift`:

```swift
import CoreGraphics
import Foundation
import PDFKit
@testable import SheetMusicPDF
import Testing

@Suite @MainActor struct PDFImporterContentStreamTests {
    @Test func extractsAsciiTextOrigin() throws {
        let data = PDFFixtureBuilder.build(
            glyphs: [.init(
                unicodeScalar: "A",
                fontName: "Helvetica",
                fontSize: 12,
                origin: CGPoint(x: 100, y: 700)
            )]
        )
        let doc = try #require(PDFDocument(data: data))
        let walker = PDFImporter.ContentStreamWalker(document: doc)
        let out = try walker.walk()
        // Either captured as RawGlyph (SMuFL-style) or TextGlyph (Unicode).
        // Helvetica + ASCII should land in `texts`.
        #expect(out.texts.contains { $0.text.contains("A") })
        // Walker must record page index 0.
        #expect(out.texts.allSatisfy { $0.pageIndex == 0 })
    }

    @Test func extractsHorizontalPathSegment() throws {
        let data = PDFFixtureBuilder.build(
            paths: [.init(
                origin: CGPoint(x: 50, y: 500),
                kind: .horizontal(width: 400)
            )]
        )
        let doc = try #require(PDFDocument(data: data))
        let walker = PDFImporter.ContentStreamWalker(document: doc)
        let out = try walker.walk()
        let horiz = out.paths.filter { $0.kind == .horizontal }
        #expect(horiz.count >= 1)
        let rect = try #require(horiz.first?.rect)
        #expect(abs(rect.minX - 50) < 1.5)
        #expect(abs(rect.width - 400) < 1.5)
    }

    @Test func extractsVerticalPathSegment() throws {
        let data = PDFFixtureBuilder.build(
            paths: [.init(
                origin: CGPoint(x: 200, y: 400),
                kind: .vertical(height: 80)
            )]
        )
        let doc = try #require(PDFDocument(data: data))
        let walker = PDFImporter.ContentStreamWalker(document: doc)
        let out = try walker.walk()
        let vert = out.paths.filter { $0.kind == .vertical }
        #expect(vert.count >= 1)
    }

    @Test func multiplePagesEnumerated() throws {
        // Build a 2-page document by concatenating two PDFs via PDFDocument
        let p0 = PDFFixtureBuilder.build(
            paths: [.init(origin: CGPoint(x: 0, y: 100), kind: .horizontal(width: 100))]
        )
        let p1 = PDFFixtureBuilder.build(
            paths: [.init(origin: CGPoint(x: 0, y: 200), kind: .horizontal(width: 100))]
        )
        let doc = try #require(PDFDocument(data: p0))
        let aux = try #require(PDFDocument(data: p1))
        if let page = aux.page(at: 0) { doc.insert(page, at: doc.pageCount) }
        let walker = PDFImporter.ContentStreamWalker(document: doc)
        let out = try walker.walk()
        let pages = Set(out.paths.map(\.pageIndex))
        #expect(pages == [0, 1])
    }
}
```

- [ ] **Step 3: Run — confirm failure**

`swift test --filter PDFImporterContentStreamTests` → FAIL (`ContentStreamWalker` undefined).

- [ ] **Step 4: Implement `ContentStreamWalker`**

`Sources/SheetMusicPDF/Import/PDFImporter+ContentStream.swift`:

```swift
import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

extension PDFImporter {
    struct ContentStreamWalker {
        let document: PDFDocument

        struct Output {
            var glyphs: [RawGlyph]
            var texts: [TextGlyph]
            var paths: [PathSegment]
        }

        func walk() throws -> Output {
            var glyphs: [RawGlyph] = []
            var texts: [TextGlyph] = []
            var paths: [PathSegment] = []

            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex),
                      let cgPage = page.pageRef
                else { continue }
                var pageState = PageState(pageIndex: pageIndex)
                walk(page: cgPage, state: &pageState)
                glyphs.append(contentsOf: pageState.glyphs)
                texts.append(contentsOf: pageState.texts)
                paths.append(contentsOf: pageState.paths)
            }

            return Output(glyphs: glyphs, texts: texts, paths: paths)
        }

        // MARK: - Page interpreter

        private final class PageState {
            let pageIndex: Int
            var ctmStack: [CGAffineTransform] = [.identity]
            var textMatrix: CGAffineTransform = .identity
            var lineMatrix: CGAffineTransform = .identity
            var fontName: String = ""
            var fontSize: CGFloat = 0
            var currentPath: [CGPoint] = []
            var glyphs: [RawGlyph] = []
            var texts: [TextGlyph] = []
            var paths: [PathSegment] = []
            var toUnicodeCMap: ToUnicodeCMap = .identity
            init(pageIndex: Int) { self.pageIndex = pageIndex }
        }

        private func walk(page: CGPDFPage, state: inout PageState) {
            // Build operator table; register handlers that pop operands
            // from the stack and update `state`. See Apple's
            // CGPDFContentStreamCreateWithPage docs for the operand model.
            //
            // Required operators:
            //   q / Q      : push/pop ctm stack
            //   cm         : concat to ctm
            //   Tf         : set font + size (resolve font name from page resources)
            //   Tm Td TD T*: update text matrix
            //   Tj / TJ    : show string — emit RawGlyph or TextGlyph
            //   m / l / re : path construction
            //   h / S / f / B : path painting (only S / B / f mark a segment as drawn)
            //
            // The implementation registers a CGPDFOperatorCallback for
            // each operator that takes `(scanner, info)` where `info` is
            // an `Unmanaged<PageState>`. Pop operands via
            // CGPDFScannerPopName / PopNumber / PopString / PopArray, mutate
            // state, and (for Tj / TJ / S / B / f) append to the output
            // collections.
            //
            // Glyph emission rule:
            //   - decode each byte / 2-byte CID through state.toUnicodeCMap
            //   - if the resulting codepoint is in the SMuFL PUA range
            //     (U+E000..U+F8FF), append RawGlyph
            //   - otherwise concatenate into a TextGlyph buffer that is
            //     flushed when the text matrix translates discontinuously
            //
            // Path emission rule:
            //   - track "did stroke / fill happen" via S/F/B operators
            //   - on stroke, classify the path into PathSegment.Kind:
            //       all moves+lines along same y → horizontal
            //       all moves+lines along same x → vertical
            //       single `re` op → rectangle
            //     drop everything else (curves are rare in MuseScore output
            //     and can be revisited if structural detection regresses)
            _ = page
            _ = state
            // TODO(impl) — see comment above. Concrete implementation is
            // straightforward C-bridging; estimate ~250 lines.
        }
    }

    /// CID → Unicode lookup. For the v1 walker we accept Identity (CID
    /// passes through as Unicode codepoint) until ToUnicodeCMap parsing
    /// is added. SMuFL fonts in MuseScore exports ship a 2-byte CID
    /// where the CID equals the SMuFL codepoint, so identity covers
    /// the SMuFL path.
    struct ToUnicodeCMap {
        static let identity = ToUnicodeCMap()
        func map(cid: UInt32) -> UInt32 { cid }
    }
}
```

Implementation note for the executor: the test suite *only* exercises ASCII text + path segments via `PDFFixtureBuilder`. Wire `Tj` and the `m`/`l`/`re`/`S` operators end-to-end first; that satisfies the tests. CID/SMuFL decoding is exercised end-to-end in Task 15's roundtrip; if the round-trip fails because a SMuFL CID does not decode to its PUA codepoint, extend `ToUnicodeCMap` then.

- [ ] **Step 5: Run tests until green**

`swift test --filter PDFImporterContentStreamTests` → PASS (4 tests).

- [ ] **Step 6: Run lint + full suite**

`swiftlint --quiet Sources Tests` and `swift test` → green.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+ContentStream.swift \
        Tests/SheetMusicTests/Helpers/PDFFixtureBuilder.swift \
        Tests/SheetMusicTests/PDFImporterContentStreamTests.swift
git commit -m "feat(pdf): content-stream walker (text + path segments)"
```

---

## Task 4: Staff-line detection

**Goal:** Distil `[PathSegment]` into `[Staff]` (one record per 5-line band).

Algorithm:

1. Take all horizontal segments with `lineWidth < 1pt` and length > 50pt (heuristic threshold; staves are wide, ledgers are short).
2. Group by `pageIndex`.
3. Within a page, cluster by y-coordinate using a tolerance equal to twice the median segment lineWidth (≈1.5pt). A cluster with exactly five y-values whose pairwise spacing is approximately uniform (CV < 0.1) is a 5-line staff.
4. Alternative path: detect any `staff5Lines` (U+E003) glyph from the classified-glyph stream and synthesise a `Staff` from its origin + advance directly — bypassing the path approach. Both paths must work; merge their outputs by deduplicating staves whose centres land within 5pt.
5. For each `Staff`, compute `xRange` = (min x of leftmost staff segment, max x of rightmost staff segment). Collect vertical path segments whose x falls within `xRange` and whose y-span covers the full staff height as `barlineCandidates`.

The `staff5Lines` path requires Task 3's glyph stream + Task 2's classifier. Task 4 takes both as input.

**Files:**
- Create: `Sources/SheetMusicPDF/Import/PDFImporter+StaffLines.swift`
- Create: `Tests/SheetMusicTests/PDFImporterStaffLinesTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import CoreGraphics
import Foundation
@testable import SheetMusicPDF
import Testing

@Suite @MainActor struct PDFImporterStaffLinesTests {
    private func horizontals(at ys: [CGFloat], xRange: ClosedRange<CGFloat>) -> [PathSegment] {
        ys.map {
            PathSegment(
                kind: .horizontal,
                rect: CGRect(x: xRange.lowerBound, y: $0,
                             width: xRange.upperBound - xRange.lowerBound, height: 0),
                lineWidth: 0.5,
                pageIndex: 0
            )
        }
    }

    @Test func detectsFiveEvenlySpacedLinesAsStaff() {
        let lines = horizontals(at: [100, 110, 120, 130, 140], xRange: 50...500)
        let staves = PDFImporter.detectStaves(paths: lines, classified: [], pageIndex: 0)
        #expect(staves.count == 1)
        let s = try! #require(staves.first)
        #expect(s.yLines.count == 5)
        #expect(s.xRange == 50...500)
    }

    @Test func ignoresFourLineBand() {
        let lines = horizontals(at: [100, 110, 120, 130], xRange: 50...500)
        let staves = PDFImporter.detectStaves(paths: lines, classified: [], pageIndex: 0)
        #expect(staves.isEmpty)
    }

    @Test func detectsStaff5LinesGlyphPath() {
        let glyph = ClassifiedGlyph(
            raw: RawGlyph(
                codepoint: 0xE003, fontName: "Bravura", fontSize: 24,
                origin: CGPoint(x: 50, y: 100), advance: 450, pageIndex: 0
            ),
            semantic: .staff5Lines
        )
        let staves = PDFImporter.detectStaves(paths: [], classified: [glyph], pageIndex: 0)
        #expect(staves.count == 1)
    }

    @Test func deduplicatesGlyphAndPathDetections() {
        // Same staff captured both as a U+E003 glyph and as five paths.
        let lines = horizontals(at: [100, 110, 120, 130, 140], xRange: 50...500)
        let glyph = ClassifiedGlyph(
            raw: RawGlyph(
                codepoint: 0xE003, fontName: "Bravura", fontSize: 24,
                origin: CGPoint(x: 50, y: 100), advance: 450, pageIndex: 0
            ),
            semantic: .staff5Lines
        )
        let staves = PDFImporter.detectStaves(paths: lines, classified: [glyph], pageIndex: 0)
        #expect(staves.count == 1, "must merge the two detections")
    }

    @Test func collectsBarlineCandidates() {
        let staffLines = horizontals(at: [100, 110, 120, 130, 140], xRange: 50...500)
        let barline = PathSegment(
            kind: .vertical,
            rect: CGRect(x: 200, y: 100, width: 0, height: 40),
            lineWidth: 0.5, pageIndex: 0
        )
        let staves = PDFImporter.detectStaves(
            paths: staffLines + [barline], classified: [], pageIndex: 0
        )
        #expect(staves.first?.barlineCandidates.count == 1)
    }
}
```

- [ ] **Step 2: Run — confirm failure**

`swift test --filter PDFImporterStaffLinesTests` → FAIL (`detectStaves` undefined).

- [ ] **Step 3: Implement `detectStaves`**

```swift
import CoreGraphics
import Foundation

extension PDFImporter {
    /// Distil straight horizontal path segments + `staff5Lines` glyphs
    /// into 5-line `Staff` records.
    static func detectStaves(
        paths: [PathSegment],
        classified: [ClassifiedGlyph],
        pageIndex: Int
    ) -> [Staff] {
        let horiz = paths.filter {
            $0.pageIndex == pageIndex
                && $0.kind == .horizontal
                && $0.rect.width > 50
        }
        var clusters: [[PathSegment]] = []
        for seg in horiz.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if var last = clusters.last, let lastSeg = last.last,
               abs(seg.rect.midY - lastSeg.rect.midY) < 1.5 * lastSeg.lineWidth + 1.0 {
                // same y-line, merge x-extent (multiple horizontal
                // path strokes that compose one logical line).
                last.append(seg)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([seg])
            }
        }

        var staves: [Staff] = []
        // Slide a 5-window over consecutive y-clusters and check spacing CV.
        let lineYs: [CGFloat] = clusters.map { $0.map(\.rect.midY).reduce(0, +) / CGFloat($0.count) }
        var i = 0
        while i + 4 < lineYs.count {
            let ys = Array(lineYs[i...(i + 4)])
            let gaps = zip(ys.dropFirst(), ys).map(-)
            let mean = gaps.reduce(0, +) / CGFloat(gaps.count)
            let variance = gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(gaps.count)
            let cv = mean > 0 ? sqrt(variance) / mean : .infinity
            if cv < 0.1 {
                let segs = (i...(i + 4)).flatMap { clusters[$0] }
                let xMin = segs.map(\.rect.minX).min() ?? 0
                let xMax = segs.map(\.rect.maxX).max() ?? 0
                let xRange = xMin...xMax
                staves.append(Staff(
                    pageIndex: pageIndex,
                    yLines: ys,
                    xRange: xRange,
                    barlineCandidates: barlineCandidates(
                        in: paths, xRange: xRange, yRange: ys.first!...ys.last!,
                        pageIndex: pageIndex
                    )
                ))
                i += 5
            } else {
                i += 1
            }
        }

        // Merge in `staff5Lines` glyph detections.
        for g in classified where g.raw.pageIndex == pageIndex {
            guard case .staff5Lines = g.semantic else { continue }
            let yMid = g.raw.origin.y
            // Skip if a path-detected staff already covers this y.
            if staves.contains(where: { abs($0.yLines.middle - yMid) < 5 }) { continue }
            let xMin = g.raw.origin.x
            let xMax = g.raw.origin.x + g.raw.advance
            let lineSpacing = g.raw.fontSize / 4   // SMuFL design metric
            let ys = (0..<5).map { yMid - lineSpacing * 2 + lineSpacing * CGFloat($0) }
            let xRange = xMin...xMax
            staves.append(Staff(
                pageIndex: pageIndex,
                yLines: ys,
                xRange: xRange,
                barlineCandidates: barlineCandidates(
                    in: paths, xRange: xRange, yRange: ys.first!...ys.last!,
                    pageIndex: pageIndex
                )
            ))
        }

        return staves.sorted { $0.yLines.middle < $1.yLines.middle }
    }

    private static func barlineCandidates(
        in paths: [PathSegment],
        xRange: ClosedRange<CGFloat>,
        yRange: ClosedRange<CGFloat>,
        pageIndex: Int
    ) -> [PathSegment] {
        paths.filter {
            $0.pageIndex == pageIndex
                && $0.kind == .vertical
                && xRange.contains($0.rect.midX)
                && $0.rect.minY <= yRange.upperBound
                && $0.rect.maxY >= yRange.lowerBound
        }
    }
}

private extension Array where Element == CGFloat {
    var middle: CGFloat { isEmpty ? 0 : self[count / 2] }
}
```

- [ ] **Step 4: Run tests**

`swift test --filter PDFImporterStaffLinesTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+StaffLines.swift \
        Tests/SheetMusicTests/PDFImporterStaffLinesTests.swift
git commit -m "feat(pdf): staff-line detection from path + glyph"
```

---

## Task 5: Layout — page → system → part → staff → measure

**Goal:** Cluster `[Staff]` records into `ImportSystem`s (y-bands), couple grand-staff staves into `ImportPart`s via bracket/brace path geometry, and split each staff into `ImportMeasure`s by barline x-position.

Algorithm (`PDFImporter.layoutPages`):

1. Group input `[Staff]` by `pageIndex`.
2. Within a page, cluster staves into systems: a system = consecutive staves whose y-gap is < 1.5 × staff height. (Bigger gaps separate systems.)
3. Within a system, group staves into parts via bracket/brace paths: a vertical path immediately to the left of the system that spans two staves' combined y-range → grand staff (one part of two staves). Otherwise each staff is its own part.
4. For each staff in each system, derive measure cells from `barlineCandidates`:
    - Sort candidates by x.
    - Cells = consecutive-x gaps between sorted candidates, plus the leading region (`xRange.lowerBound` to first barline) if there is a left edge.
    - For each cell, collect glyphs whose `origin.x` falls inside `[xMin, xMax)` (input is the global classified-glyph list).
5. Cross-staff alignment: two staves in the same system must produce the same measure count. If they don't (often a path was missed), fall back to taking the union of barline x-positions and re-splitting both staves at the union; emit a `warning` diagnostic if a staff still produces fewer measures than its peer.

**Files:**
- Create: `Sources/SheetMusicPDF/Import/PDFImporter+Layout.swift`
- Create: `Tests/SheetMusicTests/PDFImporterLayoutTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import CoreGraphics
import Foundation
@testable import SheetMusicPDF
import Testing

@Suite @MainActor struct PDFImporterLayoutTests {
    private func staff(yMid: CGFloat, xRange: ClosedRange<CGFloat>,
                       barlineXs: [CGFloat]) -> Staff {
        let yLines = (-2...2).map { yMid + CGFloat($0) * 5 }
        let bars = barlineXs.map {
            PathSegment(kind: .vertical,
                        rect: CGRect(x: $0, y: yLines.first!, width: 0,
                                     height: yLines.last! - yLines.first!),
                        lineWidth: 0.5, pageIndex: 0)
        }
        return Staff(pageIndex: 0, yLines: yLines, xRange: xRange,
                     barlineCandidates: bars)
    }

    @Test func twoNearStavesFormOneSystem() {
        let s1 = staff(yMid: 700, xRange: 50...550, barlineXs: [200, 400, 550])
        let s2 = staff(yMid: 660, xRange: 50...550, barlineXs: [200, 400, 550])
        let systems = PDFImporter.layoutSystems(
            staves: [s1, s2], paths: [], classified: [], pageIndex: 0
        )
        #expect(systems.count == 1)
        #expect(systems.first?.parts.flatMap(\.staves).count == 2)
    }

    @Test func farStavesSplitIntoTwoSystems() {
        let s1 = staff(yMid: 700, xRange: 50...550, barlineXs: [550])
        let s2 = staff(yMid: 200, xRange: 50...550, barlineXs: [550])
        let systems = PDFImporter.layoutSystems(
            staves: [s1, s2], paths: [], classified: [], pageIndex: 0
        )
        #expect(systems.count == 2)
    }

    @Test func barlinesSplitMeasures() {
        let s = staff(yMid: 500, xRange: 50...550, barlineXs: [200, 400, 550])
        let systems = PDFImporter.layoutSystems(
            staves: [s], paths: [], classified: [], pageIndex: 0
        )
        let measures = systems.first?.parts.first?.staves.first?.measures ?? []
        // 3 cells: (50,200), (200,400), (400,550)
        #expect(measures.count == 3)
        #expect(abs(measures[0].xRange.lowerBound - 50) < 1)
        #expect(abs(measures[2].xRange.upperBound - 550) < 1)
    }

    @Test func bracketCouplesGrandStaff() {
        let upper = staff(yMid: 700, xRange: 50...550, barlineXs: [550])
        let lower = staff(yMid: 660, xRange: 50...550, barlineXs: [550])
        // Vertical path covering both staves at the left edge.
        let bracket = PathSegment(
            kind: .vertical,
            rect: CGRect(x: 48, y: 658, width: 0, height: 44),
            lineWidth: 1.5, pageIndex: 0
        )
        let systems = PDFImporter.layoutSystems(
            staves: [upper, lower], paths: [bracket],
            classified: [], pageIndex: 0
        )
        #expect(systems.first?.parts.count == 1)
        #expect(systems.first?.parts.first?.staves.count == 2)
    }

    @Test func glyphsAreAssignedToTheirMeasureCell() {
        let s = staff(yMid: 500, xRange: 50...550, barlineXs: [200, 400, 550])
        let g = ClassifiedGlyph(
            raw: RawGlyph(codepoint: 0xE0A4, fontName: "Bravura", fontSize: 20,
                          origin: CGPoint(x: 250, y: 500), advance: 5, pageIndex: 0),
            semantic: .noteheadBlack
        )
        let systems = PDFImporter.layoutSystems(
            staves: [s], paths: [], classified: [g], pageIndex: 0
        )
        let measures = systems.first?.parts.first?.staves.first?.measures ?? []
        #expect(measures[0].glyphs.isEmpty)
        #expect(measures[1].glyphs.count == 1)   // x=250 is in (200,400)
        #expect(measures[2].glyphs.isEmpty)
    }
}
```

- [ ] **Step 2: Run — confirm failure**

`swift test --filter PDFImporterLayoutTests` → FAIL (`layoutSystems` undefined).

- [ ] **Step 3: Implement `layoutSystems`**

In `Sources/SheetMusicPDF/Import/PDFImporter+Layout.swift`:

```swift
import CoreGraphics
import Foundation

extension PDFImporter {
    /// Cluster staves into systems and parts on a single page,
    /// then split each staff into measure cells by barline.
    /// `paths` is the unfiltered page-level path list (used to detect
    /// brackets / braces). `classified` is the page-level classified
    /// glyph list (used to bin glyphs into measure cells).
    static func layoutSystems(
        staves: [Staff],
        paths: [PathSegment],
        classified: [ClassifiedGlyph],
        pageIndex: Int
    ) -> [ImportSystem] {
        let pageStaves = staves
            .filter { $0.pageIndex == pageIndex }
            .sorted { $0.yLines.first! > $1.yLines.first! }    // page top → bottom

        // 1. Cluster into systems by y-gap.
        var systems: [[Staff]] = []
        for staff in pageStaves {
            if var cur = systems.last, let prev = cur.last,
               abs(staff.yLines.first! - prev.yLines.last!) < 1.5 * staffHeight(prev) {
                cur.append(staff)
                systems[systems.count - 1] = cur
            } else {
                systems.append([staff])
            }
        }

        // 2. Couple staves into parts within each system.
        return systems.map { staffGroup -> ImportSystem in
            let parts = couplingByBracket(
                staves: staffGroup, paths: paths, pageIndex: pageIndex
            )
            let yRange = (staffGroup.last!.yLines.last!)...(staffGroup.first!.yLines.first!)
            return ImportSystem(pageIndex: pageIndex, yRange: yRange, parts: parts)
        }
        .map { addingMeasures($0, classified: classified) }
    }

    private static func staffHeight(_ s: Staff) -> CGFloat {
        guard let lo = s.yLines.last, let hi = s.yLines.first else { return 0 }
        return abs(hi - lo)
    }

    private static func couplingByBracket(
        staves: [Staff], paths: [PathSegment], pageIndex: Int
    ) -> [ImportPart] {
        // Find vertical paths immediately to the left of `xRange.lowerBound`
        // (within ~5pt) whose y-span covers two or more staff y-ranges.
        // Each bracket couples those staves into a single ImportPart.
        var coupled = Array(repeating: false, count: staves.count)
        var parts: [ImportPart] = []
        for path in paths where path.pageIndex == pageIndex && path.kind == .vertical {
            let leftX = staves.first?.xRange.lowerBound ?? 0
            guard abs(path.rect.midX - leftX) < 5 else { continue }
            var coupledIdxs: [Int] = []
            for (i, s) in staves.enumerated() where !coupled[i] {
                let mid = s.yLines.middle
                if path.rect.minY <= mid && mid <= path.rect.maxY {
                    coupledIdxs.append(i)
                }
            }
            if coupledIdxs.count >= 2 {
                let group = coupledIdxs.map { ImportStaff(staff: staves[$0], measures: []) }
                parts.append(ImportPart(staves: group))
                for i in coupledIdxs { coupled[i] = true }
            }
        }
        for (i, s) in staves.enumerated() where !coupled[i] {
            parts.append(ImportPart(staves: [ImportStaff(staff: s, measures: [])]))
        }
        return parts
    }

    private static func addingMeasures(
        _ system: ImportSystem, classified: [ClassifiedGlyph]
    ) -> ImportSystem {
        var parts = system.parts
        for p in 0..<parts.count {
            for s in 0..<parts[p].staves.count {
                let staff = parts[p].staves[s].staff
                let xs = ([staff.xRange.lowerBound]
                    + staff.barlineCandidates.map(\.rect.midX).sorted()
                    + [staff.xRange.upperBound]
                ).reduce(into: [CGFloat]()) { acc, x in
                    if acc.last.map({ abs($0 - x) > 1 }) ?? true { acc.append(x) }
                }
                var measures: [ImportMeasure] = []
                for i in 0..<(xs.count - 1) {
                    let lo = xs[i], hi = xs[i + 1]
                    let cellGlyphs = classified.filter {
                        $0.raw.pageIndex == staff.pageIndex
                            && lo <= $0.raw.origin.x
                            && $0.raw.origin.x < hi
                            && staff.yLines.last! - 30 <= $0.raw.origin.y
                            && $0.raw.origin.y <= staff.yLines.first! + 30
                    }
                    measures.append(ImportMeasure(
                        xRange: lo...hi,
                        glyphs: cellGlyphs,
                        leadingBarline: i == 0 ? nil
                            : staff.barlineCandidates.first { abs($0.rect.midX - lo) < 1 },
                        trailingBarline: i == xs.count - 2 ? nil
                            : staff.barlineCandidates.first { abs($0.rect.midX - hi) < 1 }
                    ))
                }
                parts[p].staves[s].measures = measures
            }
        }
        return ImportSystem(pageIndex: system.pageIndex, yRange: system.yRange, parts: parts)
    }
}

private extension Array where Element == CGFloat {
    var middle: CGFloat { isEmpty ? 0 : self[count / 2] }
}
```

- [ ] **Step 4: Cross-staff alignment fallback**

If the test suite is green to here, add one more test to enforce that two staves with mismatched barline counts are realigned:

```swift
@Test func crossStaffAlignmentUnifiesBarlines() {
    let s1 = staff(yMid: 700, xRange: 50...550, barlineXs: [200, 400, 550])
    let s2 = staff(yMid: 660, xRange: 50...550, barlineXs: [400, 550])  // missing 200
    let systems = PDFImporter.layoutSystems(
        staves: [s1, s2], paths: [], classified: [], pageIndex: 0
    )
    let counts = systems.first?.parts.flatMap { $0.staves.map { $0.measures.count } }
    #expect(counts == [3, 3])
}
```

Then in `addingMeasures`, before computing per-staff `xs`, take the union of barline midXs across all staves in the same part. (Two-pass: collect union → split each staff at the union x-list.)

- [ ] **Step 5: Run tests; full suite; lint**

`swift test --filter PDFImporterLayoutTests`; `swift test`; `swiftlint --quiet Sources Tests` → all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+Layout.swift \
        Tests/SheetMusicTests/PDFImporterLayoutTests.swift
git commit -m "feat(pdf): page→system→part→staff→measure layout"
```

---

## Task 6: Score-state extraction (clef, key, time, tempo)

**Goal:** Walk each `ImportStaff`'s measures left-to-right and emit `[ScoreStateEvent]` for clef changes, time signatures, key signatures, and tempo markings.

Detection rules (from spec §Pipeline [5b]):

- **Clef:** any `.clefG` / `.clefF` / `.clefC` / `.clefPercussion` glyph at the start of a staff or after a barline.
- **Time signature:** consecutive `.timeSignatureDigit(_)` glyphs at the start of a staff or after a double-barline. Stack vertically (two glyphs on similar x but different y) → `numerator/denominator`. `.timeSignatureCommon` → 4/4. `.timeSignatureCutTime` → 2/2.
- **Key signature:** runs of `.accidentalSharp` / `.accidentalFlat` / `.accidentalNatural` glyphs immediately after a clef or after a barline, **before** the first notehead in the measure. Count and orientation determine the key (sharps: F♯ C♯ G♯ D♯ A♯ E♯ B♯; flats: B♭ E♭ A♭ D♭ G♭ C♭ F♭). Translate count → `KeySignature`. Naturals before sharps/flats indicate the previous key being cancelled — emit `KeySignature.cMajor` (or whatever the C-major spelling is in the model) plus the new one if accidentals follow, else just C.
- **Tempo:** `TextGlyph` runs above the top staff of a system. The metronome equation `♩ = 128` typically appears as one SMuFL note glyph (`.noteheadBlack` + a `.flag8thUp` for eighth, or a `.noteheadHalf` for half) followed by an `=` text glyph and a numeric text glyph. The plain text portion (e.g. "Allegro") can precede the equation. Result: `Tempo(text: "Allegro ♩ = 128", bpm: 128)` or `Tempo(text: "Allegro", bpm: nil)` if no equation.

**Files:**
- Create: append to `Sources/SheetMusicPDF/Import/PDFImporter+Layout.swift` (this file is still under 300 lines; if it grows past the cap, split into `PDFImporter+ScoreState.swift`).
- Create: `Tests/SheetMusicTests/PDFImporterScoreStateTests.swift`

- [ ] **Step 1: Tests for clef extraction**

```swift
@Test func extractsLeadingTrebleClef() {
    let staff = ImportStaff(
        staff: synthStaff(),
        measures: [
            ImportMeasure(
                xRange: 50...200, glyphs: [
                    classified(.clefG, x: 60, y: 100)
                ],
                leadingBarline: nil, trailingBarline: nil
            )
        ]
    )
    let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
    let clefs = events.compactMap { e -> Clef? in
        if case let .clefChange(c, _) = e { return c } else { return nil }
    }
    #expect(clefs.count == 1)
    // Clef.treble equivalent in this codebase — match the actual case spelling.
}
```

…and analogous tests for time signature digits stacking, key signature accidentals (4 sharps → E major), and tempo `Allegro ♩ = 128`. Use the helpers `synthStaff()` and `classified(_:x:y:)` declared at the top of the test file.

- [ ] **Step 2: Run — confirm failure**

`swift test --filter PDFImporterScoreStateTests` → FAIL.

- [ ] **Step 3: Implement `scoreStateEvents(staff:texts:)`**

Implementation outline:

```swift
extension PDFImporter {
    static func scoreStateEvents(
        staff: ImportStaff, texts: [TextGlyph]
    ) -> [ScoreStateEvent] {
        var events: [ScoreStateEvent] = []
        for (i, measure) in staff.measures.enumerated() {
            // Walk glyphs left-to-right.
            let sorted = measure.glyphs.sorted { $0.raw.origin.x < $1.raw.origin.x }
            var idx = 0
            // 1. Optional clef.
            if let clef = readClef(&idx, glyphs: sorted) {
                events.append(.clefChange(clef, atMeasureIndex: i))
            }
            // 2. Optional key signature.
            if let key = readKey(&idx, glyphs: sorted) {
                events.append(.keySignature(key, atMeasureIndex: i))
            }
            // 3. Optional time signature.
            if let ts = readTime(&idx, glyphs: sorted) {
                events.append(.timeSignature(ts, atMeasureIndex: i))
            }
        }
        // 4. Tempo from texts above top staff (only call when staff is the top one).
        // The caller decides; this method takes the relevant texts.
        for tempo in extractTempos(staff: staff, texts: texts) {
            events.append(.tempo(tempo.value, atMeasureIndex: tempo.measureIndex))
        }
        return events
    }

    // readClef / readKey / readTime / extractTempos are private helpers —
    // each ≤30 lines, total file under 300.
}
```

`readKey` algorithm: count consecutive `.accidentalSharp` (or `.accidentalFlat`) glyphs while no notehead has appeared. The count determines the key (1 sharp → G major / E minor; we emit major by default since v1 has no minor-mode detection).

- [ ] **Step 4: Run tests until green; lint; commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+Layout.swift \
        Tests/SheetMusicTests/PDFImporterScoreStateTests.swift
git commit -m "feat(pdf): clef/key/time/tempo extraction"
```

---

## Task 7: Pitch decoding

**Goal:** For each notehead glyph in an `ImportMeasure`, compute MIDI pitch (`Int`) and tonal pitch class (`tpc`) from:
- the active clef,
- the active key signature,
- measure-local accidentals (preceding `.accidentalSharp` / `.accidentalFlat` / `.accidentalNatural` glyphs on the same y-line),
- the notehead's y-position relative to the staff's `yLines`.

The state machine resets measure-local accidentals at every barline (per same pitch class + octave, matching standard engraving — store accidental-by-pitch-class-and-octave in a `[Int: Int]` keyed by `(diatonicStep, octave)`).

Diatonic step calculation: for treble clef, the staff's bottom line is E4 (step 2, octave 4). Each line / space upwards adds one diatonic step. Convert `(step, accidentalAlteration)` + key signature → MIDI pitch via the standard major-scale degree → semitone offset table.

**Files:**
- Create: `Sources/SheetMusicPDF/Import/PDFImporter+Pitch.swift`
- Create: `Tests/SheetMusicTests/PDFImporterPitchTests.swift`

- [ ] **Step 1: Failing tests** — mid-staff line under treble = B4 (60+11=71), under bass = D3, accidental propagates to same octave only, accidental resets at barline, key signature applies absent local accidental.

```swift
@Test func trebleMidLineIsB4() {
    // ...build a measure with one notehead on the middle staff line in treble clef
    let pitches = PDFImporter.decodePitches(
        measure: m, activeClef: .treble, activeKey: .cMajor
    )
    #expect(pitches.first?.midi == 71)
}

@Test func sharpInKeyOfGAppliesByDefault() {
    // Notehead on the F line, key signature G major (1 sharp), no local accidental
    let pitches = PDFImporter.decodePitches(
        measure: m, activeClef: .treble, activeKey: .gMajor
    )
    #expect(pitches.first?.midi == 78)   // F#5
}

@Test func localAccidentalPropagatesToEndOfMeasure() {
    // Two F noteheads in C major, the first has a local sharp.
    let pitches = PDFImporter.decodePitches(
        measure: m, activeClef: .treble, activeKey: .cMajor
    )
    #expect(pitches[0].midi == 66)
    #expect(pitches[1].midi == 66)   // still F#
}

@Test func accidentalResetsAtBarline() {
    // Same setup as above but in *next* measure: notehead is plain F.
    // Two-call test: first decode m1, then m2 with a fresh state.
    // (Or pass an array of measures and verify state reset semantics.)
}
```

- [ ] **Step 2: Run — confirm failure**

- [ ] **Step 3: Implement**

```swift
extension PDFImporter {
    struct DecodedPitch {
        var midi: Int
        var tpc: Int
        var glyph: ClassifiedGlyph   // back-pointer for downstream rhythm pass
    }

    static func decodePitches(
        measure: ImportMeasure,
        activeClef: Clef,
        activeKey: KeySignature
    ) -> [DecodedPitch] {
        var localAccidentals: [PitchKey: Int] = [:]      // (step, octave) → semitone offset
        var out: [DecodedPitch] = []

        let sorted = measure.glyphs.sorted { $0.raw.origin.x < $1.raw.origin.x }
        var idx = 0
        while idx < sorted.count {
            let g = sorted[idx]
            switch g.semantic {
            case .accidentalSharp, .accidentalFlat, .accidentalNatural,
                 .accidentalDoubleSharp, .accidentalDoubleFlat:
                // Pair with the *next* notehead at similar y.
                if let nh = nextNoteheadAtSameY(after: idx, in: sorted) {
                    let key = pitchKey(noteheadY: nh.raw.origin.y,
                                       clef: activeClef,
                                       staffYLines: measure.staffYLines)
                    localAccidentals[key] = accidentalOffset(g.semantic)
                }
            case .noteheadBlack, .noteheadHalf, .noteheadWhole, .noteheadDoubleWhole:
                let key = pitchKey(noteheadY: g.raw.origin.y,
                                   clef: activeClef,
                                   staffYLines: measure.staffYLines)
                let semitone = baseSemitone(stepKey: key,
                                            keySignature: activeKey,
                                            localOverride: localAccidentals[key])
                let tpc = computeTPC(stepKey: key, semitone: semitone)
                out.append(DecodedPitch(midi: semitone, tpc: tpc, glyph: g))
            default:
                break
            }
            idx += 1
        }
        return out
    }

    private struct PitchKey: Hashable {
        var diatonicStep: Int   // 0=C, 1=D, …, 6=B
        var octave: Int
    }

    // pitchKey, baseSemitone, computeTPC, accidentalOffset, nextNoteheadAtSameY:
    // straightforward helpers — each ≤25 lines.
}

private extension ImportMeasure {
    /// Cached y-lines from the parent staff, written by the layout pass.
    /// (Add a `staffYLines: [CGFloat]` field to ImportMeasure in
    /// Internal.swift; populate during `addingMeasures` in Task 5.)
    var staffYLines: [CGFloat] { ... }
}
```

The `staffYLines` cache on `ImportMeasure` is added in this task — update `Internal.swift` and the `addingMeasures` helper from Task 5 to populate it.

- [ ] **Step 4: Run, lint, commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+Pitch.swift \
        Sources/SheetMusicPDF/Import/Internal.swift \
        Sources/SheetMusicPDF/Import/PDFImporter+Layout.swift \
        Tests/SheetMusicTests/PDFImporterPitchTests.swift
git commit -m "feat(pdf): clef/key/accidental → pitch decoder"
```

---

## Task 8: Rhythm decoding + chord assembly

**Goal:** For each notehead in a measure, derive `NoteDuration`. Cluster vertically-stacked noteheads sharing one stem path into `Chord`s.

Rules:

1. Base duration from notehead semantic: `.noteheadDoubleWhole` → breve; `.noteheadWhole` → whole; `.noteheadHalf` → half; `.noteheadBlack` → quarter.
2. Stem path detection: a vertical path segment whose x is within 2pt of the notehead's x and whose y-extent meets the notehead's y. If absent on a `.noteheadBlack`, the duration may be a beamed group — see step 4. If absent on a `.noteheadWhole`, fine (whole notes have no stem).
3. Flag count: count `.flag8thUp/Down` / `.flag16thUp/Down` glyphs whose origin lies near the *end* of the stem (top for stem-up, bottom for stem-down). 1 flag → eighth, 2 → 16th, 3 → 32nd, 4 → 64th. Halve the duration per flag from quarter base.
4. Beam path detection: thick horizontal path segments crossing the stem at one or more y-positions. One beam segment = eighth, two stacked = 16th, etc. (Same divisor logic as flags.)
5. Augmentation dots: `.augmentationDot` glyphs to the right of the notehead at similar y, count → dot count; multiply duration by 1.5^N.
6. Chord assembly: noteheads on the same stem path (within 2pt x) within the same measure cluster into one `Chord`. The chord's duration is the duration computed for the cluster (all noteheads share it).

**Files:**
- Create: `Sources/SheetMusicPDF/Import/PDFImporter+Rhythm.swift`
- Create: `Tests/SheetMusicTests/PDFImporterRhythmTests.swift`

- [ ] **Step 1: Tests** — black notehead alone → quarter; black + 1 flag → eighth; black + 1 dot → quarter dotted; two noteheads on same stem → 1 chord with 2 notes; two noteheads on adjacent stems → 2 chords.

```swift
@Test func blackNoteheadAloneIsQuarter() {
    let measure = makeMeasure(noteheads: [(x: 100, y: 500, kind: .noteheadBlack)],
                              stems: [(x: 100, yRange: 480...520)])
    let chords = PDFImporter.decodeRhythm(
        measure: measure, decoded: testPitches([(midi: 60, x: 100)]),
        paths: []
    )
    #expect(chords.first?.duration == .quarter)
    #expect(chords.first?.notes.count == 1)
}

@Test func twoNoteheadsOneStemFormOneChord() {
    let chords = PDFImporter.decodeRhythm(...)
    #expect(chords.count == 1)
    #expect(chords.first?.notes.count == 2)
}
```

- [ ] **Step 2: Run — confirm failure**

- [ ] **Step 3: Implement**

```swift
extension PDFImporter {
    static func decodeRhythm(
        measure: ImportMeasure,
        decoded: [DecodedPitch],
        paths: [PathSegment]
    ) -> [Chord] {
        // 1. Cluster decoded pitches by shared-stem x.
        // 2. For each cluster, determine base duration from notehead semantic.
        // 3. Apply flag count + beam count → divide.
        // 4. Apply augmentation dots → multiply.
        // 5. Build Chord(notes: [Note], duration: NoteDuration).
        ...
    }
}
```

For rests, this stage also produces `VoiceElement.rest(...)` from `.rest(NoteDuration)` semantics found in the measure — but rests don't go through pitch decoding, so threading is: produce `[RhythmElement]` where `RhythmElement` is `chord(Chord) | rest(Rest)`, then voicing (Task 9) assigns to voices.

Add to `Internal.swift`:

```swift
enum RhythmElement {
    case chord(Chord, stemDirection: StemDirection?, x: CGFloat)
    case rest(Rest, x: CGFloat, y: CGFloat)
}
```

(`StemDirection` is whatever `SheetMusicCore` already uses — match the existing type.)

- [ ] **Step 4: Run, lint, commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+Rhythm.swift \
        Sources/SheetMusicPDF/Import/Internal.swift \
        Tests/SheetMusicTests/PDFImporterRhythmTests.swift
git commit -m "feat(pdf): rhythm decoding (flag/beam/dot) + chord assembly"
```

---

## Task 9: Voicing — time-coverage overlap

**Goal:** Decide whether a measure is single-voice or multi-voice; assign rhythm elements to `Voice`s.

Algorithm (verbatim from spec):

1. Group consecutive beamed elements into rhythmic units. A solo unbeamed chord/rest is its own unit.
2. Compute each unit's time interval `[x_start, x_start + d]` where `d` is the unit's duration converted to the measure's x-axis scale.
3. If any two units' intervals overlap → multi-voice; else single-voice.
4. **Single voice:** all rhythm elements → voice 1.
5. **Multi voice:**
    - Stem-up chord → voice 1.
    - Stem-down chord → voice 2.
    - Stemless chord (whole note): if y above staff middle → voice 1; below → voice 2.
    - Rest: above staff middle → voice 1; below → voice 2.
6. Voices 3 / 4 (would require detecting a third stem direction or third y-band cluster of stemless elements) collapse into voice 1 / 2 with a `warning` diagnostic emitted at this measure's location.

x-axis time scale: width of measure / `timeSignature.beats`. Convert `NoteDuration` → fractional beats via the existing `NoteDuration.fraction` (or however `SheetMusicCore` exposes it).

**Files:**
- Create: `Sources/SheetMusicPDF/Import/PDFImporter+Voicing.swift`
- Create: `Tests/SheetMusicTests/PDFImporterVoicingTests.swift`

- [ ] **Step 1: Tests** — beamed eighths against quarter rest = 2 voices; sequential quarter notes = 1 voice; high arch melody (stem flips) but no overlap = 1 voice.

- [ ] **Step 2: Run — confirm failure**

- [ ] **Step 3: Implement**

```swift
extension PDFImporter {
    static func assignVoices(
        elements: [RhythmElement],
        measureXRange: ClosedRange<CGFloat>,
        timeSignature: TimeSignature,
        staffMidY: CGFloat,
        diagnostics: ((PDFImportDiagnostic) -> Void)?,
        location: String
    ) -> [Voice] {
        let units = groupBeamedUnits(elements)
        let intervals = units.map { intervalFor(unit: $0,
                                                xRange: measureXRange,
                                                timeSignature: timeSignature) }
        let multiVoice = anyOverlap(intervals: intervals)
        if !multiVoice {
            return [Voice(elements: elements.map(\.voiceElement))]
        }
        var v1: [VoiceElement] = []
        var v2: [VoiceElement] = []
        for u in units {
            for el in u.elements {
                switch voiceFor(el, staffMidY: staffMidY) {
                case 1: v1.append(el.voiceElement)
                case 2: v2.append(el.voiceElement)
                default:
                    diagnostics?(PDFImportDiagnostic(
                        severity: .warning, location: location,
                        message: "Voice 3+ collapsed into voice 1"
                    ))
                    v1.append(el.voiceElement)
                }
            }
        }
        return [Voice(elements: v1), Voice(elements: v2)]
    }

    // groupBeamedUnits / intervalFor / anyOverlap / voiceFor — private helpers.
}

private extension RhythmElement {
    var voiceElement: VoiceElement {
        switch self {
        case let .chord(c, _, _): return .chord(c)
        case let .rest(r, _, _): return .rest(r)
        }
    }
}
```

- [ ] **Step 4: Run, lint, commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+Voicing.swift \
        Tests/SheetMusicTests/PDFImporterVoicingTests.swift
git commit -m "feat(pdf): time-coverage multi-voice detection"
```

---

## Task 10: Lyrics

**Goal:** Cluster lyric `TextGlyph`s into y-bands directly under each staff (one band per verse). Match each syllable to the nearest notehead by x-position. Hyphen `-` → middle/end syllable; underscore `_` → melisma extension.

Algorithm:

1. For each `ImportStaff`, define a y-window from `yLines.last - 4 × lineSpacing` (~staff height worth below).
2. Collect `TextGlyph`s whose origin y is in the window AND whose x is in the staff's `xRange`.
3. Cluster by y (tolerance = lineSpacing): each cluster is one verse, ordered by y descending (verse 1 closest to staff).
4. For each verse, sort syllables by x; for each syllable, find the closest notehead-x in the staff's measures across all voices' chord onsets, and attach as a `Lyric`.
5. Hyphen termination: if the syllable text ends with `-`, mark it as `Lyric.Syllabic.middle/begin`. Otherwise `single` or `end` based on the previous syllable's hyphen state.
6. Underscore: a syllable that *is* `_` extends the previous syllable's melisma. Don't attach as a new syllable.

**Files:**
- Create: `Sources/SheetMusicPDF/Import/PDFImporter+Lyrics.swift`
- Create: `Tests/SheetMusicTests/PDFImporterLyricsTests.swift`

- [ ] **Step 1: Tests** — single verse "Hap-py birth-day" produces 4 syllables on 4 noteheads with correct syllabic flags; two-verse separation by y; melisma underscore extends the previous syllable.

- [ ] **Step 2: Run — confirm failure**

- [ ] **Step 3: Implement** — function signature:

```swift
extension PDFImporter {
    static func attachLyrics(
        staff: inout ImportStaff,
        texts: [TextGlyph]
    ) {
        // Mutate staff.measures' chords' notes to add Lyric.
        // Skip whatever is already not a chord (rests don't get lyrics).
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+Lyrics.swift \
        Tests/SheetMusicTests/PDFImporterLyricsTests.swift
git commit -m "feat(pdf): lyric y-band clustering and syllable matching"
```

---

## Task 11: Structural marks (repeats, voltas, rehearsal marks, jumps)

**Goal:** From barline path geometry + adjacent text, derive:
- `BarLine.subtype` (single / double / start-repeat / end-repeat / final).
- Volta `Spanner` (rectangular bracket above measures, with internal `1.` / `2.` text).
- `RehearsalMark` (capital letter inside a thin rectangle above a system's first measure).
- `Marker` / `Jump` from text labels: `Segno`, `Coda`, `Fine`, `D.C.`, `D.S.`, `D.S. al Coda`, `To Coda`.

Algorithm sketches:

- **Barline subtype:** for each barline path, look at its lineWidth + the existence of a second vertical path within 3pt. Two thin lines → `double`. Two lines where one is thick → `final`. Plus two `.repeatBarlineDots` glyphs on either side → `start-repeat` / `end-repeat`.
- **Volta:** find rectangular path segments (PathSegment.kind == .rectangle) above a system's first staff, height < 20pt, width > 50pt. Inside the bracket, find `TextGlyph` `1.` / `2.` / `1.–2.` and the bracket's x-span → measure indices it covers. Build `Spanner(subType: .volta, ...)`.
- **Rehearsal mark:** thin rectangle (≤ 30pt wide, ≤ 20pt tall) above a measure with a single capital-letter `TextGlyph` inside → `RehearsalMark(text: letter, ...)`.
- **Markers / jumps:** `TextGlyph` whose normalized text matches `^(D\.C\.|D\.S\.|Fine|Coda|To Coda|Segno)( al .*)?$` adjacent to a barline → `Marker` (Segno/Coda/Fine) or `Jump` (D.C./D.S./To Coda).

**Files:**
- Create: `Sources/SheetMusicPDF/Import/PDFImporter+Structure.swift`
- Create: `Tests/SheetMusicTests/PDFImporterStructureTests.swift`

- [ ] **Step 1: Tests** — start-repeat barline detection; volta `1.` over measures 5–6; rehearsal mark `B`; `D.C. al Fine` text adjacent to final barline.

- [ ] **Step 2..4: Implement, run, commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+Structure.swift \
        Tests/SheetMusicTests/PDFImporterStructureTests.swift
git commit -m "feat(pdf): structural marks (repeats, voltas, rehearsals, jumps)"
```

---

## Task 12: Title / composer / metadata fallback

**Goal:** Extract title, subtitle, composer/arranger from frame text on page 1; fall back to `PDFDocument` metadata when option set.

Algorithm:

1. Take all `TextGlyph`s on page 0 with origin y > 75% of page height (top band).
2. Sort by font size descending. Largest (and not right-aligned) → `title`. Italic medium → `subtitle`. Right-aligned (origin x > 60% of page width) → `composer` or `arranger`.
3. If any field still empty AND `options.useMetadataAsFallback`: read `PDFDocument.documentAttributes` — `Title` → `score.title` if missing, `Author` → `score.composer` if missing, `Subject` → `score.subtitle` if missing.

**Files:**
- Create: `Sources/SheetMusicPDF/Import/PDFImporter+Text.swift`
- Create: `Tests/SheetMusicTests/PDFImporterTextTests.swift`

- [ ] **Step 1..4: TDD: tests, fail, implement, commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter+Text.swift \
        Tests/SheetMusicTests/PDFImporterTextTests.swift
git commit -m "feat(pdf): title/composer extraction with metadata fallback"
```

---

## Task 13: Pipeline assembly + façade wiring

**Goal:** Wire stages 1–12 into `PDFImporter.parse(pdfData:options:)`. Replace the `throw` stub from Task 1 with the actual pipeline. Failure-mode rules from the spec land here.

Pipeline (matching spec §Pipeline):

```swift
public static func parse(pdfData: Data, options: PDFImportOptions = .init()) throws -> Score {
    guard !pdfData.isEmpty else { throw SheetMusicError.malformedScore("empty") }
    guard let document = PDFDocument(data: pdfData) else {
        throw SheetMusicError.malformedScore("not a valid PDF")
    }
    guard document.pageCount > 0 else { throw SheetMusicError.malformedScore("zero pages") }

    let walker = ContentStreamWalker(document: document)
    let walked = try walker.walk()                                       // [1][2]
    guard !walked.glyphs.isEmpty || !walked.texts.isEmpty else {
        throw SheetMusicError.malformedScore("no glyphs found")
    }
    let classified = walked.glyphs.map { raw in
        ClassifiedGlyph(raw: raw, semantic: smuflSemantic(codepoint: raw.codepoint))
    }
    emitUnknownGlyphDiagnostics(classified, options: options)            // [3]

    var systemsAllPages: [ImportSystem] = []
    for page in 0..<document.pageCount {
        let pageStaves = detectStaves(
            paths: walked.paths.filter { $0.pageIndex == page },
            classified: classified.filter { $0.raw.pageIndex == page },
            pageIndex: page
        )                                                                // [4]
        let systems = layoutSystems(
            staves: pageStaves,
            paths: walked.paths,
            classified: classified,
            pageIndex: page
        )                                                                // [5]
        systemsAllPages.append(contentsOf: systems)
    }
    guard !systemsAllPages.isEmpty else {
        throw SheetMusicError.malformedScore("no staff detected on any page")
    }

    let score = assembleScore(
        document: document,
        systems: systemsAllPages,
        texts: walked.texts,
        classified: classified,
        options: options
    )
    return score
}
```

`assembleScore` builds the output `Score`:

1. For each "part position" (system index 0's part list), instantiate a `Part`. Parts are stable across systems if the same number/coupling repeats; otherwise emit a warning diagnostic.
2. For each part, collect all measures across systems in reading order (left-to-right within a system, top-to-bottom across systems within a page, top-to-bottom across pages).
3. Run state extraction (Task 6) per staff to get `[ScoreStateEvent]`. Apply running clef/key/time to each measure as it is decoded.
4. For each measure: pitch decode (Task 7), rhythm decode (Task 8), voicing (Task 9). Insert `Voice`s into the `Measure`.
5. Lyrics (Task 10) — attach to chord notes.
6. Structural marks (Task 11) — set barline subtypes, build `Spanner`s, append `Marker`/`Jump`.
7. Text (Task 12) — set `score.title` etc.
8. Apply `options.preserveBreaks`: when true, set `lineBreak = true` on the last `Measure` of each system, `pageBreak = true` on the last measure of each page.

**Files:**
- Modify: `Sources/SheetMusicPDF/Import/PDFImporter.swift` (replace stub)
- Add: `Tests/SheetMusicTests/PDFImporterFaçadeTests.swift` smoke cases for end-to-end (pending Task 15 for the comprehensive contract)

- [ ] **Step 1: Add a façade test exercising the whole pipeline on a synthetic PDF**

A minimal test using `PDFFixtureBuilder` to draw a single staff with one black notehead under treble clef, then assert the parse returns a `Score` with one chord at MIDI 71 (B4) — pinning the full pipeline path end-to-end. SMuFL fonts may not be installed; the test can use an alternative path that *exports* a tiny `Score` via `PDFExporter` then re-imports (this is what Task 15 generalises). For Task 13, an MVP smoke test that just confirms a non-empty `Score` is returned without throwing on a one-staff fixture is enough.

- [ ] **Step 2..3: Wire stages, iterate until smoke green**

`swift test --filter PDFImporterFaçadeTests` → PASS.

- [ ] **Step 4: Verify `parse(pdfURL:)` overload still funnels through `parse(pdfData:)`**

- [ ] **Step 5: Lint, full suite, commit**

```bash
git add Sources/SheetMusicPDF/Import/PDFImporter.swift \
        Tests/SheetMusicTests/PDFImporterFaçadeTests.swift
git commit -m "feat(pdf): wire 12-stage import pipeline through façade"
```

---

## Task 14: Diagnostics integration test

**Goal:** Verify diagnostics fire for the documented silent-degrade cases and stay silent when no callback is set.

**Files:**
- Create: `Tests/SheetMusicTests/PDFImporterDiagnosticsTests.swift`

- [ ] **Step 1: Failing tests**

```swift
@Suite @MainActor struct PDFImporterDiagnosticsTests {
    @Test func unknownCodepointEmitsInfo() throws {
        // Build a PDF with an unmapped PUA codepoint glyph.
        let data = PDFFixtureBuilder.build(glyphs: [
            .init(unicodeScalar: UnicodeScalar(0xE999)!,
                  fontName: "Helvetica", fontSize: 12,
                  origin: CGPoint(x: 100, y: 700))
        ])
        var captured: [PDFImportDiagnostic] = []
        var opts = PDFImportOptions()
        opts.diagnostics = { d in captured.append(d) }
        // Either parse throws (no staff) — that is fine — or it returns
        // a Score; either way the unknown-glyph diagnostic must fire.
        _ = try? PDFImporter.parse(pdfData: data, options: opts)
        #expect(captured.contains { $0.severity == .info })
    }

    @Test func nilCallbackIsSilent() throws {
        let data = PDFFixtureBuilder.build(glyphs: [
            .init(unicodeScalar: UnicodeScalar(0xE999)!,
                  fontName: "Helvetica", fontSize: 12,
                  origin: CGPoint(x: 100, y: 700))
        ])
        // No callback set; must not crash, must not throw on the
        // diagnostic path itself (only on the no-staff condition).
        _ = try? PDFImporter.parse(pdfData: data, options: PDFImportOptions())
    }
}
```

- [ ] **Step 2..3: Implement `emitUnknownGlyphDiagnostics` and the corresponding `warning` paths in voicing/structure if not already wired; run tests**

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/PDFImporterDiagnosticsTests.swift \
        Sources/SheetMusicPDF/Import/PDFImporter.swift
git commit -m "feat(pdf): diagnostics callback for unknown codepoints + voicing collapse"
```

---

## Task 15: Self-roundtrip golden test

**Goal:** For each `.mscx` covered by `MidiExportTests`, run: `MSCXParser.parse → PDFExporter.exportPDF → PDFImporter.parse`, then compare the two `Score`s for **musical-content equivalence** (parts, staves, measures, voices, chord pitches/durations/ties, rests, key/time/tempo, barline subtypes, voltas, repeats, rehearsal marks, lyrics — layout coordinates excluded).

Note: `PDFExporter` is `@MainActor`. Tests in this suite must be `@MainActor`. `MidiExportTests` and `MSCXParser.parse` are not `@MainActor`, so the test's main-actor isolation only matters for the exporter call.

**Files:**
- Create: `Tests/SheetMusicTests/PDFImporterRoundTripTests.swift`
- Create: `Tests/SheetMusicTests/Helpers/PDFRoundTripComparison.swift` (the equivalence comparator — analogous to `MidiSemanticComparison.swift`)

- [ ] **Step 1: Helper — `compareForPDFRoundTrip(a:b:)`**

```swift
@MainActor
enum PDFRoundTripComparison {
    /// Compare two Scores after a PDF roundtrip; tolerate layout
    /// coordinates and other PDF-side artifacts. Throws on mismatch
    /// with a precise location like "staves[1].measures[3].voices[0]".
    static func assertEquivalent(_ a: Score, _ b: Score, fixture: String) throws {
        // 1. Parts: same count, same instrument long names.
        // 2. Staves: same count, same id ordering.
        // 3. For each staff: same measure count.
        // 4. For each measure: same voice count, same time signature,
        //    same key signature, same barline subtype.
        // 5. For each voice: same element count, with element-wise:
        //    chord → same notes (pitch + tie), same duration.
        //    rest  → same duration.
        // 6. Lyrics: same syllable text + syllabic flag per note.
        // 7. Structural marks: same Marker/Jump/RehearsalMark sequence.
        ...
    }
}
```

- [ ] **Step 2: Test driver — parametrised suite**

```swift
@Suite @MainActor struct PDFImporterRoundTripTests {
    static let fixtures: [String] = [
        // Match the MidiExportTests fixture list. Start with the smallest
        // fixture to iterate fast; expand to all 12 once green.
        "midi01",
    ]

    @Test(arguments: fixtures)
    func mscxRoundTripsThroughPDF(name: String) async throws {
        let mscxURL = try #require(Bundle.module.url(
            forResource: name, withExtension: "mscx"
        ))
        let mscxData = try Data(contentsOf: mscxURL)
        let scoreA = try MSCXParser.parse(mscxData)
        let pdfData = try PDFExporter.exportPDF(score: scoreA, options: .init())
        let scoreB = try PDFImporter.parse(pdfData: pdfData)
        try PDFRoundTripComparison.assertEquivalent(scoreA, scoreB, fixture: name)
    }
}
```

(`PDFExporter.exportPDF(score:options:)` is the existing public method — confirm its actual name and signature with `grep -n "public static func" Sources/SheetMusicPDF/PDFExporter.swift` before committing.)

- [ ] **Step 3: Run with the smallest fixture**

`swift test --filter PDFImporterRoundTripTests` → fix issues iteratively.

This is **the place** where most pipeline bugs surface. Expect this task to spend 60–80% of the project's debugging budget. The diagnostic strategy:

- Failure in pitch → check Task 7 state machine; add focused unit test for the failing pitch under the failing key.
- Failure in rhythm → check Task 8; add focused unit test.
- Failure in voicing → check Task 9.
- Failure in barline subtype → check Task 11.

Each fix should land as its own commit on top of Task 15's WIP commit.

- [ ] **Step 4: Expand fixture list to the full MidiExportTests set, fix per-fixture issues**

- [ ] **Step 5: Commit (squashable into the per-fixture fixes)**

```bash
git add Tests/SheetMusicTests/PDFImporterRoundTripTests.swift \
        Tests/SheetMusicTests/Helpers/PDFRoundTripComparison.swift
git commit -m "test(pdf): self-roundtrip golden across MSCX fixtures"
```

---

## Task 16: Umbrella `SheetMusic.loadScore(pdfURL:)` overloads

**Goal:** Surface the import path through the umbrella façade, matching the MIDI/MSCX/MusicXML overload pattern.

**Files:**
- Modify: `Package.swift` (add `SheetMusicPDF` to the `SheetMusic` target's deps)
- Modify: `Sources/SheetMusic/SheetMusic.swift` (add re-export + overloads)
- Create: tests in `Tests/SheetMusicTests/SheetMusicFacadeTests.swift` (extend existing suite — `grep -n "@Suite" Tests/SheetMusicTests/SheetMusicFacadeTests.swift` to find it)

- [ ] **Step 1: Failing umbrella tests**

```swift
@Test func umbrellaLoadScoreFromPDFData() throws {
    // Use a fixture .pdf produced by exporting a tiny Score, similar
    // to the round-trip test pattern but kept as a pinned fixture if
    // any byte-stable variant is wanted. Otherwise reuse PDFExporter
    // at test time.
    let mscxData = try Data(contentsOf: Bundle.module.url(
        forResource: "midi01", withExtension: "mscx")!)
    let score = try MSCXParser.parse(mscxData)
    let pdf = try PDFExporter.exportPDF(score: score, options: .init())
    let imported = try SheetMusic.loadScore(pdfData: pdf)
    #expect(!imported.staves.isEmpty)
}

@Test func umbrellaLoadScoreFromPDFURL() throws {
    // Write the exported pdf to a temp file and read via URL overload.
}
```

- [ ] **Step 2: Run — fail (overloads don't exist)**

- [ ] **Step 3: Update `Package.swift`**

```swift
.target(
    name: "SheetMusic",
    dependencies: [
        "SheetMusicCore",
        "SheetMusicMSCX",
        "SheetMusicMusicXML",
        "SheetMusicMIDI",
        "SheetMusicPDF",                  // ← added
    ]
),
```

- [ ] **Step 4: Update `Sources/SheetMusic/SheetMusic.swift`**

Add at the top:

```swift
@_exported import SheetMusicPDF
```

Add inside `enum SheetMusic`:

```swift
/// Read a `.pdf` file (vector PDF from MuseScore 3.x/4.x) and parse
/// into a `Score`. CPU-bound; wrap with `Task { … }` if you need
/// to keep the main thread responsive.
public static func loadScore(
    pdfURL: URL,
    options: PDFImportOptions = .init()
) throws -> Score {
    try PDFImporter.parse(pdfURL: pdfURL, options: options)
}

/// Parse vector-PDF bytes into a `Score`.
public static func loadScore(
    pdfData: Data,
    options: PDFImportOptions = .init()
) throws -> Score {
    try PDFImporter.parse(pdfData: pdfData, options: options)
}
```

- [ ] **Step 5: Run umbrella tests + full suite**

`swift test` → all green; `swiftlint --quiet Sources Tests` → zero.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/SheetMusic/SheetMusic.swift \
        Tests/SheetMusicTests/SheetMusicFacadeTests.swift
git commit -m "feat(pdf): expose loadScore(pdfURL:) / (pdfData:) on umbrella"
```

---

## Task 17: Example app integration

**Goal:** Let the example app pick `.pdf` files from the picker and load via `SheetMusic.loadScore(pdfURL:)`.

**Files:**
- Modify: `Example/SheetMusicExample/ScoreFileType.swift` (add `.pdf`)
- Modify: `Example/SheetMusicExample/Shared/ScoreLoader.swift` (add `.pdf` branch)
- Modify: `Example/Info.plist` (add `com.adobe.pdf` to `CFBundleDocumentTypes`)
- Modify: `Example/SheetMusicExample/ContentView.swift` (no change required if `ScoreFileType.allUTTypes` already returns the list — confirm)

- [ ] **Step 1: Update `ScoreFileType.swift`**

```swift
enum ScoreFileType {
    case mscx
    case mscz
    case musicXML
    case mxl
    case midi
    case pdf            // ← added

    static var allUTTypes: [UTType] {
        var out: [UTType] = []
        if let t = UTType(filenameExtension: "mscx") { out.append(t) }
        if let t = UTType(filenameExtension: "mscz") { out.append(t) }
        if let t = UTType(filenameExtension: "musicxml") { out.append(t) }
        if let t = UTType(filenameExtension: "mxl") { out.append(t) }
        out.append(.midi)
        out.append(.pdf)        // ← added
        out.append(.xml)
        out.append(.zip)
        return out
    }

    static func detect(url: URL) -> ScoreFileType? {
        switch url.pathExtension.lowercased() {
        case "mscx":    return .mscx
        case "mscz":    return .mscz
        case "musicxml", "xml": return .musicXML
        case "mxl":     return .mxl
        case "mid", "midi": return .midi
        case "pdf":     return .pdf       // ← added
        default:        return nil
        }
    }
}
```

- [ ] **Step 2: Update `ScoreLoader.swift`**

Add branch in the `switch ScoreFileType.detect(url: url)`:

```swift
case .pdf:
    return try SheetMusic.loadScore(pdfURL: url)
```

- [ ] **Step 3: Update `Example/Info.plist`**

Add inside the `CFBundleDocumentTypes` array:

```xml
<dict>
    <key>CFBundleTypeName</key>
    <string>Portable Document Format (PDF)</string>
    <key>LSHandlerRank</key>
    <string>Default</string>
    <key>LSItemContentTypes</key>
    <array>
        <string>com.adobe.pdf</string>
    </array>
</dict>
```

- [ ] **Step 4: Regenerate the Xcode project + build the example**

```bash
cd Example && xcodegen
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Example/SheetMusicExample/ScoreFileType.swift \
        Example/SheetMusicExample/Shared/ScoreLoader.swift \
        Example/Info.plist
git commit -m "feat(example): open .pdf files from the picker"
```

---

## Final pass — full validation

- [ ] **Run the whole test suite from a clean state**

```bash
swift package clean
swift test
```

Expected: all suites green, including the existing 12 / 48-test set, plus the ~14 new PDF-importer suites.

- [ ] **Lint clean**

```bash
swiftlint --quiet Sources Tests
```

Expected: zero warnings.

- [ ] **Spot-check the spec coverage**

Walk through `docs/superpowers/specs/2026-05-03-pdf-import-design.md` §Scope and confirm each "in scope" bullet has a covering task; each "out of scope" bullet either is silently dropped (with diagnostic) or rejected (throws). If anything is missing, file a follow-up plan rather than expanding scope here.

- [ ] **Diagnostics smoke**

Manually run the example app on an actual MuseScore PDF (3.x and 4.x export of the same source) and visually confirm both render in the score view. Note any visible diagnostic-worthy issues for a follow-up issue.

- [ ] **Performance smoke (informational only)**

```bash
swift test --filter PDFImporterRoundTripTests -c release
```

Note the timing for the largest fixture in a follow-up note. The 1s-per-26-page target from the spec is loose; do not gate CI on it.

---

## Self-Review Checklist (run before declaring the plan ready)

1. **Spec coverage:** Each in-scope bullet from the spec is covered by Tasks 2–17. ✓
2. **Placeholders:** No "TBD"/"add appropriate error handling"/"similar to Task N" sneakouts. The Pitch/Rhythm/Voicing/Lyrics/Structure/Text tasks describe the algorithm explicitly with code skeletons; the executor still has to type the helper bodies, but the contract is fully specified.
3. **Type consistency:** `Score`, `Measure`, `Voice`, `Chord`, `Note`, `NoteDuration`, `KeySignature`, `TimeSignature`, `Tempo`, `Spanner`, `BarLine`, `Marker`, `Jump`, `RehearsalMark`, `Lyric`, `Clef` are all referenced by name; the executor must verify each spelling against `Sources/SheetMusicCore/Score/` before first use in each task. Internal types (`RawGlyph`, `Staff`, `ImportSystem`, `RhythmElement`, etc.) are defined once in `Internal.swift` (Tasks 1, 8) and referenced consistently downstream.
4. **Risk hot spots flagged:** Task 3 (CID/ToUnicode CMap) and Task 15 (round-trip golden) are the two places where surprises will emerge. Both have explicit fallback / iteration guidance.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-03-pdf-import.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
