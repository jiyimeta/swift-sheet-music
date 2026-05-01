import CoreGraphics
import SheetMusic
import SheetMusicPDF
import SheetMusicUI

/// Pre-computed PDF preview layout. Bundles the laid-out
/// `LayoutDocument`, the per-page system batches, and the
/// resolved `EngravingPage` so callers don't have to invoke
/// `PDFExporter.resolve` twice (once for the body, once inside
/// the `.task` that lays out the document).
struct PDFPreviewLayout {
    let doc: LayoutDocument
    let pages: [PDFExporter.PageBatch]
    let page: EngravingPage

    /// Lay out `score` for an on-screen PDF preview using the same
    /// geometry the share/save export will produce, so the preview
    /// is a truthful proxy for the exported PDF.
    @MainActor
    static func build(score: Score) -> PDFPreviewLayout {
        let resolved = PDFExporter.resolve(
            options: PDFExporter.Options(), score: score
        )
        let opts = ScoreViewOptions(
            staffSize: resolved.staffSize,
            systemGap: 16,
            wrapToViewWidth: true
        )
        let availableWidth = max(
            resolved.staffSize * 4,
            resolved.page.size.width
                - resolved.page.oddMargins.leading
                - resolved.page.oddMargins.trailing
        )
        let doc = LayoutEngine.layout(
            score: score, options: opts,
            availableWidth: availableWidth
        )
        let pages = PDFExporter.paginate(
            systems: doc.systems, page: resolved.page
        )
        return PDFPreviewLayout(
            doc: doc, pages: pages, page: resolved.page
        )
    }
}
