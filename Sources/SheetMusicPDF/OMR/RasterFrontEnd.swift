#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// One rasterized page → the `buildScore` inputs for it.
///
/// This is the product path. `OMRHybridFrontEnd` in the tests keeps its
/// bisect modes as substitutions around this call, so there is exactly one
/// implementation and one set of numbers.
enum RasterFrontEnd {
    static func page(
        bitmap: GrayBitmap, pageIndex: Int, detector: any OMRGlyphDetecting,
        diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?,
    ) throws -> (walked: WalkedContent, pageSize: CGSize) {
        // keepDeskewed: the detector consumes the deskewed grayscale. It is
        // opt-in because a page is ~18MB and holding one per page multiplies a
        // sweep's peak RSS by the page count — so the analysis dies here, with
        // this function's frame.
        let analysis = RasterPage.analyze(bitmap, pageIndex: pageIndex, keepDeskewed: true)
        return try assembled(
            analysis: analysis, pageIndex: pageIndex, detector: detector,
            diagnostics: diagnostics,
        )
    }

    /// The assembly step alone, for a caller that already holds the raster
    /// analysis.
    ///
    /// The eval harness computes `RasterPageAnalysis` once per page (with
    /// `keepDeskewed: true`) because its bisect modes need it too, and
    /// re-running `RasterPage.analyze` here would pay for a second
    /// classical-CV pass over the same bitmap for no reason — this is the
    /// seam `.full` and `.detectorGlyphs` route through so their numbers
    /// and the product path's stay one computation, not two that happen to
    /// agree today.
    static func assembled(
        analysis: RasterPageAnalysis, pageIndex: Int, detector: any OMRGlyphDetecting,
        diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?,
    ) throws -> (walked: WalkedContent, pageSize: CGSize) {
        let glyphs = try detector.glyphs(
            pageIndex: pageIndex, analysis: analysis, diagnostics: diagnostics,
        )
        // texts and curves stay empty: no OCR, no curve detector. A raster page
        // therefore carries no title, lyrics, tempo text or ties.
        let walked = WalkedContent(glyphs: glyphs, texts: [], paths: analysis.paths, curves: [])
        return (walked, analysis.pageSizePt)
    }
}
