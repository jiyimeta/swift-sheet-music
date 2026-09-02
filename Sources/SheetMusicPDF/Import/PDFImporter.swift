#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
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
    /// Run stages 1-12 of the pipeline over the walked content and assemble
    /// the resulting `Score`. Foundation-only — the Apple front-end
    /// (`walkDocument`) produced `walked` / `pageSizes` / `documentAttributes`
    /// from a `PDFDocument`; Android supplies the same values from its own PDF
    /// reader. Throws when the content yields no glyphs / paths, or when no
    /// staff can be detected on any page.
    static func buildScore(
        pageCount: Int,
        walked incoming: WalkedContent,
        pageSizes: [Int: CGSize],
        documentAttributes: [String: Any]?,
        options: PDFImportOptions,
        geometry: PDFGeometryCollector? = nil,
        rasterPages: Set<Int>? = nil,
    ) throws -> Score {
        // THE FIRST THING THAT HAPPENS. Every pass below reads an
        // order-preserving `filter` of these four streams, so imposing one
        // canonical order here makes the whole decode a function of the
        // streams' CONTENT rather than of the order a front-end happened to
        // emit them in. That is not a nicety: a raster front-end finds glyphs
        // on a page and cannot reproduce a PDF content stream's order, so
        // without this the raster and vector decodes of the same page can
        // never agree — which is exactly what gate P0-G1 measures. See
        // `PDFImporter+Canonical` for why this is one sort and not thirty
        // comparator fixes.
        let walked = incoming.canonicalized()
        // Page sizes (mediaBox) drive the geometry side-car's system rects and
        // display flips; only consumed on the geometry-capture path.
        geometry?.setPageSizes(pageSizes)
        guard !walked.glyphs.isEmpty || !walked.texts.isEmpty || !walked.paths.isEmpty else {
            throw refuseEmptyContent(options: options)
        }
        let classified = walked.glyphs
        emitUnknownGlyphDiagnostics(classified, options: options)
        emitUndecodedCodeDiagnostics(walked.undecodedCodes, options: options)

        // Detect every page's staves first so the system clusterer can use a
        // DOCUMENT-WIDE ensemble size (staves per system). MuseScore stacks
        // several equal-sized systems per page; the per-page gap heuristic
        // can't tell a wide within-system gap from a true between-system gap
        // in isolation, but the ensemble size is a stable structural prior
        // across the whole document. See `ensembleStaffCount`.
        var pageStavesByPage: [[Staff]] = []
        for page in 0 ..< pageCount {
            let pagePaths = walked.paths.filter { $0.pageIndex == page }
            let pageClassified = classified.filter { $0.geometry.pageIndex == page }
            pageStavesByPage.append(detectStaves(
                paths: pagePaths,
                classified: pageClassified,
                pageIndex: page,
            ))
        }
        let ensembleSize = ensembleStaffCount(pageStavesByPage)

        var systemsAllPages: [ImportSystem] = []
        for page in 0 ..< pageCount {
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
            throw malformedPDF(code: "pdf.staff.noneDetected", message: "PDFImporter: no staff detected on any page")
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
            firstPageSize: pageSizes[0],
            documentAttributes: documentAttributes,
            systems: systemsAllPages,
            texts: walked.texts,
            classified: classified,
            paths: walked.paths,
            tieMarks: tieMarks,
            graceSizeThreshold: graceSizeThreshold,
            options: options,
            geometry: geometry,
            rasterPages: rasterPages,
        )
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
            .filter { isNotehead($0.semantic) && $0.geometry.renderedSize > 0 }
            .map(\.geometry.renderedSize)
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
                    location: "page \(g.geometry.pageIndex)",
                    message: "Unknown SMuFL codepoint U+\(String(cp, radix: 16, uppercase: true))",
                ))
            }
        }
    }

    /// §9: a document the importer cannot read has to say why and name the
    /// knob that might fix it. Deliberately NOT a new pass over the pages
    /// asking "is this a scan?" — that would make the default options do work
    /// they do not do today, which is exactly what the byte-identical vector
    /// corpus gate exists to detect. This fires only where the importer was
    /// already about to throw.
    static func refuseEmptyContent(options: PDFImportOptions) -> SheetMusicError {
        let configured = options.omrTileClassifier != nil || options.omrDetector != nil
        let hint = configured
            ? "PDFImporter: no glyphs/paths found, and PDFImportOptions.omrTileClassifier "
            + "read nothing from these pages either."
            : "PDFImporter: no glyphs/paths found. If this is a scanned PDF, set "
            + "PDFImportOptions.omrTileClassifier to read its pages as images."
        options.diagnostics?(PDFImportDiagnostic(
            severity: .warning, location: "document", message: hint,
        ))
        return malformedPDF(code: "pdf.content.empty", message: hint)
    }

    /// The `info` diagnostic owed to a caller who set `omrTileClassifier` on
    /// an entry point that does not rasterize. A knob that silently does
    /// nothing is this repository's own silent-drop smell; only the PDFKit
    /// entries — `parse(pdfData:options:)` / `parse(pdfURL:options:)` and
    /// their `parseWithGeometry` twins — act on it.
    ///
    /// Lives here rather than beside the fallback because
    /// `parseUsingSwiftReader` is compiled on Android too, where the whole
    /// raster path is excluded.
    static func warnEntryPointDoesNotRasterize(_ entryPoint: String, options: PDFImportOptions) {
        guard options.omrTileClassifier != nil || options.omrDetector != nil else { return }
        options.diagnostics?(PDFImportDiagnostic(
            severity: .info, location: "document",
            message: "PDFImporter.\(entryPoint) does not rasterize: "
                + "PDFImportOptions.omrTileClassifier is ignored here. Use "
                + "PDFImporter.parse(pdfData:options:) or parseWithGeometry(pdfData:options:) "
                + "to read scanned pages.",
        ))
    }

    /// Report every show-string code the front-end had to drop — one
    /// `.warning` per page and font, never one per glyph.
    ///
    /// A drop here is content leaving the decode: the glyph is not merely
    /// unclassified, it is gone, taking its position with it. That used to
    /// happen in silence, which is how a whole score could import as 91
    /// measures with zero notes and zero diagnostics.
    static func emitUndecodedCodeDiagnostics(
        _ tallies: [UndecodedCodeTally],
        options: PDFImportOptions,
    ) {
        guard let cb = options.diagnostics else { return }
        for t in tallies {
            var dropped: [String] = []
            if t.unmappedCodes > 0 {
                dropped.append("\(t.unmappedCodes) show-string code(s) the "
                    + "font's /ToUnicode CMap does not map")
            }
            if t.truncatedBytes > 0 {
                dropped.append("\(t.truncatedBytes) trailing byte(s) left by a "
                    + "show string that ended part-way through a code")
            }
            guard !dropped.isEmpty else { continue }
            cb(PDFImportDiagnostic(
                severity: .warning,
                location: "page \(t.pageIndex), font \(t.fontName)",
                message: "Dropped " + dropped.joined(separator: " and "),
                context: "first dropped code 0x"
                    + String(t.firstCode, radix: 16, uppercase: true),
            ))
        }
    }

    private static func malformedPDF(code: String, message: String) -> SheetMusicError {
        .malformedScore(ScoreFault(code: code, message: message))
    }
}
