#if !os(Android)
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// The seam a raster front-end's symbol classifier implements: given
    /// one page's labels (for `page.page.index` / page framing) and its
    /// raster analysis, produce the classified glyphs a `buildScore` call
    /// needs. `OMROracleFrontEnd` fills this role with ground-truth
    /// labels; `OMRDetectorFrontEnd` fills it with the trained CNN.
    protocol OMRGlyphDetecting {
        func glyphs(page: OMRPageLabels, analysis: RasterPageAnalysis) throws -> [ClassifiedGlyph]
    }

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
    struct OMRPrecomputedDetector: OMRGlyphDetecting {
        let byPageIndex: [Int: [ClassifiedGlyph]]

        func glyphs(page: OMRPageLabels, analysis _: RasterPageAnalysis) throws -> [ClassifiedGlyph] {
            guard let glyphs = byPageIndex[page.page.index] else {
                throw SheetMusicError.malformedScore(
                    reason: "OMRPrecomputedDetector: no precomputed glyphs for page "
                        + "\(page.page.index) — it holds \(byPageIndex.keys.sorted())",
                )
            }
            return glyphs
        }
    }
#endif
