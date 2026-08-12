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
            var vTrue: [String: Int] = [:]
            var vFalse: [String: Int] = [:]
        }

        @Test func rasterPathsAgainstLabels() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_RASTER_SEAM=1 but OMR_DATA_ROOT is unset")
                return
            }
            var totals = Totals()
            // Frozen too: the degraded eval set marks itself with
            // `frozen.json` rather than `render.json`, and a
            // `render.json`-only walk over it sweeps nothing while
            // printing a plausible-looking zero.
            for dir in try OMRHarnessDirectoryWalk.renderOrFrozenDirectories(root: root) {
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
            for key in Set(totals.vTrue.keys).union(totals.vFalse.keys).sorted() {
                let t = totals.vTrue[key] ?? 0
                let f = totals.vFalse[key] ?? 0
                print("[vprofile] hw=\(key) true=\(t) false=\(f)")
            }
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
            // …and the TRUTH is brought into the front-end's frame. On a
            // clean raster this is the identity; on a degraded one,
            // skipping it measures the frame mismatch instead of the
            // detector — the first degraded sweep read 0.20 staff-line
            // recall for exactly that reason.
            let truthPaths = OMRHybridFrontEnd.reframe(
                page.paths, page: page, transform: analysis.transform,
            )
            let truthBeams = OMRHybridFrontEnd.reframe(
                page.beams, page: page, transform: analysis.transform,
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
                truth: OMRSeamMetrics.mergedHorizontals(truthPaths),
                staffSpacingPt: spacing,
            )
            totals.lineMatched += lines.matched
            totals.lineTotal += lines.total

            let bars = OMRSeamMetrics.barlinePR(
                predicted: predicted.paths, truth: truthPaths, staffSpacingPt: spacing,
            )
            totals.barTp += bars.tp
            totals.barFp += bars.fp
            totals.barFn += bars.fn

            let beams = OMRSeamMetrics.beamPR(
                predicted: predicted.beams, truth: truthBeams, staffSpacingPt: spacing,
            )
            totals.beamTp += beams.tp
            totals.beamFp += beams.fp
            totals.beamFn += beams.fn

            if ProcessInfo.processInfo.environment["OMR_VERTICAL_PROBE"] == "1" {
                profileVerticals(
                    predicted: predicted.paths, truth: truthPaths,
                    spacing: spacing, into: &totals,
                )
            }
        }

        /// Bucket every predicted vertical by height and width in staff
        /// spaces, split by whether it matched a truth vertical.
        ///
        /// The question this answers is whether a geometric discriminator
        /// for the false positives EXISTS at all — the raster cannot tell
        /// a clef's stroke from a barline by construction, so before
        /// designing a filter, the two populations have to be shown to
        /// separate on something the front-end can actually see.
        func profileVerticals(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            spacing: Double, into totals: inout Totals,
        ) {
            let tBars = truth.filter { $0.kind == "vertical" }
            for p in predicted where p.kind == "vertical" {
                let px = (p.rectPt[0] + p.rectPt[2]) / 2
                let py = (p.rectPt[1] + p.rectPt[3]) / 2
                let matched = tBars.contains { t in
                    let dx = (t.rectPt[0] + t.rectPt[2]) / 2 - px
                    let dy = (t.rectPt[1] + t.rectPt[3]) / 2 - py
                    return (dx * dx + dy * dy).squareRoot() <= 0.5 * spacing
                }
                let h = (p.rectPt[3] - p.rectPt[1]) / spacing
                let w = p.lineWidthPt / spacing
                let key = "\(Int((h * 2).rounded()))|\(Int((w * 10).rounded()))"
                if matched {
                    totals.vTrue[key, default: 0] += 1
                } else {
                    totals.vFalse[key, default: 0] += 1
                }
            }
        }
    }
#endif
