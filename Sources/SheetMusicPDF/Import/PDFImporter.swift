import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

/// Internal façade for parsing vector PDFs (MuseScore 3.x/4.x exports)
/// into `Score`. Currently HELD INTERNAL while the importer is being
/// reworked — see `docs/superpowers/plans/2026-05-03-pdf-import-paused.md`
/// for resume instructions and the Phase-2 roadmap. Mirrors `MidiImporter`
/// shape (caseless enum, sync only).
enum PDFImporter {
    static func parse(
        pdfURL: URL,
        options: PDFImportOptions = .init(),
    ) throws -> Score {
        let data = try Data(contentsOf: pdfURL)
        return try parse(pdfData: data, options: options)
    }

    static func parse(
        pdfData: Data,
        options: PDFImportOptions = .init(),
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
        options: PDFImportOptions,
    ) throws -> Score {
        let walked = try ContentStreamWalker(document: document).walk()
        guard !walked.glyphs.isEmpty || !walked.texts.isEmpty || !walked.paths.isEmpty else {
            throw SheetMusicError.malformedScore(
                reason: "PDFImporter: no glyphs/paths found",
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
                pageIndex: page,
            )
            let systems = layoutSystems(
                staves: pageStaves,
                paths: walked.paths,
                classified: classified,
                pageIndex: page,
            )
            systemsAllPages.append(contentsOf: systems)
        }
        guard !systemsAllPages.isEmpty else {
            throw SheetMusicError.malformedScore(
                reason: "PDFImporter: no staff detected on any page",
            )
        }

        // Pair tie arcs to noteheads up front (geometry only — two
        // tied noteheads share a staff line, so same y ⇒ same pitch).
        // The result is a set of notehead identities carrying a forward
        // or back tie, consulted while assembling each measure.
        let tieMarks = detectTies(curves: walked.curves, noteheads: classified)

        // Grace-note size threshold: MuseScore renders grace / cue
        // noteheads at ~70% of the full notehead size (via a scaled
        // text / current-transformation matrix; the Tf operand is
        // uniform). Take the score-wide median full-notehead rendered
        // size and call anything below 85% of it a grace. 0 disables the
        // pass (no small noteheads found).
        let graceSizeThreshold = graceNoteSizeThreshold(classified: classified)

        return assembleScore(
            document: document,
            systems: systemsAllPages,
            texts: walked.texts,
            classified: classified,
            paths: walked.paths,
            tieMarks: tieMarks,
            graceSizeThreshold: graceSizeThreshold,
            options: options,
        )
    }

    /// Grace-note rendered-size threshold from the score-wide notehead
    /// population. Returns `0.85 × median(noteheadRenderedSize)`, or 0 when
    /// fewer than a handful of noteheads exist (nothing to compare against)
    /// or when no glyph carries a usable `renderedSize`. A clean bimodal
    /// split is expected (full ≈ 100%, grace ≈ 70%), so the exact cut point
    /// between them is not sensitive.
    static func graceNoteSizeThreshold(classified: [ClassifiedGlyph]) -> CGFloat {
        let sizes = classified
            .filter { isNotehead($0.semantic) && $0.raw.renderedSize > 0 }
            .map(\.raw.renderedSize)
            .sorted()
        guard sizes.count >= 8 else { return 0 }
        let median = sizes[sizes.count / 2]
        guard median > 0 else { return 0 }
        return median * 0.85
    }

    /// Emit one `.info` diagnostic per `.unknown` SMuFL codepoint.
    static func emitUnknownGlyphDiagnostics(
        _ classified: [ClassifiedGlyph],
        options: PDFImportOptions,
    ) {
        guard let cb = options.diagnostics else { return }
        for g in classified {
            if case let .unknown(cp) = g.semantic {
                cb(PDFImportDiagnostic(
                    severity: .info,
                    location: "page \(g.raw.pageIndex)",
                    message: "Unknown SMuFL codepoint U+\(String(cp, radix: 16, uppercase: true))",
                ))
            }
        }
    }
}
