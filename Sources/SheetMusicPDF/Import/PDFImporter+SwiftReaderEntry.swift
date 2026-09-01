#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// Entry points driven by the Foundation-only pure-Swift PDF reader. Compiled on BOTH platforms: Android
// uses them as its only front-end (see `PDFImporter+AndroidEntry`), and on Apple they stay reachable so
// the Apple test suite can exercise — and cross-check — the exact code Android runs.

/// Metadata-only view of a PDF: enough to name a library item without running the decode pipeline.
public struct PDFDocumentSummary: Hashable, Sendable {
    public let pageCount: Int
    /// The `/Title` document attribute, when the document carries a non-empty one.
    public let title: String?

    public init(pageCount: Int, title: String?) {
        self.pageCount = pageCount
        self.title = title
    }
}

extension PDFImporter {
    /// Page count + `/Title`, without decoding any notation. `nil` when the bytes are not a parseable PDF
    /// or the document has no pages.
    public static func summaryUsingSwiftReader(pdfData: Data) -> PDFDocumentSummary? {
        guard let doc = PDFReaderDocument(data: pdfData), doc.pageCount > 0 else { return nil }
        let rawTitle = doc.documentAttributes?["Title"] as? String
        let title = rawTitle.flatMap { $0.isEmpty ? nil : $0 }
        return PDFDocumentSummary(pageCount: doc.pageCount, title: title)
    }

    /// Parse via the pure-Swift reader. Throws `SheetMusicError.malformedScore` when the bytes are not a
    /// parseable PDF.
    public static func parseUsingSwiftReader(
        pdfData: Data,
        options: PDFImportOptions = .init(),
    ) throws -> Score {
        warnEntryPointDoesNotRasterize("parseUsingSwiftReader", options: options)
        let walk = try walkOrThrow(pdfData: pdfData)
        return try buildScore(
            pageCount: walk.pageCount,
            walked: walk.content,
            pageSizes: walk.pageSizes,
            documentAttributes: walk.attributes,
            options: options,
            // This entry point never rasterizes (see the warning above), so
            // no page is detector-read and the clef consensus stays out.
            rasterPages: [],
        )
    }

    /// Parse via the pure-Swift reader and also return the geometry side-car. The collector only observes;
    /// the `Score` is identical to `parseUsingSwiftReader`'s.
    public static func parseWithGeometryUsingSwiftReader(
        pdfData: Data,
        options: PDFImportOptions = .init(),
    ) throws -> (score: Score, geometry: PDFScoreGeometry) {
        warnEntryPointDoesNotRasterize("parseWithGeometryUsingSwiftReader", options: options)
        let walk = try walkOrThrow(pdfData: pdfData)
        let collector = PDFGeometryCollector()
        let score = try buildScore(
            pageCount: walk.pageCount,
            walked: walk.content,
            pageSizes: walk.pageSizes,
            documentAttributes: walk.attributes,
            options: options,
            geometry: collector,
            // This entry point never rasterizes (see the warning above), so
            // no page is detector-read and the clef consensus stays out.
            rasterPages: [],
        )
        return (score, collector.finalize())
    }

    private static func walkOrThrow(
        pdfData: Data,
    ) throws -> (content: WalkedContent, pageCount: Int, pageSizes: [Int: CGSize], attributes: [String: Any]?) {
        guard !pdfData.isEmpty else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "pdf.data.empty",
                message: "PDFImporter: empty data",
            ))
        }
        guard let walk = walkWithSwiftReader(pdfData: pdfData) else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "pdf.data.invalidPDF",
                message: "PDFImporter: not a valid PDF",
            ))
        }
        return walk
    }
}
