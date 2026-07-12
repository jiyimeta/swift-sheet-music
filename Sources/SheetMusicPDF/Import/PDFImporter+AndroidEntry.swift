#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// Non-Apple (Android / Linux) front-end for `PDFImporter`: parse via the
// Foundation-only pure-Swift reader (`walkWithSwiftReader`). Gated
// `#if !canImport(PDFKit)` so it does NOT collide with the Apple
// `PDFImporter+AppleEntry` `parse` on Apple, where PDFKit is available and the
// proven `CGPDFScanner` path is used instead.

#if !canImport(PDFKit)
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
            guard let walk = walkWithSwiftReader(pdfData: pdfData) else {
                throw SheetMusicError.malformedScore(
                    reason: "PDFImporter: not a valid PDF",
                )
            }
            return try buildScore(
                pageCount: walk.pageCount,
                walked: walk.content,
                pageSizes: walk.pageSizes,
                documentAttributes: walk.attributes,
                options: options,
            )
        }
    }
#endif
