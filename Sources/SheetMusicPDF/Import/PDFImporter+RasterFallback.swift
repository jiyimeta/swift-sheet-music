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

    /// Lowest resolution the fallback will rasterize at: one pixel per point.
    /// Below this a staff line is thinner than a pixel and the classical-CV
    /// stage has nothing to measure.
    static let minimumRenderDPI: Double = 72

    /// `omrRenderDPI` is public, so any `Double` can arrive here, and
    /// `PDFPageRasterizer` clamps its pixel dimensions with `max(1, …)` — a
    /// zero, negative or NaN value would therefore rasterize a 1x1 page whose
    /// only symptom is a downstream "no staff detected on this page". Clamp
    /// once per document and name the value that was rejected.
    static func renderDPI(for options: PDFImportOptions) -> Double {
        guard options.omrRenderDPI.isFinite, options.omrRenderDPI >= minimumRenderDPI else {
            options.diagnostics?(PDFImportDiagnostic(
                severity: .warning, location: "document",
                message: "OMR: omrRenderDPI is \(options.omrRenderDPI), which cannot resolve a "
                    + "staff line; rasterizing at \(minimumRenderDPI) dpi instead",
            ))
            return minimumRenderDPI
        }
        return options.omrRenderDPI
    }

    /// Reads every page the vector walker found no music on.
    ///
    /// PER PAGE, so a document mixing a typeset title page with scanned music
    /// needs no decision from the caller. NOT containment, though: `buildScore`
    /// derives one document-wide ensemble staff count as a GCD over every
    /// page's staff count, so a raster page that miscounts can push that to
    /// `nil` and drop EVERY page — vector ones included — onto the per-page
    /// heuristic. Exercised by the mixed-document test.
    ///
    /// NON-THROWING BY DESIGN. Every failure below degrades to today's outcome
    /// FOR THAT PAGE — a warning and no content — because the fallback is an
    /// enhancement over pages the importer was going to contribute nothing for.
    /// Propagating one page's rasterization or detection failure would turn
    /// setting `omrTileClassifier` on a 200-page mixed document into a total
    /// parse failure over one page the vector path never read anyway.
    @discardableResult
    static func applyRasterFallback(
        to walked: inout WalkedContent,
        pageSizes: inout [Int: CGSize],
        document: PDFDocument,
        detector: any OMRGlyphDetecting,
        options: PDFImportOptions,
    ) -> Set<Int> {
        var rasterPages: Set<Int> = []
        let dpi = renderDPI(for: options)
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
            let result: (walked: WalkedContent, pageSize: CGSize)
            do {
                let bitmap = try PDFPageRasterizer.bitmap(page: page, dpi: dpi)
                result = try RasterFrontEnd.page(
                    bitmap: bitmap, pageIndex: index, detector: detector,
                    diagnostics: options.diagnostics,
                )
            } catch {
                // Same shape as the missing-`CGPDFPage` case above: say what
                // was lost, and leave the page as the vector walk left it.
                options.diagnostics?(PDFImportDiagnostic(
                    severity: .warning, location: "page \(index)",
                    message: "OMR: this page has no vector content and could not be read as an "
                        + "image either; nothing was imported from it",
                    context: "\(error)",
                ))
                continue
            }
            guard !result.walked.glyphs.isEmpty || !result.walked.paths.isEmpty else {
                // Nothing was read. Leave the page exactly as the vector walk
                // left it — in particular its mediaBox page size, which any
                // text the walker DID find on it is measured against.
                // `RasterFrontEnd`/`OMRGlyphDetector` have already said why.
                continue
            }
            rasterPages.insert(index)
            walked.glyphs += result.walked.glyphs
            walked.paths += result.walked.paths
            // The analysis's own frame, never the mediaBox: on a resampled page
            // they differ, and mixing them shifts paths relative to glyphs.
            pageSizes[index] = result.pageSize
        }
        return rasterPages
    }
}
