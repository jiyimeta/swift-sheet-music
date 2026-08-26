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
            /// One entry per MATCHED truth beam: the fraction of its
            /// x-range the prediction covers. Bucketed at 5% rather than
            /// kept whole — 22,725 beams across the sweep is a list worth
            /// tens of megabytes, and percentiles are all this reports.
            var beamCoverageBuckets: [Int: Int] = [:]
            var skewAbsSum = 0.0
            var vTrue: [String: Int] = [:]
            var vFalse: [String: Int] = [:]
            /// Truth verticals the front-end DID / did not emit, keyed by
            /// `<halfSpaces>|<beamRelation>`.
            var stemHit: [String: Int] = [:]
            var stemMiss: [String: Int] = [:]
            /// Predicted verticals bucketed by quarter-staff-space of
            /// head-to-nearer-end distance, split by whether they are real.
            var endReal: [Int: Int] = [:]
            var endFalse: [Int: Int] = [:]
            /// The same verticals re-scored with a granularity-tolerant
            /// match, accumulated in the SAME pass so the two columns
            /// describe one run and not two.
            var vgran = OMRVerticalGranularity.Totals()
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
            printBeamCoverage(totals.beamCoverageBuckets)
            OMRVerticalGranularity.report(totals.vgran)
            for key in Set(totals.endReal.keys).union(totals.endFalse.keys).sorted() {
                print(
                    "[endprofile] sp=\(Double(key) / 4) "
                        + "real=\(totals.endReal[key] ?? 0) "
                        + "false=\(totals.endFalse[key] ?? 0)",
                )
            }
            for key in Set(totals.stemHit.keys).union(totals.stemMiss.keys).sorted() {
                print(
                    "[stemprofile] key=\(key) "
                        + "hit=\(totals.stemHit[key] ?? 0) "
                        + "miss=\(totals.stemMiss[key] ?? 0)",
                )
            }
            for key in Set(totals.vTrue.keys).union(totals.vFalse.keys).sorted() {
                let t = totals.vTrue[key] ?? 0
                let f = totals.vFalse[key] ?? 0
                print("[vprofile] hw=\(key) true=\(t) false=\(f)")
            }
        }

        /// Percentiles of the matched beams' x-coverage, plus how many
        /// matches would survive candidate coverage gates.
        ///
        /// The counts at 0.5 / 0.8 / 0.95 are what a gated `beamPR` would
        /// report at each threshold. Printing all three, rather than
        /// picking one now, is deliberate: the shortfall a correct
        /// detector still shows (its slab stops at the outermost stem's
        /// ink) has never been measured, and a threshold chosen above it
        /// would rediagnose correct beams as truncated ones.
        func printBeamCoverage(_ buckets: [Int: Int]) {
            let total = buckets.values.reduce(0, +)
            guard total > 0 else {
                print("[beamcov][SUMMARY] matched=0")
                return
            }
            func percentile(_ q: Double) -> Double {
                var seen = 0
                let target = Int((Double(total) * q).rounded(.down))
                for bucket in buckets.keys.sorted() {
                    seen += buckets[bucket] ?? 0
                    if seen > target { return Double(bucket) / 20 }
                }
                return 1
            }
            func atLeast(_ threshold: Double) -> Int {
                buckets.filter { Double($0.key) / 20 >= threshold - 1e-9 }
                    .values.reduce(0, +)
            }
            print(
                "[beamcov][SUMMARY] matched=\(total) "
                    + "p01=\(String(format: "%.2f", percentile(0.01))) "
                    + "p05=\(String(format: "%.2f", percentile(0.05))) "
                    + "p25=\(String(format: "%.2f", percentile(0.25))) "
                    + "p50=\(String(format: "%.2f", percentile(0.50))) "
                    + "ge0.5=\(atLeast(0.5)) ge0.8=\(atLeast(0.8)) ge0.95=\(atLeast(0.95))",
            )
            for bucket in buckets.keys.sorted() {
                print("[beamcov] cov=\(Double(bucket) / 20) n=\(buckets[bucket] ?? 0)")
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
            for c in beams.coverage {
                totals.beamCoverageBuckets[Int((c * 20).rounded(.down)), default: 0] += 1
            }

            runProbes(
                predicted: predicted.paths, truth: truthPaths,
                analysis: analysis, page: page, spacing: spacing, into: &totals,
            )
        }

        /// The env-gated profiles. Off by default and factored out of
        /// `evaluate` so adding one never pushes that function over the
        /// body-length cap.
        func runProbes(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            analysis: RasterPageAnalysis, page: OMRPageLabels,
            spacing: Double, into totals: inout Totals,
        ) {
            let env = ProcessInfo.processInfo.environment
            if env["OMR_VERTICAL_PROBE"] == "1" {
                profileVerticals(
                    predicted: predicted, truth: truth,
                    spacing: spacing, into: &totals,
                )
                OMRVerticalGranularity.accumulate(
                    predicted: predicted, truth: truth,
                    spacing: spacing, into: &totals.vgran,
                )
            }
            if env["OMR_STEM_END_PROBE"] == "1" {
                profileHeadEndDistance(
                    predicted: predicted, truth: truth,
                    page: page, transform: analysis.transform,
                    spacing: spacing, into: &totals,
                )
            }
            if env["OMR_STEM_MISS_PROBE"] == "1" {
                profileMissedVerticals(
                    predicted: predicted, truth: truth,
                    beams: analysis.paths.filter { $0.kind == .beam },
                    spacing: spacing, into: &totals,
                )
            }
        }

        /// Every TRUTH vertical, bucketed by its length and by where it
        /// sits relative to the beams this page's front-end found, split
        /// by whether the front-end emitted it at all.
        ///
        /// This is the apportionment the eighth→quarter defect needs. The
        /// bisect says verticals carry the loss (substituting the oracle's
        /// verticals moves duration p50 59 → 75 while substituting its
        /// beams moves it 59 → 62), so the question is no longer WHICH
        /// primitive but WHICH STEMS, and the two candidate answers make
        /// different pictures here:
        ///
        ///   * `touchesBeam` uses a strict `quad.xRange.contains(x)`, and
        ///     a beam's fitted x-range structurally stops at the ink of
        ///     its own outermost stems (every stem column merges beam and
        ///     stem into one run that lands on no ladder rung). If that is
        ///     the mechanism, the misses pile up in `edge` — just outside
        ///     a beam's span — while `inside` stays clean.
        ///   * If instead the floors are simply too high for real stems,
        ///     the misses spread across the short buckets regardless of
        ///     any beam, i.e. mostly in `none`.
        func profileMissedVerticals(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            beams: [PathSegment], spacing: Double, into totals: inout Totals,
        ) {
            guard spacing > 0 else { return }
            let pBars = predicted.filter { $0.kind == "vertical" }
            for t in truth where t.kind == "vertical" {
                let tx = (t.rectPt[0] + t.rectPt[2]) / 2
                let ty = (t.rectPt[1] + t.rectPt[3]) / 2
                let found = pBars.contains { p in
                    let dx = (p.rectPt[0] + p.rectPt[2]) / 2 - tx
                    let dy = (p.rectPt[1] + p.rectPt[3]) / 2 - ty
                    return (dx * dx + dy * dy).squareRoot() <= 0.5 * spacing
                }
                let lengthSp = (t.rectPt[3] - t.rectPt[1]) / spacing
                let key = "\(Int((lengthSp * 2).rounded()))|"
                    + Self.beamRelation(x: tx, beams: beams, spacing: spacing)
                if found {
                    totals.stemHit[key, default: 0] += 1
                } else {
                    totals.stemMiss[key, default: 0] += 1
                }
            }
        }

        /// Every predicted vertical, bucketed by the distance from its
        /// NEARER END to the notehead that would certify it as a stem,
        /// split by whether the vertical is real.
        ///
        /// This is the histogram that has to exist before `isStem` grows
        /// a y-term. `isStem` today accepts a vertical when ANY notehead
        /// in the measure cell is within 1.4 staff spaces of it IN X, with
        /// no y condition at all — an assumption that holds for a vector
        /// PDF, where MuseScore strokes stems and draws accidentals as
        /// glyphs, so paths and glyphs are disjoint ink. A raster sees
        /// only ink, and an accidental's vertical stroke sits at the
        /// note's own y, on the legal side, inside the x-window.
        ///
        /// The end distance is the discriminating quantity because a
        /// notehead sits at ONE END of its stem, whereas a glyph stroke
        /// that shares an x is centred on the note. `beamedEnd` already
        /// uses this same `min(|y − loY|, |y − hiY|)` to find a stem's
        /// beam-attaching end, so the two stay consistent.
        ///
        /// Read the two populations' overlap and put the threshold in the
        /// gap's MIDDLE, not at either edge — this stage has already been
        /// bitten twice by taking the edge of a plateau.
        func profileHeadEndDistance(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            page: OMRPageLabels, transform: PageTransform,
            spacing: Double, into totals: inout Totals,
        ) {
            guard spacing > 0,
                  let replay = try? OMROracleFrontEnd.replay(pages: [page])
            else { return }
            // Through the oracle replay and the SAME reframe the hybrid
            // uses, rather than reading label origins directly: on a clean
            // raster the two agree, which is exactly why reading them
            // directly would stay wrong in silence on a degraded one.
            let heads = OMRHybridFrontEnd.reframe(
                replay.walked.glyphs.filter {
                    $0.geometry.pageIndex == page.page.index
                        && OMRLabelClassNames.className(for: $0.semantic)
                        .hasPrefix("notehead")
                },
                page: page, transform: transform,
            )
            let tBars = truth.filter { $0.kind == "vertical" }
            let window = 1.4 * spacing
            for p in predicted where p.kind == "vertical" {
                let px = (p.rectPt[0] + p.rectPt[2]) / 2
                let py = (p.rectPt[1] + p.rectPt[3]) / 2
                let real = tBars.contains { t in
                    let dx = (t.rectPt[0] + t.rectPt[2]) / 2 - px
                    let dy = (t.rectPt[1] + t.rectPt[3]) / 2 - py
                    return (dx * dx + dy * dy).squareRoot() <= 0.5 * spacing
                }
                var best = Double.greatestFiniteMagnitude
                for head in heads {
                    let hx = Double(head.geometry.origin.x)
                    guard abs(hx - px) <= window else { continue }
                    let hy = Double(head.geometry.origin.y)
                    best = min(
                        best,
                        min(abs(hy - p.rectPt[1]), abs(hy - p.rectPt[3])),
                    )
                }
                // No notehead in the x-window at all: `isStem` already
                // rejects it, so it is not part of this decision.
                guard best < .greatestFiniteMagnitude else { continue }
                let key = Int((best / spacing * 4).rounded(.down))
                if real {
                    totals.endReal[key, default: 0] += 1
                } else {
                    totals.endFalse[key, default: 0] += 1
                }
            }
        }

        /// Where `x` sits relative to the page's detected beams:
        /// `in` (inside some beam's fitted x-range), `edge` (outside every
        /// range but within half a staff space of one — the band a beam
        /// cannot cover because its own outer stem's ink lives there), or
        /// `none`.
        static func beamRelation(
            x: Double, beams: [PathSegment], spacing: Double,
        ) -> String {
            var nearest = Double.greatestFiniteMagnitude
            for beam in beams {
                guard let q = beam.quad else { continue }
                let lo = Double(q.xRange.lowerBound)
                let hi = Double(q.xRange.upperBound)
                if x >= lo, x <= hi { return "in" }
                nearest = min(nearest, min(abs(x - lo), abs(x - hi)))
            }
            return nearest <= 0.5 * spacing ? "edge" : "none"
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
