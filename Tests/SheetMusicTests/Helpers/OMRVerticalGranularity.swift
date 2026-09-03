#if !os(Android) && !os(WASI)
    import Foundation

    /// The vertical (stem / barline) seam re-scored with a matching that
    /// tolerates a REPRESENTATION-GRANULARITY difference between the two
    /// sides, reported alongside — never instead of — the one-to-one
    /// numbers `OMRSeamMetrics.barlinePR` produces.
    ///
    /// `barlinePR` pairs a truth vertical with a prediction when their
    /// CENTRES sit within half a staff space, in x AND y. That criterion
    /// silently assumes both sides cut a column of ink at the same places,
    /// and the two sides here demonstrably do not: the vector labels emit a
    /// system-spanning barline as one segment PER STAFF at a shared x,
    /// while the raster detector merges a continuous column into a single
    /// tall run (see the "NO UPPER LENGTH LIMIT" note in
    /// `RasterPage+Verticals`, where capping the length destroyed the
    /// score). Whenever one side splits what the other merges, the centres
    /// cannot agree, and ONE correct answer is scored as one false
    /// negative plus several false positives.
    ///
    /// The tolerant scheme replaces centre agreement with y-INTERVAL
    /// COVERAGE at a compatible x, in both directions, so it is blind to
    /// which side did the splitting:
    ///
    ///   * a truth vertical is COVERED when the union of the predicted
    ///     verticals sharing its x covers at least θ of its y-extent;
    ///   * a predicted vertical is EXPLAINED when the union of the truth
    ///     verticals sharing its x covers at least θ of ITS y-extent.
    ///
    /// θ is reported at both 0.8 and 0.9 rather than fixed, because the
    /// gap between them is itself the evidence for how tight the coverage
    /// is; a granularity artefact covers essentially all of its partner,
    /// while a genuinely different line covers a fraction.
    ///
    /// This is a MEASUREMENT, not a proposed replacement metric. Its
    /// leniency is real and stated: a short stroke that happens to sit
    /// inside a tall truth barline's x-window and y-extent is "explained"
    /// here even if it is not that barline. The per-height breakdown
    /// exists so that leniency can be read rather than assumed away.
    enum OMRVerticalGranularity {
        struct Totals {
            var pages = 0
            var truthTotal = 0
            var predTotal = 0
            /// Recomputed from the same assignment `barlinePR` makes, so
            /// the "original" column here is a self-check against the
            /// summary line and not a second implementation of it.
            var origTp = 0
            var origFp = 0
            var origFn = 0
            var truthCov80 = 0
            var truthCov90 = 0
            var predExp80 = 0
            var predExp90 = 0
            /// Truth verticals keyed by length in HALF staff spaces — the
            /// same key `[stemprofile]` uses, so the two profiles' rows
            /// line up.
            var truthHit: [Int: Int] = [:]
            var truthMissCov80: [Int: Int] = [:]
            var truthMissCov90: [Int: Int] = [:]
            var truthMissUncov: [Int: Int] = [:]
            /// Sanity counter: a truth vertical the centre metric matched
            /// yet the coverage metric does not cover. A large value would
            /// mean the tolerant scheme is not a superset and the two
            /// columns are not comparable.
            var truthHitUncov90: [Int: Int] = [:]
            /// Predicted verticals split at the pending threshold
            /// decision's boundary (`verticalMinLengthInSpaces` is 2.5, and
            /// the false positives were reported to pile up under 3.0).
            var bandTotal: [String: Int] = [:]
            var bandOrigTp: [String: Int] = [:]
            var bandFpExp80: [String: Int] = [:]
            var bandFpExp90: [String: Int] = [:]
            var bandFpUnexp90: [String: Int] = [:]
            /// Original false positives by height in half staff spaces,
            /// and how many of those a truth vertical explains.
            var fpByHeight: [Int: Int] = [:]
            var fpByHeightExp90: [Int: Int] = [:]
            /// Explained false positives split by whether the truth
            /// vertical doing the explaining is ABSURDLY tall — the labels
            /// carry the page border as a vertical path, and a border
            /// swallows anything at its x, so "explained" by one is not
            /// evidence of a granularity artefact.
            var fpExpTallTruth = 0
            var fpExpNormalTruth = 0
            /// Truth verticals the centre metric missed but coverage
            /// covers, keyed by HOW MANY predictions contributed. One
            /// contributor means the prediction is simply offset in y, not
            /// that either side split the line — a different defect with a
            /// different fix, and the two must not be reported as one.
            var missCoveredByPartnerCount: [Int: Int] = [:]
            /// For those, the covering prediction's length over the truth
            /// vertical's, rounded. 1 means the prediction is the same
            /// line merely OFFSET in y; 2 and above means it absorbed this
            /// truth vertical along with its neighbours, which is the
            /// merge the granularity hypothesis predicts.
            var missCoveredLengthRatio: [Int: Int] = [:]
            /// Guard against reading "no truth vertical explains it" off a
            /// lookup that never found a candidate for an unrelated
            /// reason: how many false positives have ANY truth vertical at
            /// a compatible x at all.
            var fpWithXPartner = 0
            var fpWithoutXPartner = 0
        }

        static let bandBoundaryInSpaces = 3.0
        static let lowBand = "lt3.0sp"
        static let highBand = "ge3.0sp"
        /// Above this, a "vertical" is not music. Measured: the eval
        /// labels' tallest verticals are the A4 page's own left and right
        /// edges, 184.6 staff spaces at x = 0 and x = 595.4.
        static let absurdHeightInSpaces = 30.0

        /// Fraction of `target`'s y-extent covered by the UNION of
        /// `others`, clipped to `target`. A degenerate (zero-height)
        /// target counts as covered when anything overlaps its x at all —
        /// the labels do not produce one, but the arithmetic must not
        /// divide by zero.
        static func coveredFraction(
            of target: (Double, Double), by others: [(Double, Double)],
        ) -> Double {
            let span = target.1 - target.0
            guard span > 0 else { return others.isEmpty ? 0 : 1 }
            var clipped: [(Double, Double)] = []
            for other in others {
                let lo = max(other.0, target.0)
                let hi = min(other.1, target.1)
                if hi > lo { clipped.append((lo, hi)) }
            }
            guard !clipped.isEmpty else { return 0 }
            clipped.sort { $0.0 < $1.0 }
            var total = 0.0
            var curLo = clipped[0].0
            var curHi = clipped[0].1
            for c in clipped.dropFirst() {
                if c.0 > curHi {
                    total += curHi - curLo
                    curLo = c.0
                    curHi = c.1
                } else {
                    curHi = max(curHi, c.1)
                }
            }
            total += curHi - curLo
            return min(1, total / span)
        }

        /// One page, both directions.
        static func accumulate(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            spacing: Double, into totals: inout Totals,
        ) {
            guard spacing > 0 else { return }
            let tBars = truth.filter { $0.kind == "vertical" }
            let pBars = predicted.filter { $0.kind == "vertical" }
            let assign = OMRSeamMetrics.barlineAssignment(
                predicted: pBars, truth: tBars, staffSpacingPt: spacing,
            )
            totals.pages += 1
            totals.truthTotal += tBars.count
            totals.predTotal += pBars.count
            let tp = assign.truthMatched.filter(\.self).count
            totals.origTp += tp
            totals.origFn += tBars.count - tp
            totals.origFp += pBars.count - assign.predMatched.filter(\.self).count
            accumulateTruth(
                tBars: tBars, pBars: pBars, matched: assign.truthMatched,
                spacing: spacing, into: &totals,
            )
            accumulatePredicted(
                tBars: tBars, pBars: pBars, matched: assign.predMatched,
                spacing: spacing, into: &totals,
            )
        }

        private static func midX(_ p: OMRPageLabels.Path) -> Double {
            (p.rectPt[0] + p.rectPt[2]) / 2
        }

        private static func yExtent(_ p: OMRPageLabels.Path) -> (Double, Double) {
            (p.rectPt[1], p.rectPt[3])
        }

        /// Every truth vertical: is its y-extent covered by the
        /// predictions that share its x?
        private static func accumulateTruth(
            tBars: [OMRPageLabels.Path], pBars: [OMRPageLabels.Path],
            matched: [Bool], spacing: Double, into totals: inout Totals,
        ) {
            let xTol = 0.5 * spacing
            let pX = pBars.map(midX)
            for (i, t) in tBars.enumerated() {
                let tx = midX(t)
                let partners = pBars.indices
                    .filter { abs(pX[$0] - tx) <= xTol }
                    .map { yExtent(pBars[$0]) }
                let cov = coveredFraction(of: yExtent(t), by: partners)
                if cov >= 0.8 { totals.truthCov80 += 1 }
                if cov >= 0.9 { totals.truthCov90 += 1 }
                let key = Int(((t.rectPt[3] - t.rectPt[1]) / spacing * 2).rounded())
                guard !matched[i] else {
                    totals.truthHit[key, default: 0] += 1
                    if cov < 0.9 { totals.truthHitUncov90[key, default: 0] += 1 }
                    continue
                }
                if cov >= 0.9 {
                    totals.truthMissCov90[key, default: 0] += 1
                    totals.truthMissCov80[key, default: 0] += 1
                    let overlapping = partners.filter {
                        min($0.1, t.rectPt[3]) - max($0.0, t.rectPt[1]) > 0
                    }
                    totals.missCoveredByPartnerCount[overlapping.count, default: 0] += 1
                    let truthLen = t.rectPt[3] - t.rectPt[1]
                    let longest = overlapping.map { $0.1 - $0.0 }.max() ?? 0
                    if truthLen > 0 {
                        let ratio = min(20, Int((longest / truthLen).rounded()))
                        totals.missCoveredLengthRatio[ratio, default: 0] += 1
                    }
                } else if cov >= 0.8 {
                    totals.truthMissCov80[key, default: 0] += 1
                } else {
                    totals.truthMissUncov[key, default: 0] += 1
                }
            }
        }

        /// Every predicted vertical: does a truth vertical at its x
        /// account for its y-extent?
        private static func accumulatePredicted(
            tBars: [OMRPageLabels.Path], pBars: [OMRPageLabels.Path],
            matched: [Bool], spacing: Double, into totals: inout Totals,
        ) {
            let xTol = 0.5 * spacing
            let tX = tBars.map(midX)
            for (j, p) in pBars.enumerated() {
                let px = midX(p)
                let partners = tBars.indices
                    .filter { abs(tX[$0] - px) <= xTol }
                    .map { yExtent(tBars[$0]) }
                let cov = coveredFraction(of: yExtent(p), by: partners)
                if cov >= 0.8 { totals.predExp80 += 1 }
                if cov >= 0.9 { totals.predExp90 += 1 }
                let height = (p.rectPt[3] - p.rectPt[1]) / spacing
                let band = height < bandBoundaryInSpaces ? lowBand : highBand
                totals.bandTotal[band, default: 0] += 1
                guard !matched[j] else {
                    totals.bandOrigTp[band, default: 0] += 1
                    continue
                }
                let hKey = Int((height * 2).rounded())
                totals.fpByHeight[hKey, default: 0] += 1
                if partners.isEmpty {
                    totals.fpWithoutXPartner += 1
                } else {
                    totals.fpWithXPartner += 1
                }
                if cov >= 0.9 {
                    totals.fpByHeightExp90[hKey, default: 0] += 1
                    totals.bandFpExp90[band, default: 0] += 1
                    totals.bandFpExp80[band, default: 0] += 1
                    let byBorder = partners.contains {
                        ($0.1 - $0.0) / spacing >= absurdHeightInSpaces
                    }
                    if byBorder {
                        totals.fpExpTallTruth += 1
                    } else {
                        totals.fpExpNormalTruth += 1
                    }
                } else {
                    totals.bandFpUnexp90[band, default: 0] += 1
                    if cov >= 0.8 { totals.bandFpExp80[band, default: 0] += 1 }
                }
            }
        }

        static func report(_ t: Totals) {
            guard t.pages > 0 else {
                print("[vgran][SUMMARY] pages=0")
                return
            }
            reportSummary(t)
            reportBands(t)
            print(
                "[vgran][fpcause] explainedByBorderTruth=\(t.fpExpTallTruth) "
                    + "explainedByNormalTruth=\(t.fpExpNormalTruth) "
                    + "fpWithXPartner=\(t.fpWithXPartner) "
                    + "fpWithoutXPartner=\(t.fpWithoutXPartner)",
            )
            for n in t.missCoveredByPartnerCount.keys.sorted() {
                print(
                    "[vgran][fncause] contributingPredictions=\(n) "
                        + "n=\(t.missCoveredByPartnerCount[n] ?? 0)",
                )
            }
            for r in t.missCoveredLengthRatio.keys.sorted() {
                print(
                    "[vgran][fnratio] predLen/truthLen=\(r) "
                        + "n=\(t.missCoveredLengthRatio[r] ?? 0)",
                )
            }
            for key in allTruthKeys(t) {
                print(
                    "[vgran][truth] key=\(key) sp=\(Double(key) / 2) "
                        + "origHit=\(t.truthHit[key] ?? 0) "
                        + "origHitUncov90=\(t.truthHitUncov90[key] ?? 0) "
                        + "origMissCov90=\(t.truthMissCov90[key] ?? 0) "
                        + "origMissCov80=\(t.truthMissCov80[key] ?? 0) "
                        + "origMissUncov=\(t.truthMissUncov[key] ?? 0)",
                )
            }
            for key in Set(t.fpByHeight.keys).sorted() {
                print(
                    "[vgran][fp] key=\(key) sp=\(Double(key) / 2) "
                        + "fp=\(t.fpByHeight[key] ?? 0) "
                        + "explained90=\(t.fpByHeightExp90[key] ?? 0)",
                )
            }
        }

        private static func allTruthKeys(_ t: Totals) -> [Int] {
            Set(t.truthHit.keys)
                .union(t.truthMissCov80.keys)
                .union(t.truthMissCov90.keys)
                .union(t.truthMissUncov.keys)
                .sorted()
        }

        private static func ratio(_ num: Int, _ den: Int) -> String {
            den > 0 ? String(format: "%.4f", Double(num) / Double(den)) : "n/a"
        }

        private static func reportSummary(_ t: Totals) {
            print(
                "[vgran][SUMMARY] pages=\(t.pages) truth=\(t.truthTotal) "
                    + "pred=\(t.predTotal) "
                    + "orig tp=\(t.origTp) fp=\(t.origFp) fn=\(t.origFn) "
                    + "recall=\(ratio(t.origTp, t.truthTotal)) "
                    + "precision=\(ratio(t.origTp, t.predTotal))",
            )
            print(
                "[vgran][TOLERANT] "
                    + "cov80=\(t.truthCov80) fn80=\(t.truthTotal - t.truthCov80) "
                    + "recall80=\(ratio(t.truthCov80, t.truthTotal)) "
                    + "exp80=\(t.predExp80) fp80=\(t.predTotal - t.predExp80) "
                    + "precision80=\(ratio(t.predExp80, t.predTotal))",
            )
            print(
                "[vgran][TOLERANT] "
                    + "cov90=\(t.truthCov90) fn90=\(t.truthTotal - t.truthCov90) "
                    + "recall90=\(ratio(t.truthCov90, t.truthTotal)) "
                    + "exp90=\(t.predExp90) fp90=\(t.predTotal - t.predExp90) "
                    + "precision90=\(ratio(t.predExp90, t.predTotal))",
            )
        }

        private static func reportBands(_ t: Totals) {
            for band in [lowBand, highBand] {
                let total = t.bandTotal[band] ?? 0
                let origTp = t.bandOrigTp[band] ?? 0
                let exp90 = t.bandFpExp90[band] ?? 0
                let unexp = t.bandFpUnexp90[band] ?? 0
                print(
                    "[vgran][band] band=\(band) pred=\(total) "
                        + "origTp=\(origTp) origFp=\(total - origTp) "
                        + "fpExplained80=\(t.bandFpExp80[band] ?? 0) "
                        + "fpExplained90=\(exp90) fpUnexplained90=\(unexp) "
                        + "origPrecision=\(ratio(origTp, total)) "
                        + "tolPrecision90=\(ratio(origTp + exp90, total))",
                )
            }
        }
    }
#endif
