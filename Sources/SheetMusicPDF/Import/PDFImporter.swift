import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

/// Façade for parsing vector PDFs (MuseScore 3.x/4.x exports) into `Score`.
/// Mirrors `MidiImporter` shape (caseless enum, sync only).
///
/// `parse` returns the `Score` alone. `parseWithGeometry` additionally
/// returns a `PDFScoreGeometry` side-car linking each Score element to its
/// rectangle in the original PDF — used to draw a playback cursor on, and
/// hit-test taps against, the displayed source PDF. The geometry collector
/// is allocated only on the `parseWithGeometry` path; `parse` runs the same
/// pipeline with no geometry overhead.
public enum PDFImporter {
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
        return try buildScore(document: document, options: options)
    }

    /// Parse `pdfData` and also return the geometry side-car.
    public static func parseWithGeometry(
        pdfData: Data,
        options: PDFImportOptions = .init(),
    ) throws -> (score: Score, geometry: PDFScoreGeometry) {
        let document = try openDocument(pdfData)
        let collector = PDFGeometryCollector()
        let score = try buildScore(
            document: document, options: options, geometry: collector,
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

    private static func openDocument(_ pdfData: Data) throws -> PDFDocument {
        guard !pdfData.isEmpty else {
            throw SheetMusicError.malformedScore(reason: "PDFImporter: empty data")
        }
        guard let document = PDFDocument(data: pdfData) else {
            throw SheetMusicError.malformedScore(reason: "PDFImporter: not a valid PDF")
        }
        guard document.pageCount > 0 else {
            throw SheetMusicError.malformedScore(reason: "PDFImporter: zero pages")
        }
        return document
    }

    /// Run stages 1-12 of the pipeline against `document` and assemble
    /// the resulting `Score`. Throws when the document yields no glyphs
    /// / paths, or when no staff can be detected on any page.
    static func buildScore(
        document: PDFDocument,
        options: PDFImportOptions,
        geometry: PDFGeometryCollector? = nil,
    ) throws -> Score {
        // Page sizes (mediaBox) for the geometry side-car's system rects and
        // display flips. Only computed on the geometry-capture path.
        recordPageSizes(document: document, geometry: geometry)
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

        // Detect every page's staves first so the system clusterer can use a
        // DOCUMENT-WIDE ensemble size (staves per system). MuseScore stacks
        // several equal-sized systems per page; the per-page gap heuristic
        // can't tell a wide within-system gap from a true between-system gap
        // in isolation, but the ensemble size is a stable structural prior
        // across the whole document. See `ensembleStaffCount`.
        var pageStavesByPage: [[Staff]] = []
        for page in 0 ..< document.pageCount {
            let pagePaths = walked.paths.filter { $0.pageIndex == page }
            let pageClassified = classified.filter { $0.raw.pageIndex == page }
            pageStavesByPage.append(detectStaves(
                paths: pagePaths,
                classified: pageClassified,
                pageIndex: page,
            ))
        }
        let ensembleSize = ensembleStaffCount(pageStavesByPage)

        var systemsAllPages: [ImportSystem] = []
        for page in 0 ..< document.pageCount {
            let systems = layoutSystems(
                staves: pageStavesByPage[page],
                paths: walked.paths,
                classified: classified,
                pageIndex: page,
                ensembleSize: ensembleSize,
            )
            systemsAllPages.append(contentsOf: systems)
        }
        guard !systemsAllPages.isEmpty else {
            throw SheetMusicError.malformedScore(
                reason: "PDFImporter: no staff detected on any page",
            )
        }

        // Expand collapsed "N-bar" multi-measure rests (H-bar + count) back
        // into their N constituent measures so the imported measure count
        // matches the uncollapsed source. No-op when the document has no
        // mm-rest H-bars (the common case). See PDFImporter+MultiMeasureRest.
        if options.expandMultiMeasureRests {
            systemsAllPages = expandMultiMeasureRests(
                systemsAllPages, diagnostics: options.diagnostics,
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
            geometry: geometry,
        )
    }

    /// Record each page's mediaBox size into the geometry side-car. No-op on
    /// the non-geometry path (the collector is nil).
    private static func recordPageSizes(
        document: PDFDocument, geometry: PDFGeometryCollector?,
    ) {
        guard let geometry else { return }
        var sizes: [Int: CGSize] = [:]
        for p in 0 ..< document.pageCount {
            if let page = document.page(at: p) {
                sizes[p] = page.bounds(for: .mediaBox).size
            }
        }
        geometry.setPageSizes(sizes)
    }

    /// Document-wide ensemble size: the number of staves in one system,
    /// inferred from the per-page detected-staff counts. MuseScore lays a
    /// fixed-size ensemble out as a whole number of equal systems per page,
    /// so every body page's staff count is a multiple of the ensemble size;
    /// pages differ only in how many systems fit (the last page often holds
    /// one). The greatest common divisor of the body pages' staff counts is
    /// therefore the per-system staff count (e.g. counts {16, 8} ⇒ 8;
    /// {10, 15} ⇒ 5; {12, 18} ⇒ 6).
    ///
    /// Returns `nil` when there's no usable signal (no multi-staff page, or a
    /// degenerate GCD of 1), so the clusterer falls back to its per-page
    /// heuristics. Pages with 0 or 1 staff (title / text pages) are ignored.
    static func ensembleStaffCount(_ pageStavesByPage: [[Staff]]) -> Int? {
        let counts = pageStavesByPage.map(\.count).filter { $0 >= 2 }
        guard !counts.isEmpty else { return nil }
        let g = counts.reduce(0) { gcd($0, $1) }
        return g >= 2 ? g : nil
    }

    /// Euclidean GCD (gcd(0, n) == n, so it composes under `reduce(0, gcd)`).
    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x
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
