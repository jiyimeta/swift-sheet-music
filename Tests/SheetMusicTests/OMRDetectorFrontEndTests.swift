#if !os(Android)
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// The vocabulary check is the one gate here that never needs a
    /// model: `OMRDetectorFrontEnd.checkVocabulary` is pure, and these
    /// four cases are the whole of that gate's evidence (task-14 brief). A
    /// model whose class list disagrees with the frozen table — reorder,
    /// unknown name, wrong length — must throw, not warn: it would
    /// otherwise assemble a plausible-looking score out of the wrong
    /// symbols and nothing downstream would notice.
    struct OMRDetectorFrontEndTests {
        @Test func aModelWhoseClassListMatchesTheFrozenTableLoads() throws {
            try OMRDetectorFrontEnd.checkVocabulary(OMRPrepTargets.trainableVocabulary)
        }

        @Test func aReorderedClassListIsRejected() {
            var classes = OMRPrepTargets.trainableVocabulary
            classes.swapAt(0, 1)
            // A model whose class 7 means something else than the table's
            // class 7 builds a plausible score out of the wrong symbols,
            // and nothing downstream notices. This must throw, not warn.
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkVocabulary(classes)
            }
        }

        @Test func anUnknownClassNameIsRejected() {
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkVocabulary(
                    OMRPrepTargets.trainableVocabulary + ["noteheadTriangle"],
                )
            }
        }

        @Test func aShortClassListIsRejected() {
            #expect(throws: (any Error).self) {
                try OMRDetectorFrontEnd.checkVocabulary(
                    Array(OMRPrepTargets.trainableVocabulary.dropLast()),
                )
            }
        }
    }

    /// Gated on a real model directory — none exists on this machine yet
    /// (task-14 brief). Point `OMR_MODEL_ROOT` at a directory holding
    /// `model.mlpackage` / `model.json`, as written by
    /// `Training/model/export.py` (e.g. its `--checkpoint random` output,
    /// the P3d-G1 floor).
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_MODEL_ROOT"] != nil))
    struct OMRDetectorFrontEndModelTests {
        @Test func aRealModelProducesGlyphsInPageSpace() async throws {
            let path = try #require(ProcessInfo.processInfo.environment["OMR_MODEL_ROOT"])
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let frontEnd = try await OMRDetectorFrontEnd(modelRoot: root)

            let bitmap = RasterTestBitmaps.staff(
                widthPx: 1600, heightPx: 1200, dpi: 300, topY: 400, spacingPx: 14,
            )
            let analysis = RasterPage.analyze(bitmap, pageIndex: 0, keepDeskewed: true)
            let page = OMRPageLabels(
                schema: 1,
                page: OMRPageLabels.Page(
                    index: 0,
                    widthPt: Double(bitmap.width) * 72.0 / bitmap.dpi,
                    heightPt: Double(bitmap.height) * 72.0 / bitmap.dpi,
                ),
                image: OMRPageLabels.Image(
                    file: "page.png", dpi: Int(bitmap.dpi),
                    labelTransform: [1, 0, 0, 0, 1, 0, 0, 0, 1], sourceSizePx: nil,
                ),
                glyphs: [], paths: [], beams: [], curves: [], texts: [],
                census: OMRPageLabels.Census(glyphsByClass: [:], texts: 0),
            )

            let glyphs = try frontEnd.glyphs(page: page, analysis: analysis)
            // A real model on a real staff page is expected to find
            // something; every glyph it finds must sit on this page, in
            // page space.
            let pageSize = analysis.pageSizePt
            for glyph in glyphs {
                #expect(glyph.geometry.pageIndex == 0)
                #expect(glyph.geometry.origin.x >= -1 && glyph.geometry.origin.x <= pageSize.width + 1)
                #expect(glyph.geometry.origin.y >= -1 && glyph.geometry.origin.y <= pageSize.height + 1)
            }
        }
    }
#endif
