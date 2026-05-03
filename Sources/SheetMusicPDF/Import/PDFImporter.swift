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
        return try buildScore(document: document, options: options)
    }

    /// Run stages 1-12 of the pipeline against `document` and assemble
    /// the resulting `Score`. Throws when the document yields no glyphs
    /// / paths, or when no staff can be detected on any page.
    static func buildScore(
        document: PDFDocument,
        options: PDFImportOptions
    ) throws -> Score {
        let walked = try ContentStreamWalker(document: document).walk()
        guard !walked.glyphs.isEmpty || !walked.texts.isEmpty || !walked.paths.isEmpty else {
            throw SheetMusicError.malformedScore(
                reason: "PDFImporter: no glyphs/paths found"
            )
        }
        let classified = walked.glyphs.map {
            ClassifiedGlyph(raw: $0, semantic: smuflSemantic(codepoint: $0.codepoint))
        }
        emitUnknownGlyphDiagnostics(classified, options: options)

        var systemsAllPages: [ImportSystem] = []
        for page in 0 ..< document.pageCount {
            let pagePaths = walked.paths.filter { $0.pageIndex == page }
            let pageClassified = classified.filter { $0.raw.pageIndex == page }
            let pageStaves = detectStaves(
                paths: pagePaths,
                classified: pageClassified,
                pageIndex: page
            )
            let systems = layoutSystems(
                staves: pageStaves,
                paths: walked.paths,
                classified: classified,
                pageIndex: page
            )
            systemsAllPages.append(contentsOf: systems)
        }
        guard !systemsAllPages.isEmpty else {
            throw SheetMusicError.malformedScore(
                reason: "PDFImporter: no staff detected on any page"
            )
        }

        return assembleScore(
            document: document,
            systems: systemsAllPages,
            texts: walked.texts,
            classified: classified,
            options: options
        )
    }

    /// Emit one `.info` diagnostic per `.unknown` SMuFL codepoint.
    static func emitUnknownGlyphDiagnostics(
        _ classified: [ClassifiedGlyph],
        options: PDFImportOptions
    ) {
        guard let cb = options.diagnostics else { return }
        for g in classified {
            if case let .unknown(cp) = g.semantic {
                cb(PDFImportDiagnostic(
                    severity: .info,
                    location: "page \(g.raw.pageIndex)",
                    message: "Unknown SMuFL codepoint U+\(String(cp, radix: 16, uppercase: true))"
                ))
            }
        }
    }
}
