#if !os(Android)
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

            // As of this writing, glyph order structurally CANNOT reach
            // `detectStaves`'s output: every consumer of `classified` —
            // `staffNoteheads.contains` in the stem veto
            // (PDFImporter+StaffLines.swift:326-329) and `content.contains`
            // in `segmentRegionHasContent`
            // (PDFImporter+StaffLinesNarrow.swift:177-182) — is a pure
            // existential predicate (an OR-reduction with no accumulation,
            // no `first`/`min` tie-break). `contains(where:)` has the same
            // truth table for an `Array` or a `Set` regardless of order or
            // duplication, so swapping either container for a `Set` would
            // NOT be caught here.
            //
            // What this assertion DOES guard against: a FUTURE change that
            // makes glyph consumption order-SENSITIVE — e.g. accumulating
            // `classified` into an array whose order reaches the output, or
            // replacing a `contains` with `first(where:)` / `min(by:)`
            // whose tie-break depends on input order. If that happens, this
            // reversed-order comparison starts failing.
            //
            // The `!isEmpty` guard stays regardless: without it, a future
            // regression that broke barline detection entirely (dropping
            // the fixture's one candidate) would still satisfy `[] == []`
            // and this test would advertise a guarantee — on the ONE output
            // glyph data touches at all — that it no longer provides.
            let aBarlines = (a.first?.barlineCandidates ?? [])
                .sorted { $0.rect.minX < $1.rect.minX }
            let bBarlines = (b.first?.barlineCandidates ?? [])
                .sorted { $0.rect.minX < $1.rect.minX }
            #expect(!aBarlines.isEmpty)
            #expect(aBarlines == bBarlines)
        }
    }
#endif
