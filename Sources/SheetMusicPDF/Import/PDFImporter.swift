import Foundation
import PDFKit
import SheetMusicCore

/// Public façade for parsing vector PDFs (MuseScore 3.x/4.x exports)
/// into `Score`. Mirrors `MidiImporter` — caseless enum, sync only.
public enum PDFImporter {
    public static func parse(
        pdfURL: URL,
        options: PDFImportOptions = .init()
    ) throws -> Score {
        let data = try Data(contentsOf: pdfURL)
        return try parse(pdfData: data, options: options)
    }

    public static func parse(
        pdfData: Data,
        options: PDFImportOptions = .init()
    ) throws -> Score {
        guard !pdfData.isEmpty else {
            throw SheetMusicError.malformedScore(reason: "PDFImporter: empty data")
        }
        guard let document = PDFDocument(data: pdfData) else {
            throw SheetMusicError.malformedScore(reason: "PDFImporter: not a valid PDF")
        }
        guard document.pageCount > 0 else {
            throw SheetMusicError.malformedScore(reason: "PDFImporter: zero pages")
        }
        // Pipeline wired in later tasks. Until Task 13 lands, throw so
        // the caller is not handed an empty Score silently.
        throw SheetMusicError.malformedScore(
            reason: "PDFImporter: pipeline not yet wired (\(document.pageCount) pages)"
        )
    }
}
