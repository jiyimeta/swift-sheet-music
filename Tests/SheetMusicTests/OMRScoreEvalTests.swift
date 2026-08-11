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
        /// One render directory's outcome. Not `private`, and factored
        /// out of the `@Test` loop below, so Task 9's
        /// `OMRHarnessWiringTests` can drive the source.mscx /
        /// .labels.json discovery → parse → replay → metrics wiring
        /// directly against a synthetic fixture, without needing
        /// `OMR_DATA_ROOT`. The printed lines in
        /// `oracleReplayAgainstSourceMscx` below are unchanged for every
        /// directory that reaches a summary line — only re-expressed as
        /// a switch over this.
        ///
        /// ONE DELIBERATE BEHAVIOR CHANGE (Task 9 review, finding 1): the
        /// `.labels.json` listing (`OMRHarnessDirectoryWalk.labelFiles`)
        /// used to sit OUTSIDE the original `do { … } catch { … }`, so a
        /// listing failure threw out of the `for dir in renderDirs` loop
        /// and failed the whole `@Test`, aborting the batch with no
        /// per-directory line. Here it is INSIDE the do-block, so that
        /// failure is caught, returned as `.failed`, printed as a
        /// per-directory `FAIL-THREW` line, and the sweep continues —
        /// matching `source.mscx`/labels/replay failures already handled
        /// a few lines below, and matching the other three harnesses.
        /// Kept intentionally: a dataset sweep must not let one bad
        /// directory abort the whole gate.
        enum RenderOutcome {
            case skippedNoSourceOrLabels
            case processed(summary: String, diverge: String?)
            case failed(String)
        }

        @MainActor
        static func evaluateOneRender(dir: String, tag: String) -> RenderOutcome {
            let fm = FileManager.default
            do {
                let labelPaths = try OMRHarnessDirectoryWalk.labelFiles(in: dir)
                guard fm.fileExists(atPath: "\(dir)/source.mscx"), !labelPaths.isEmpty else {
                    return .skippedNoSourceOrLabels
                }
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
                let summary = ScoreSemanticMetrics.summaryRow(
                    tag: tag, scoreA: scoreA, scoreB: scoreC,
                    pdfRecovered: recovered, aligned: aligned, hiddenLoss: 0,
                )
                let diverge = ScoreSemanticMetrics.firstDivergenceReport(
                    scoreA: aligned.scoreA, scoreB: aligned.scoreB, window: 2,
                )
                return .processed(summary: summary, diverge: diverge)
            } catch {
                return .failed("\(error)")
            }
        }

        @MainActor
        @Test func oracleReplayAgainstSourceMscx() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_SCORE_EVAL=1 but OMR_DATA_ROOT is unset")
                return
            }
            let renderDirs = try OMRHarnessDirectoryWalk.renderDirectories(root: root)
            for dir in renderDirs {
                // One pool per render — see the note in
                // `OMRLabelExportHarness`.
                autoreleasepool {
                    let renderID = (dir as NSString).lastPathComponent
                    let tag = "[\(renderID)]"
                    switch Self.evaluateOneRender(dir: dir, tag: tag) {
                    case .skippedNoSourceOrLabels:
                        print("\(tag)[SUMMARY] SKIP-NO-SOURCE-OR-LABELS")
                    case let .processed(summary, diverge):
                        print(summary)
                        if let diverge {
                            print("\(tag)[diverge] \(diverge)")
                        }
                    case let .failed(message):
                        print("\(tag)[SUMMARY] FAIL-THREW \(message)")
                    }
                }
            }
        }
    }
#endif
