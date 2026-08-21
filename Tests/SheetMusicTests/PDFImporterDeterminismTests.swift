#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// The importer must not depend on Dictionary / Set iteration order.
    /// Swift randomizes hash seeds per process, but within one process a
    /// repeated parse of identical input must be bit-stable — and any
    /// order-dependent pass shows up as instability across shuffled input
    /// that is geometrically identical.
    @MainActor struct PDFImporterDeterminismTests {
        private func glyph(
            x: CGFloat, y: CGFloat, _ semantic: SMuFLSemantic,
        ) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: semantic,
            )
        }

        @Test func staffDetectionIsOrderIndependent() {
            let staffLines = (0 ..< 5).map { i in
                PathSegment(
                    kind: .horizontal,
                    rect: CGRect(
                        x: 100,
                        y: 100 + CGFloat(i) * 10,
                        width: 400,
                        height: 0,
                    ),
                    lineWidth: 0.5, pageIndex: 0,
                )
            }
            // A genuine barline candidate: a vertical spanning well past both
            // outer staff lines (y 100...140), sitting at x=400 — far enough
            // (>1.3 spatium) from every notehead below that `barlineCandidates`
            // does not veto it as a note stem. Non-empty output here is
            // required so the assertions below aren't vacuously comparing
            // `[] == []` — see the comment there for what this does and does
            // NOT demonstrate.
            let barline = PathSegment(
                kind: .vertical,
                rect: CGRect(x: 400, y: 95, width: 0, height: 50),
                lineWidth: 1.0, pageIndex: 0,
            )
            let paths = staffLines + [barline]
            let glyphs = [
                glyph(x: 150, y: 120, .noteheadBlack),
                glyph(x: 200, y: 130, .noteheadBlack),
                glyph(x: 250, y: 110, .noteheadBlack),
            ]
            let a = PDFImporter.detectStaves(
                paths: paths, classified: glyphs, pageIndex: 0,
            )
            let b = PDFImporter.detectStaves(
                paths: paths.reversed(), classified: glyphs.reversed(),
                pageIndex: 0,
            )
            #expect(a.count == b.count)
            #expect(a.first?.yLines == b.first?.yLines)
            #expect(a.first?.xRange == b.first?.xRange)

            // `detectStaves` has THREE consumers of `classified`, and they do
            // NOT all behave the same way:
            //   1. `staffNoteheads.contains { … }` in the stem veto
            //      (PDFImporter+StaffLines.swift:326-329) — existential,
            //      order- and duplication-invariant.
            //   2. `content.contains { … }` in `segmentRegionHasContent`
            //      (PDFImporter+StaffLinesNarrow.swift:177-182) — same shape,
            //      also invariant.
            //   3. `appendGlyphDetectedStaves` (PDFImporter+StaffLines.swift
            //      :185-217), called directly from `detectStaves` with the
            //      RAW `classified` array — an ORDERED ACCUMULATION with
            //      early-skip: it walks `.staff5Lines` glyphs in array order
            //      and appends a synthesized `Staff` only if its y-band does
            //      not already overlap one already appended. Which glyph
            //      "wins" an overlapping pair depends on iteration order, and
            //      that result propagates into `yLines` / `xRange` and
            //      downstream `barlineCandidates`. This is genuinely
            //      order-SENSITIVE, not invariant — do not read the first two
            //      call sites as representative of all three.
            //
            // So glyph order CAN reach `detectStaves`'s output in general.
            // Determinism holds today NOT because the code is order-
            // invariant, but because `WalkedContent.glyphs` is itself built
            // deterministically: `ContentStreamWalker.walk()`
            // (PDFImporter+ContentStream.swift:19-34) appends in page order,
            // then content-stream order within a page — no `Dictionary`, no
            // `Set`, no sort anywhere upstream. The input ordering is
            // load-bearing, which is exactly why the front-end contract
            // (`PDFImporter+Interpreter.swift`'s `WalkedContent` doc comment)
            // states the "no Dictionary / Set iteration order" rule as a
            // hard requirement rather than an implementation detail.
            //
            // THIS FIXTURE covers only paths 1 and 2: it has no
            // `.staff5Lines` glyphs, so `appendGlyphDetectedStaves`'s loop
            // `continue`s immediately every iteration and never exercises
            // its order-sensitive accumulation. The reversed-order
            // comparison below therefore does NOT demonstrate that
            // `detectStaves` is order-independent in general — only that
            // paths 1 and 2 are, for this fixture's shape. A future fixture
            // (or test) that adds overlapping `.staff5Lines` glyphs would be
            // needed to pin path 3's behavior.
            //
            // The `!isEmpty` guard stays regardless of the above: without
            // it, a future regression that broke barline detection entirely
            // (dropping the fixture's one candidate) would still satisfy
            // `[] == []`, and this test would advertise a guarantee it no
            // longer provides even for the two paths it does cover.
            let aBarlines = (a.first?.barlineCandidates ?? [])
                .sorted { $0.rect.minX < $1.rect.minX }
            let bBarlines = (b.first?.barlineCandidates ?? [])
                .sorted { $0.rect.minX < $1.rect.minX }
            #expect(!aBarlines.isEmpty)
            #expect(aBarlines == bBarlines)
        }
    }
#endif
