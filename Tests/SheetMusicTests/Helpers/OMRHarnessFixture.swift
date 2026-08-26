#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    @testable import SheetMusicPDF

    /// A minimal `OMR_DATA_ROOT`-shaped directory tree, built under a
    /// temp directory, for driving each harness's own file discovery and
    /// per-render branch selection without `OMR_DATA_ROOT` or a real
    /// dataset (Task 9 controller addition — the four env-gated harnesses
    /// had never executed their own wiring, only the shared pure
    /// functions they call, per the Task 5-8 reviews).
    ///
    /// Every render directory's PDF / labels / mscx are derived from the
    /// SAME walked content: a bare 5-line staff, no glyphs — the minimum
    /// `PDFImporterFaçadeTests.parsesNonEmptyScoreFromSyntheticPDF`
    /// already proves `buildScore` accepts. No CoreText/CFF font
    /// embedding is needed, so this fixture is not gated by Bravura
    /// availability and is deterministic across hosts.
    @MainActor
    enum OMRHarnessFixture {
        static let dpi = 300

        /// One page's PDF bytes plus everything derived from walking it:
        /// the `Score` a direct import produces, and the labels an
        /// export would write for it.
        struct Page {
            var pdfData: Data
            var score: Score
            var labels: OMRPageLabels
        }

        /// The tree's layout. `root` is a fresh temp directory owned by
        /// this fixture; call `cleanup(_:)` when done with it.
        struct Layout {
            var root: String
            /// render.json + score.pdf + page_0.labels.json + source.mscx.
            /// The well-formed case for every harness that reads labels.
            var wellFormedDir: String
            /// render.json + score.pdf + source.mscx, NO `.labels.json`.
            /// Doubles as: the "labels missing" skip case for the
            /// replay/seam/score harnesses, AND a legitimately
            /// well-formed input for the label-export harness (which
            /// produces labels, and requires none as input).
            var missingLabelsDir: String
            /// render.json + score.pdf + page_0.labels.json, NO
            /// `source.mscx` — the "source missing" skip case.
            var missingSourceDir: String
            /// No `render.json` at all — must be excluded by the very
            /// first traversal filter, never reaching any harness.
            var notARenderDir: String
        }

        /// Walks a synthetic 5-line-staff, glyph-less PDF the same way
        /// `PDFImporterFaçadeTests` proves is enough for `buildScore`,
        /// then derives the `Score` and the `OMRPageLabels` a real
        /// export would write for the identical content.
        static func buildPage() throws -> Page {
            let lineYs: [CGFloat] = [400, 410, 420, 430, 440]
            let paths = lineYs.map {
                PDFFixtureBuilder.PathPlacement(
                    origin: CGPoint(x: 50, y: $0), kind: .horizontal(width: 400),
                )
            }
            let pdfData = PDFFixtureBuilder.build(paths: paths)
            let document = try PDFImporter.openDocument(pdfData)
            let walk = try PDFImporter.walkDocument(
                document, anchorMusicGlyphsToPUARange: true,
            )
            guard let pageSize = walk.pageSizes[0] else {
                throw SheetMusicError.malformedScore(ScoreFault(
                    code: "omr.harness",
                    message: "OMRHarnessFixture: no page size for page 0",
                ))
            }
            let score = try PDFImporter.buildScore(
                pageCount: document.pageCount, walked: walk.content,
                pageSizes: walk.pageSizes, documentAttributes: nil,
                options: .init(),
            )
            let labels = OMRLabelSchema.pageLabels(
                walked: walk.content, pageIndex: 0, pageSize: pageSize,
                dpi: dpi, imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            return Page(pdfData: pdfData, score: score, labels: labels)
        }

        /// Builds the tree and returns its layout. Caller must call
        /// `cleanup(_:)` when done.
        static func makeLayout() throws -> Layout {
            let fm = FileManager.default
            let root = fm.temporaryDirectory
                .appendingPathComponent("omr-harness-fixture-\(UUID().uuidString)")
            // Task 9 review, minor finding: on any throw below, this
            // directory would otherwise leak — the caller only receives
            // (and therefore only `cleanup(_:)`s) a `Layout` on success.
            // `succeeded` flips to `true` only right before the `return`,
            // so this `defer` removes `root` on every throwing exit and
            // is a no-op on the success path (the caller owns cleanup
            // from there).
            var succeeded = false
            defer { if !succeeded { try? fm.removeItem(at: root) } }
            let wellFormed = root.appendingPathComponent("aaa_well_formed")
            let missingLabels = root.appendingPathComponent("bbb_missing_labels")
            let missingSource = root.appendingPathComponent("ccc_missing_source")
            let notARender = root.appendingPathComponent("zzz_not_a_render")
            for dir in [wellFormed, missingLabels, missingSource, notARender] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            let page = try buildPage()
            let renderJSON = try JSONSerialization.data(
                withJSONObject: ["pdf": "score.pdf", "dpi": dpi],
            )
            let labelData = try OMRLabelSchema.encodeCanonical(page.labels)
            let mscxData = try MSCXEncoder.encode(page.score)

            try write(renderJSON, "render.json", in: wellFormed)
            try write(page.pdfData, "score.pdf", in: wellFormed)
            try write(labelData, "page_0.labels.json", in: wellFormed)
            try write(mscxData, "source.mscx", in: wellFormed)

            try write(renderJSON, "render.json", in: missingLabels)
            try write(page.pdfData, "score.pdf", in: missingLabels)
            try write(mscxData, "source.mscx", in: missingLabels)

            try write(renderJSON, "render.json", in: missingSource)
            try write(page.pdfData, "score.pdf", in: missingSource)
            try write(labelData, "page_0.labels.json", in: missingSource)

            try write(Data("not a render dir".utf8), "README.txt", in: notARender)

            succeeded = true
            return Layout(
                root: root.path, wellFormedDir: wellFormed.path,
                missingLabelsDir: missingLabels.path,
                missingSourceDir: missingSource.path,
                notARenderDir: notARender.path,
            )
        }

        /// Removes the fixture's temp directory. Best-effort: a failed
        /// cleanup must never fail the test that already ran.
        static func cleanup(_ layout: Layout) {
            try? FileManager.default.removeItem(atPath: layout.root)
        }

        private static func write(_ data: Data, _ name: String, in dir: URL) throws {
            try data.write(to: dir.appendingPathComponent(name))
        }
    }
#endif
