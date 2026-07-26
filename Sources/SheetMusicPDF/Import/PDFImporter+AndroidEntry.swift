import Foundation
import SheetMusicCore

// Non-Apple (Android / Linux) front-end for `PDFImporter`. The implementations live in
// `PDFImporter+SwiftReaderEntry` (compiled on both platforms so the Apple test suite covers them); these
// are the platform-default spellings, gated so they do NOT collide with the Apple `CGPDFScanner` entry
// points in `PDFImporter+AppleEntry`.

#if !canImport(PDFKit)
    extension PDFImporter {
        public static func parse(pdfURL: URL, options: PDFImportOptions = .init()) throws -> Score {
            try parse(pdfData: Data(contentsOf: pdfURL), options: options)
        }

        public static func parse(pdfData: Data, options: PDFImportOptions = .init()) throws -> Score {
            try parseUsingSwiftReader(pdfData: pdfData, options: options)
        }

        public static func parseWithGeometry(
            pdfData: Data,
            options: PDFImportOptions = .init(),
        ) throws -> (score: Score, geometry: PDFScoreGeometry) {
            try parseWithGeometryUsingSwiftReader(pdfData: pdfData, options: options)
        }

        public static func parseWithGeometry(
            pdfURL: URL,
            options: PDFImportOptions = .init(),
        ) throws -> (score: Score, geometry: PDFScoreGeometry) {
            try parseWithGeometry(pdfData: Data(contentsOf: pdfURL), options: options)
        }
    }
#endif
