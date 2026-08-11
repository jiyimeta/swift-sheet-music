#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// Seam-level evaluation of the REAL raster front-end against the
    /// page labels (design spec §8.1). No-op unless `OMR_RASTER_SEAM=1`;
    /// prints, never asserts — the numbers are the deliverable.
    ///
    /// Run it in RELEASE. `analyze` is pixel-loop-bound and a debug build
    /// is roughly two orders of magnitude slower, which turns a
    /// half-hour sweep into a multi-day one:
    ///
    ///     OMR_DATA_ROOT=~/Datasets/sheet-music-omr/v2 \
    ///     ~/.claude/bin/run-with-memcap.sh 4000 /tmp/raster-seam.log \
    ///         env OMR_RASTER_SEAM=1 swift test -c release --no-parallel \
    ///         --filter OMRRasterSeamEvalHarness
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_RASTER_SEAM"] == "1"))
    struct OMRRasterSeamEvalHarness {
        struct Totals {
            var pages = 0
            var lineMatched = 0
            var lineTotal = 0
            var barTp = 0
            var barFp = 0
            var barFn = 0
            var beamTp = 0
            var beamFp = 0
            var beamFn = 0
            var skewAbsSum = 0.0
        }

        @Test func rasterPathsAgainstLabels() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_RASTER_SEAM=1 but OMR_DATA_ROOT is unset")
                return
            }
            var totals = Totals()
            for dir in try OMRHarnessDirectoryWalk.renderDirectories(root: root) {
                for name in try OMRHarnessDirectoryWalk.labelFiles(in: dir) {
                    try evaluate(dir: dir, labelFile: name, into: &totals)
                }
            }
            let lineRecall = totals.lineTotal > 0
                ? Double(totals.lineMatched) / Double(totals.lineTotal) : 0
            print(
                "[raster-seam][SUMMARY] pages=\(totals.pages) "
                    + "staffLines=\(totals.lineMatched)/\(totals.lineTotal) "
                    + "recall=\(String(format: "%.4f", lineRecall)) "
                    + "barlines tp=\(totals.barTp) fp=\(totals.barFp) fn=\(totals.barFn) "
                    + "beams tp=\(totals.beamTp) fp=\(totals.beamFp) fn=\(totals.beamFn) "
                    + "meanAbsSkew="
                    + String(format: "%.3f", totals.skewAbsSum / Double(max(1, totals.pages)))
                    + " peakRSS=\(OMRPageBitmapLoader.peakResidentMB())MB",
            )
        }

        /// One page. Split out of the `@Test` body to stay under the
        /// 60-line function cap, and so a unit test can drive it.
        func evaluate(dir: String, labelFile: String, into totals: inout Totals) throws {
            let page = try OMRLabelSchema.decode(
                Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(labelFile)")),
            )
            let imageURL = URL(fileURLWithPath: "\(dir)/\(page.image.file)")
            guard FileManager.default.fileExists(atPath: imageURL.path) else { return }
            let analysis = try OMRPageBitmapLoader.withPageBitmap(
                url: imageURL, dpi: Double(page.image.dpi),
            ) { RasterPage.analyze($0, pageIndex: page.page.index) }
            totals.pages += 1
            totals.skewAbsSum += abs(analysis.deskewDegrees)

            // The predicted paths are projected through the SAME
            // conversion the labels were written with, so the comparison
            // is of the detector and not of two converters.
            let predicted = OMRLabelSchema.pathLabels(
                analysis.paths, pageIndex: page.page.index,
            )
            // Prefer the front-end's own measured spacing: the label-side
            // fallback runs the vector staff detector, which is exactly
            // the thing under test on the prediction side.
            let spacing = analysis.staffSpacingPt > 0
                ? analysis.staffSpacingPt : OMRSeamMetrics.staffSpacing(page: page)

            // Both sides through the same merge: the labels carry one
            // staff line as up to ten segments and the raster emits one,
            // and a one-to-one match between those two representations
            // scores a perfect detector at one over the fragment count.
            let lines = OMRSeamMetrics.staffLineRecall(
                predicted: OMRSeamMetrics.mergedHorizontals(predicted.paths),
                truth: OMRSeamMetrics.mergedHorizontals(page.paths),
                staffSpacingPt: spacing,
            )
            totals.lineMatched += lines.matched
            totals.lineTotal += lines.total

            let bars = OMRSeamMetrics.barlinePR(
                predicted: predicted.paths, truth: page.paths, staffSpacingPt: spacing,
            )
            totals.barTp += bars.tp
            totals.barFp += bars.fp
            totals.barFn += bars.fn

            let beams = OMRSeamMetrics.beamPR(
                predicted: predicted.beams, truth: page.beams, staffSpacingPt: spacing,
            )
            totals.beamTp += beams.tp
            totals.beamFp += beams.fp
            totals.beamFn += beams.fn
        }
    }
#endif
