#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import PDFKit
import SheetMusicCore

// Apple front-end for `PDFImporter`: the `PDFDocument` / `CGPDFScanner` path.
// EXCLUDED from the Android target (see Package.swift) — Android parses via the
// Foundation-only `PDFImporter+AndroidEntry` (the pure-Swift reader). Both feed
// the same Foundation-only `buildScore`.

extension PDFImporter {
    public static func parse(
        pdfURL: URL,
        options: PDFImportOptions = .init(),
    ) throws -> Score {
        let data = try Data(contentsOf: pdfURL)
        return try parse(pdfData: data, options: options)
    }

    public static func parse(
        pdfData: Data,
        options: PDFImportOptions = .init(),
    ) throws -> Score {
        let document = try openDocument(pdfData)
        let walk = try walkDocument(
            document, enableShapeMatching: options.enableShapeMatching,
            disableSMuFLCodepointTier: options.disableSMuFLCodepointTier,
            anchorMusicGlyphsToPUARange: options.anchorMusicGlyphsToPUARange,
            bypassMusicFontGate: options.bypassMusicFontGateForTesting,
            musicFontGateBound: options.musicFontGateBound,
            musicFontGateFraction: options.musicFontGateFraction,
            shapeAcceptanceThreshold: options.shapeAcceptanceThreshold,
        )
        var content = walk.content
        var pageSizes = walk.pageSizes
        // `nil` means today's behavior LITERALLY: with no classifier and no
        // injected detector nothing below runs — no rasterization, no page
        // analysis, not even a second pass over the pages. That is what makes
        // the byte-identical vector corpus gate meaningful.
        if let detector = try rasterDetector(for: options) {
            applyRasterFallback(
                to: &content, pageSizes: &pageSizes,
                document: document, detector: detector, options: options,
            )
        }
        return try buildScore(
            pageCount: document.pageCount,
            walked: content,
            pageSizes: pageSizes,
            documentAttributes: walk.attributes,
            options: options,
        )
    }

    /// Parse `pdfData` and also return the geometry side-car.
    public static func parseWithGeometry(
        pdfData: Data,
        options: PDFImportOptions = .init(),
    ) throws -> (score: Score, geometry: PDFScoreGeometry) {
        warnEntryPointDoesNotRasterize("parseWithGeometry", options: options)
        let document = try openDocument(pdfData)
        let collector = PDFGeometryCollector()
        let walk = try walkDocument(
            document, enableShapeMatching: options.enableShapeMatching,
            disableSMuFLCodepointTier: options.disableSMuFLCodepointTier,
            anchorMusicGlyphsToPUARange: options.anchorMusicGlyphsToPUARange,
            bypassMusicFontGate: options.bypassMusicFontGateForTesting,
            musicFontGateBound: options.musicFontGateBound,
            musicFontGateFraction: options.musicFontGateFraction,
            shapeAcceptanceThreshold: options.shapeAcceptanceThreshold,
        )
        let score = try buildScore(
            pageCount: document.pageCount,
            walked: walk.content,
            pageSizes: walk.pageSizes,
            documentAttributes: walk.attributes,
            options: options,
            geometry: collector,
        )
        return (score, collector.finalize())
    }

    /// Parse the PDF at `pdfURL` and also return the geometry side-car.
    public static func parseWithGeometry(
        pdfURL: URL,
        options: PDFImportOptions = .init(),
    ) throws -> (score: Score, geometry: PDFScoreGeometry) {
        let data = try Data(contentsOf: pdfURL)
        return try parseWithGeometry(pdfData: data, options: options)
    }
}

extension PDFImporter {
    static func openDocument(_ pdfData: Data) throws -> PDFDocument {
        guard !pdfData.isEmpty else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "pdf.data.empty",
                message: "PDFImporter: empty data",
            ))
        }
        guard let document = PDFDocument(data: pdfData) else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "pdf.data.invalidPDF",
                message: "PDFImporter: not a valid PDF",
            ))
        }
        guard document.pageCount > 0 else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "pdf.pages.zero",
                message: "PDFImporter: zero pages",
            ))
        }
        return document
    }

    /// Apple front-end: walk the document (`CGPDFScanner`) and collect the
    /// per-page mediaBox sizes + document attributes. The Foundation-only
    /// `buildScore` consumes these VALUES, never the `PDFDocument`, so the
    /// decode pipeline stays platform-neutral (Android supplies the same
    /// `WalkedContent` + page sizes from its own PDF reader).
    static func walkDocument(
        _ document: PDFDocument,
        enableShapeMatching: Bool = false,
        disableSMuFLCodepointTier: Bool = false,
        anchorMusicGlyphsToPUARange: Bool = false,
        bypassMusicFontGate: Bool = false,
        musicFontGateBound: Double = GlyphClassifier.defaultMusicFontGateBound,
        musicFontGateFraction: Double = GlyphClassifier.defaultMusicFontGateFraction,
        shapeAcceptanceThreshold: Double = GlyphClassifier.defaultShapeAcceptanceThreshold,
    ) throws -> (content: WalkedContent, pageSizes: [Int: CGSize], attributes: [String: Any]?) {
        let content = try ContentStreamWalker(
            document: document, enableShapeMatching: enableShapeMatching,
            disableSMuFLCodepointTier: disableSMuFLCodepointTier,
            anchorMusicToPUARange: anchorMusicGlyphsToPUARange,
            bypassMusicFontGate: bypassMusicFontGate,
            musicFontGateBound: musicFontGateBound,
            musicFontGateFraction: musicFontGateFraction,
            shapeAcceptanceThreshold: shapeAcceptanceThreshold,
        ).walk()
        var pageSizes: [Int: CGSize] = [:]
        for p in 0 ..< document.pageCount {
            if let page = document.page(at: p) {
                pageSizes[p] = page.bounds(for: .mediaBox).size
            }
        }
        return (content, pageSizes, document.documentAttributes as? [String: Any])
    }
}
