#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    @testable import SheetMusicPDF
    import Testing

    struct OMRScoreEvalUnitTests {
        /// The harness body, factored so a unit test can drive it with
        /// hand content and the env-gated suite with dataset dirs.
        @Test func summaryRowAndDivergenceOnHandScores() {
            let a = ScoreSemanticMetricsTests.makeScore([[60, 62, 64, 65]])
            let b = ScoreSemanticMetricsTests.makeScore([[60, 62, 64, 67]])
            let aligned = ScoreSemanticMetrics.alignNotefulParts(scoreA: a, scoreB: b)
            let row = ScoreSemanticMetrics.summaryRow(
                tag: "[hand]", scoreA: a, scoreB: b,
                pdfRecovered: true, aligned: aligned, hiddenLoss: 0,
            )
            #expect(row.contains("pitch%=75%"))
            #expect(ScoreSemanticMetrics.firstDivergenceReport(scoreA: a, scoreB: b, window: 1) != nil)
        }
    }

    /// Score-level harness (spec §8.2, gate P0-G3): oracle replay vs
    /// source.mscx per render. No-op unless OMR_SCORE_EVAL=1. Prints,
    /// never asserts. KNOWN METRIC BLIND SPOTS (inherited from the
    /// real-corpus harness, by design): end-truncated parts keep
    /// percentages high; mid-score part loss cascades; measure-count
    /// explosions zero out pitch — ALWAYS read measuresA/measuresB first.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_SCORE_EVAL"] == "1"))
    struct OMRScoreEvalHarness {
        @MainActor
        @Test func oracleReplayAgainstSourceMscx() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_SCORE_EVAL=1 but OMR_DATA_ROOT is unset")
                return
            }
            let fm = FileManager.default
            let renderDirs = try (fm.contentsOfDirectory(atPath: root)).sorted()
                .map { "\(root)/\($0)" }
                .filter { fm.fileExists(atPath: "\($0)/render.json") }
            for dir in renderDirs {
                let renderID = (dir as NSString).lastPathComponent
                let tag = "[\(renderID)]"
                let labelPaths = try (fm.contentsOfDirectory(atPath: dir))
                    .filter { $0.hasSuffix(".labels.json") }.sorted()
                guard fm.fileExists(atPath: "\(dir)/source.mscx"), !labelPaths.isEmpty else {
                    print("\(tag)[SUMMARY] SKIP-NO-SOURCE-OR-LABELS")
                    continue
                }
                do {
                    let scoreA = try MSCXParser.parse(
                        contentsOf: URL(fileURLWithPath: "\(dir)/source.mscx"),
                    )
                    let pages = try labelPaths.map {
                        try OMRLabelSchema.decode(
                            Data(contentsOf: URL(fileURLWithPath: "\(dir)/\($0)")),
                        )
                    }
                    let replay = try OMROracleFrontEnd.replay(pages: pages)
                    let scoreC = try PDFImporter.buildScore(
                        pageCount: replay.pageCount, walked: replay.walked,
                        pageSizes: replay.pageSizes, documentAttributes: nil,
                        options: .init(),
                    )
                    let recovered = !scoreC.parts.isEmpty
                        && ScoreSemanticMetrics.contentTotals(scoreC).notes > 0
                    let aligned = ScoreSemanticMetrics.alignNotefulParts(
                        scoreA: scoreA, scoreB: scoreC,
                    )
                    print(ScoreSemanticMetrics.summaryRow(
                        tag: tag, scoreA: scoreA, scoreB: scoreC,
                        pdfRecovered: recovered, aligned: aligned, hiddenLoss: 0,
                    ))
                    if let diverge = ScoreSemanticMetrics.firstDivergenceReport(
                        scoreA: aligned.scoreA, scoreB: aligned.scoreB, window: 2,
                    ) {
                        print("\(tag)[diverge] \(diverge)")
                    }
                } catch {
                    print("\(tag)[SUMMARY] FAIL-THREW \(error)")
                }
            }
        }
    }
#endif
