#if !os(Android)
    @testable import SheetMusicPDF

    /// The seam a raster front-end's symbol classifier implements: given
    /// one page's labels (for `page.page.index` / page framing) and its
    /// raster analysis, produce the classified glyphs a `buildScore` call
    /// needs. `OMROracleFrontEnd` fills this role with ground-truth
    /// labels; `OMRDetectorFrontEnd` fills it with the trained CNN.
    protocol OMRGlyphDetecting {
        func glyphs(page: OMRPageLabels, analysis: RasterPageAnalysis) throws -> [ClassifiedGlyph]
    }
#endif
