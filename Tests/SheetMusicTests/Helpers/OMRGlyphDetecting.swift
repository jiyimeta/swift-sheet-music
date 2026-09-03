#if !os(Android) && !os(WASI)
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// A detector that answers from glyphs already computed for a render,
    /// so a sweep that needs the same page's detections twice — once for
    /// the seam metrics, once inside `OMRHybridFrontEnd.compose` for the
    /// score-level comparison — runs the real detector once.
    ///
    /// Measured before this existed: 111 page-detections for 69 pages.
    /// Detection was the sweep's whole cost, so the second pass was a
    /// straight doubling of it.
    ///
    /// Deliberately a frozen dictionary rather than a cache that fills
    /// itself: a cache keyed on the page index alone would answer a
    /// LATER render's page 0 with an earlier render's glyphs if anyone
    /// forgot to clear it, and nothing downstream could tell. This is
    /// built per render from that render's own results and **throws**
    /// for a page it was not given.
    ///
    /// Conforms to `SheetMusicPDF`'s internal `OMRGlyphDetecting` (Task 5)
    /// via `@testable import` — this file used to declare its own protocol
    /// of the same name, which shadowed the Sources one inside `Tests/`;
    /// that declaration is gone now that the two would otherwise mean two
    /// different things under the same name.
    struct OMRPrecomputedDetector: OMRGlyphDetecting {
        let byPageIndex: [Int: [ClassifiedGlyph]]

        func glyphs(
            pageIndex: Int, analysis _: RasterPageAnalysis,
            diagnostics _: (@Sendable (PDFImportDiagnostic) -> Void)?,
        ) throws -> [ClassifiedGlyph] {
            guard let glyphs = byPageIndex[pageIndex] else {
                throw SheetMusicError.malformedScore(ScoreFault(
                    code: "omr.detector",
                    message: "OMRPrecomputedDetector: no precomputed glyphs for page "
                        + "\(pageIndex) — it holds \(byPageIndex.keys.sorted())",
                ))
            }
            return glyphs
        }
    }
#endif
