import Foundation

/// The seam a raster front-end's symbol classifier fills: one page's raster
/// analysis in, classified glyphs in PDF page points out.
///
/// INTERNAL, and it must stay that way: `RasterPageAnalysis` and
/// `ClassifiedGlyph` are importer internals, and a public protocol mentioning
/// them would drag both into the package's API permanently. The public
/// extension point is `OMRTileClassifier`, whose types this module owns.
protocol OMRGlyphDetecting: Sendable {
    func glyphs(
        pageIndex: Int, analysis: RasterPageAnalysis,
        diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?,
    ) throws -> [ClassifiedGlyph]
}
