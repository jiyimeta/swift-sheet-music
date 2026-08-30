import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

// The raster fallback's insertion point in the Apple front-end: pages the
// vector walker found no music on are rasterized and read by the OMR
// detector, then merged into the same `WalkedContent` / page-size values
// `buildScore` already consumes.
//
// EXCLUDED from the Android build (see Package.swift) for the same reason as
// `PDFImporter+AppleEntry`: it is driven by PDFKit / CoreGraphics, and
// `PDFPageRasterizer` — a PDF page → pixels — has no Android shape yet.

extension PDFImporter {
    /// The detector this parse should use, or `nil` for "no raster fallback".
    ///
    /// `nil` is the whole contract of the default options: the caller of this
    /// function must not rasterize, must not analyze, and must not walk the
    /// pages a second time when it gets `nil` back.
    static func rasterDetector(for options: PDFImportOptions) throws -> (any OMRGlyphDetecting)? {
        if let injected = options.omrDetector { return injected }
        guard let classifier = options.omrTileClassifier else { return nil }
        return try OMRGlyphDetector(classifier: classifier)
    }

    /// Reads every page the vector walker found no music on.
    ///
    /// PER PAGE, so a document mixing a typeset title page with scanned music
    /// needs no decision from the caller. NOT containment, though: `buildScore`
    /// derives one document-wide ensemble staff count as a GCD over every
    /// page's staff count, so a raster page that miscounts can push that to
    /// `nil` and drop EVERY page — vector ones included — onto the per-page
    /// heuristic. Exercised by the mixed-document test.
    static func applyRasterFallback(
        to walked: inout WalkedContent,
        pageSizes: inout [Int: CGSize],
        document: PDFDocument,
        detector: any OMRGlyphDetecting,
        options: PDFImportOptions,
    ) throws {
        for index in 0 ..< document.pageCount {
            // Music, specifically: `texts` are deliberately NOT consulted.
            // A scan often carries an invisible OCR text layer, and counting
            // that as content would make the one document class this whole
            // path exists for the one it declines to read.
            let hasContent = walked.glyphs.contains { $0.geometry.pageIndex == index }
                || walked.paths.contains { $0.pageIndex == index }
            guard !hasContent else { continue }
            guard let page = document.page(at: index)?.pageRef else {
                options.diagnostics?(PDFImportDiagnostic(
                    severity: .warning, location: "page \(index)",
                    message: "OMR: this page has no vector content and cannot be rasterized "
                        + "either — PDFKit did not hand back a CGPDFPage for it",
                ))
                continue
            }
            let bitmap = try PDFPageRasterizer.bitmap(page: page, dpi: options.omrRenderDPI)
            let result = try RasterFrontEnd.page(
                bitmap: bitmap, pageIndex: index, detector: detector,
                diagnostics: options.diagnostics,
            )
            guard !result.walked.glyphs.isEmpty || !result.walked.paths.isEmpty else {
                // Nothing was read. Leave the page exactly as the vector walk
                // left it — in particular its mediaBox page size, which any
                // text the walker DID find on it is measured against.
                // `RasterFrontEnd`/`OMRGlyphDetector` have already said why.
                continue
            }
            walked.glyphs += result.walked.glyphs
            walked.paths += result.walked.paths
            // The analysis's own frame, never the mediaBox: on a resampled page
            // they differ, and mixing them shifts paths relative to glyphs.
            pageSizes[index] = result.pageSize
        }
    }
}
