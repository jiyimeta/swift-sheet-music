#if !os(Android) && !os(WASI)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// WHY the staff-line seam loses the lines it loses, and what each
    /// mechanism would be worth if it were repaired.
    ///
    /// The summary line reports one number — `staffLines=…/… recall=…` —
    /// and a recall of 0.68 is compatible with several completely
    /// different detectors: one that finds every line a quarter of a space
    /// too low, one that finds two thirds of each line, one that shatters
    /// each line into fragments the merge does not rejoin, and one that
    /// genuinely never sees the ink. Those want opposite fixes, and the
    /// program's record on this codebase is that reasoning about which one
    /// dominates loses to measuring it — twice, on the beam seam, where a
    /// mechanism that was real on synthetic fixtures recovered ZERO on the
    /// corpus.
    ///
    /// So every truth line the metric missed is assigned to exactly one
    /// mechanism, and the mechanisms partition the miss population: their
    /// counts sum to `truth − matched`. Where a mechanism corresponds to
    /// relaxing a gate, the histogram beside it is the COUNTERFACTUAL —
    /// how many lines come back at each candidate value — computed here so
    /// nobody has to write a fix to find out.
    ///
    /// Gated on `OMR_STAFFLINE_DIAG=1`; prints, never asserts, and leaves
    /// every existing line of output untouched.
    enum OMRStaffLineDiagnostics {
        static var enabled: Bool {
            ProcessInfo.processInfo.environment["OMR_STAFFLINE_DIAG"] == "1"
        }

        /// One truth line's cause of death. Ordered from "the detector
        /// found this line" to "the detector never saw it".
        enum Mechanism: String, CaseIterable {
            /// A prediction satisfies BOTH gates, but an earlier truth
            /// line consumed it. Representation granularity, not
            /// detection: one predicted run is standing in for two truth
            /// lines (or the merge fused two lines into one).
            case taken
            /// No single prediction covers the line, but the UNION of the
            /// predictions at its y does. The line was detected and then
            /// split — `mergedHorizontals` rejoins co-linear fragments
            /// only within 2pt of each other in y.
            case fragmented
            /// One prediction sits at the line's y and covers some but
            /// less than `staffLineOverlapGate` of it. Truncation.
            case truncated
            /// A prediction covers the line but sits further than
            /// `staffLineDyGateInSpaces` away in y. Localisation.
            case offset
            /// Something overlaps and something is near, but no one
            /// prediction is both. The two gates fail together.
            case both
            /// Nothing within a staff space of the line overlaps it at
            /// all. The ink was never turned into a run.
            case absent
        }

        struct Totals {
            var pages = 0
            var truthTotal = 0
            var matched = 0
            var predTotal = 0
            /// Predictions no truth line paired with: the FALSE staff
            /// lines. Downstream these matter at least as much as the
            /// misses — `pathDetectedStaves` slides a five-window over the
            /// y-clusters and advances by one on a failure, so an extra
            /// line shifts every staff below it.
            var predUnmatched = 0
            var mechanism: [String: Int] = [:]
            /// The same two counts restricted to truth lines that are
            /// really staff lines (`solidInkFraction`). This is the recall
            /// the front-end should be judged on; the unrestricted one
            /// mixes in ledger rows the design deliberately rejects.
            var solidTotal = 0
            var solidMatched = 0
            var solidMechanism: [String: Int] = [:]
            /// Ink fraction of the merged truth line, in twentieths, split
            /// by outcome — the evidence for `solidInkFraction` being a
            /// gap rather than a cut through a distribution.
            var inkFracHit: [Int: Int] = [:]
            var inkFracMiss: [Int: Int] = [:]
            /// dy, in twentieths of a staff space, for every `offset`
            /// miss: the counterfactual for widening the dy gate.
            var offsetDy: [Int: Int] = [:]
            /// Best single-prediction coverage, in twentieths, for every
            /// `truncated` miss: the counterfactual for lowering the
            /// overlap gate.
            var truncatedCoverage: [Int: Int] = [:]
            /// Truth line width as a fraction (twentieths) of the widest
            /// truth line on its page, split by outcome. This is the
            /// column that would show a short ossia / cue staff being
            /// discarded by `staffLineMinWidthFractionOfWidest`.
            var widthFracHit: [Int: Int] = [:]
            var widthFracMiss: [Int: Int] = [:]
            /// Keyed `<lines in this staff>|<index from the top>`, split
            /// by outcome: whether the losses sit on a staff's outer lines
            /// (a band effect) or anywhere (a page effect).
            var positionHit: [String: Int] = [:]
            var positionMiss: [String: Int] = [:]
            /// The DOWNSTREAM consumer, `PDFImporter.detectStaves`, run
            /// twice on the same page: once on the raster's own paths and
            /// once with the truth horizontals substituted — which is
            /// exactly the `truthStaffLines` bisect mode, at page
            /// granularity.
            var stavesRaster = 0
            var stavesSubstituted = 0
            var stavesAligned = 0
            var pagesStaffCountEqual = 0
            var pagesRasterFewer = 0
            var pagesRasterMore = 0
            /// Gap coefficient of variation, in 200ths, of the raster's own
            /// five lines under each truth-line staff — split by whether
            /// the raster kept that staff. See `evenness(of:…)`.
            var evenKept: [Int: Int] = [:]
            var evenLost: [Int: Int] = [:]
            /// Staves where the raster did not emit all five lines at all,
            /// so no CV can be formed.
            var evenKeptIncomplete = 0
            var evenLostIncomplete = 0
            /// One line per LOST staff: its four raster gaps against its
            /// four truth gaps. The CV histogram says the gate is what
            /// drops them; this says whether the unevenness is sub-pixel
            /// quantisation or something larger, which is the difference
            /// between fixing the emitted y and fixing the gate.
            var lostDetail: [String] = []
            /// SIGNED y-error of every MATCHED truth line, in twentieths
            /// of a staff space (0.05 sp buckets, floored so the sign
            /// survives).
            ///
            /// The mechanism histograms above only see lines the metric
            /// MISSED, and its dy gate is 0.25 sp = 1.14pt here — wider
            /// than any error that still matches. So a detector that
            /// places every line half a raster row low is invisible to
            /// all of them, and that is precisely the residue round one
            /// could not resolve. Signed rather than absolute because
            /// bias and jitter want opposite fixes: a bias is one
            /// rounding site, jitter is not fixable at all.
            var matchedDy: [Int: Int] = [:]
            var matchedDyN = 0
            var matchedDySum = 0.0
            var matchedDySumSq = 0.0
            /// The same, restricted to lines the ink test calls real
            /// staff lines. Ledger rows that happen to match drag the
            /// unrestricted mean toward their own geometry.
            var matchedDySolid: [Int: Int] = [:]
            var geometry = StaffGeometry()
        }

        /// What the DOWNSTREAM consumer sees when the raster's staff and
        /// the truth-line staff are the same staff.
        ///
        /// `detectStaves` output is not consumed as five line y's.
        /// `staffAnchor` reads `yLines.first` and `yLines.last` and
        /// nothing between them; `barlineCandidates` reads the same two
        /// plus `xRange`; the three middle lines only ever appear inside
        /// `gapCV`, which is a pass/fail the staff already passed. So a
        /// per-line dy histogram can be alarming and cost nothing, and a
        /// dy on ONE of the two outer lines can be tiny and cost a whole
        /// score. These counters are keyed to what is actually read.
        struct StaffGeometry {
            /// Aligned staff pairs seen.
            var pairs = 0
            /// `raster.yLines.first − truth.yLines.first`, 0.05 sp buckets.
            /// This is `StaffAnchor.bottomY`: the pitch origin.
            var anchorDy: [Int: Int] = [:]
            /// `rasterSpan − truthSpan` over the outer lines, 0.05 sp
            /// buckets. This is 4 × `StaffAnchor.lineSpacing`: the pitch
            /// scale.
            var spanErr: [Int: Int] = [:]
            /// max |dy| over the five lines, 0.05 sp buckets — the sweep
            /// the round-one report asked for.
            var maxAbsDy: [Int: Int] = [:]
            /// THE counterfactual for pitch. For a notehead sitting
            /// exactly on truth staff position k (half-spaces from the
            /// bottom line), does the raster's own anchor quantise it to
            /// k? Counted per position and per staff.
            var pitchFlipStaves = 0
            var pitchFlipByPosition: [Int: Int] = [:]
            /// `barlineCandidates.count` both ways, per aligned pair.
            var barlineDelta: [Int: Int] = [:]
            var barlinePairsEqual = 0
            /// xRange edges, `raster − truth`, in whole staff spaces.
            var xLoErr: [Int: Int] = [:]
            var xHiErr: [Int: Int] = [:]
            /// One row per aligned pair that differs in something the
            /// consumer reads. Printed, not bucketed: on a corpus of 572
            /// staves the population that differs is small and each
            /// member names a page.
            var detail: [String] = []
        }

        /// What one page contributed, for the per-page row.
        struct Row {
            var truth = 0
            var matched = 0
            var pred = 0
            var predUnmatched = 0
            var solid = 0
            var solidMatched = 0
            var mechanism: [String: Int] = [:]
            /// The lines that actually cost something: real staff lines
            /// the front-end did not emit. Kept whole, not counted, so the
            /// probe can print each one — there are few enough (measured:
            /// tens across the sweep) that naming them beats bucketing
            /// them, and the ones on a page that also loses a STAFF are
            /// the only staff-line misses with a price.
            var solidMissed: [(line: OMRPageLabels.Path, mechanism: Mechanism)] = []
            var stavesRaster = 0
            var stavesSubstituted = 0
            var stavesAligned = 0
            /// This page's matched-line dy, so the histogram can be
            /// crossed against the per-render score deltas rather than
            /// only read as a corpus aggregate.
            var dyN = 0
            var dySum = 0.0
            var dyAbsMax = 0.0
            var dySumSq = 0.0
        }

        /// A merged truth line is a real STAFF LINE only if this much of
        /// its span is actually inked.
        ///
        /// `mergedHorizontals` unions the x-extents of every co-linear
        /// fragment, and the labels put ledger lines in the same
        /// `horizontal` stream as staff lines. A row of six ledger dashes
        /// at one y therefore arrives as ONE merged "staff line" 411pt
        /// wide with 13% ink — measured, on `cov_clef_changes` page 0 —
        /// and the raster front-end rejects it BY DESIGN (see
        /// `RasterPage.staffLineMinInkFraction`, whose doc records what
        /// happens when it does not). Counting those as recall misses is
        /// what makes 0.68 look like a detector defect.
        ///
        /// Measured on v2-eval, the two populations do not overlap: the
        /// mean ink fraction per width bucket is 1.000 for the full-width
        /// lines and 0.11–0.27 for the wide sparse ones, with nothing in
        /// between. 0.9 is the middle of that gap.
        static let solidInkFraction = 0.9

        /// Assign every missed truth line to one mechanism and fold the
        /// page into `totals`. `truth` and `predicted` must already be
        /// merged (see `OMRSeamMetrics.mergedHorizontals`) and filtered to
        /// horizontals; `truthFragments` is the SAME truth BEFORE the
        /// merge, which is the only thing that can say how much of a
        /// merged line is really inked.
        static func accumulate(
            predicted: [OMRPageLabels.Path], truth: [OMRPageLabels.Path],
            truthFragments: [OMRPageLabels.Path], spacingPt: Double,
            into totals: inout Totals,
        ) -> Row {
            var row = Row()
            guard spacingPt > 0 else { return row }
            let assign = OMRSeamMetrics.staffLineAssignment(
                predicted: predicted, truth: truth, staffSpacingPt: spacingPt,
            )
            row.truth = truth.count
            row.pred = predicted.count
            row.matched = assign.truthPartner.compactMap(\.self).count
            row.predUnmatched = assign.predMatched.filter { !$0 }.count
            let widest = truth.map { $0.rectPt[2] - $0.rectPt[0] }.max() ?? 0
            let places = staffPositions(truth)
            for (ti, t) in truth.enumerated() {
                let ink = inkFraction(t, fragments: truthFragments)
                let solid = ink >= solidInkFraction
                let widthKey = widest > 0
                    ? Int(((t.rectPt[2] - t.rectPt[0]) / widest * 20).rounded(.down)) : 0
                let inkKey = Int((ink * 20).rounded(.down))
                if solid { row.solid += 1 }
                if let pi = assign.truthPartner[ti] {
                    totals.widthFracHit[widthKey, default: 0] += 1
                    totals.inkFracHit[inkKey, default: 0] += 1
                    totals.positionHit[places[ti], default: 0] += 1
                    recordMatchedDy(
                        dySp: (predicted[pi].rectPt[1] - t.rectPt[1]) / spacingPt,
                        solid: solid, into: &totals, row: &row,
                    )
                    if solid {
                        totals.solidMatched += 1
                        row.solidMatched += 1
                    }
                    continue
                }
                totals.widthFracMiss[widthKey, default: 0] += 1
                totals.inkFracMiss[inkKey, default: 0] += 1
                totals.positionMiss[places[ti], default: 0] += 1
                let verdict = classify(
                    t, predicted: predicted, used: assign.predMatched, spacingPt: spacingPt,
                )
                row.mechanism[verdict.mechanism.rawValue, default: 0] += 1
                totals.mechanism[verdict.mechanism.rawValue, default: 0] += 1
                if solid {
                    totals.solidMechanism[verdict.mechanism.rawValue, default: 0] += 1
                    row.solidMissed.append((t, verdict.mechanism))
                }
                if let bucket = verdict.offsetDyBucket {
                    totals.offsetDy[bucket, default: 0] += 1
                }
                if let bucket = verdict.coverageBucket {
                    totals.truncatedCoverage[bucket, default: 0] += 1
                }
            }
            totals.pages += 1
            totals.truthTotal += row.truth
            totals.solidTotal += row.solid
            totals.matched += row.matched
            totals.predTotal += row.pred
            totals.predUnmatched += row.predUnmatched
            return row
        }

        /// Bucket one matched line's signed y-error at 0.05 staff spaces.
        ///
        /// `.down` rather than `.toNearestOrAwayFromZero` so the buckets
        /// tile the axis without a double-width one straddling zero,
        /// which is the shape that would make a bias look symmetric.
        static func recordMatchedDy(
            dySp: Double, solid: Bool, into totals: inout Totals, row: inout Row,
        ) {
            let bucket = Int((dySp / 0.05).rounded(.down))
            totals.matchedDy[bucket, default: 0] += 1
            totals.matchedDyN += 1
            totals.matchedDySum += dySp
            totals.matchedDySumSq += dySp * dySp
            if solid { totals.matchedDySolid[bucket, default: 0] += 1 }
            row.dyN += 1
            row.dySum += dySp
            row.dySumSq += dySp * dySp
            row.dyAbsMax = max(row.dyAbsMax, abs(dySp))
        }

        /// How much of a merged line's span its unmerged fragments cover.
        ///
        /// Fragments are gathered by the SAME 2pt y-tolerance
        /// `mergedHorizontals` merged on, so the set recovered here is the
        /// set that was merged.
        static func inkFraction(
            _ line: OMRPageLabels.Path, fragments: [OMRPageLabels.Path],
        ) -> Double {
            unionCoverage(
                fragments.filter { abs($0.rectPt[1] - line.rectPt[1]) <= 2.0 }, of: line,
            )
        }

        /// One missed truth line's mechanism, plus whichever
        /// counterfactual bucket that mechanism carries.
        ///
        /// The tests run most-recoverable first, so each line lands in the
        /// cheapest bucket that explains it and the six counts partition
        /// the miss population exactly.
        static func classify(
            _ t: OMRPageLabels.Path, predicted: [OMRPageLabels.Path],
            used: [Bool], spacingPt: Double,
        ) -> (mechanism: Mechanism, offsetDyBucket: Int?, coverageBucket: Int?) {
            let tWidth = t.rectPt[2] - t.rectPt[0]
            guard tWidth > 0 else { return (.absent, nil, nil) }
            let dyGate = OMRSeamMetrics.staffLineDyGateInSpaces * spacingPt
            var takenByOther = false
            var nearDy: [OMRPageLabels.Path] = []
            var bestOffsetDy: Double?
            var anyLoose = false
            for (i, p) in predicted.enumerated() {
                let dy = abs(p.rectPt[1] - t.rectPt[1])
                let cover = coverage(p, of: t)
                if dy <= dyGate { nearDy.append(p) }
                if OMRSeamMetrics.staffLinePairs(p, t, staffSpacingPt: spacingPt), used[i] {
                    takenByOther = true
                }
                // HALF a staff space, not a whole one. A prediction a
                // full space away is the NEXT staff line, not this one
                // mislocalised, and counting it as an offset reported 158
                // of 171 "offsets" at dy ≈ 0.95 sp — every one of them a
                // neighbour, and every one of them really an absence.
                if cover >= OMRSeamMetrics.staffLineOverlapGate, dy <= 0.5 * spacingPt {
                    bestOffsetDy = min(bestOffsetDy ?? .infinity, dy)
                }
                if cover > 0, dy <= 0.5 * spacingPt { anyLoose = true }
            }
            if takenByOther { return (.taken, nil, nil) }
            let best = nearDy.map { coverage($0, of: t) }.max() ?? 0
            if unionCoverage(nearDy, of: t) >= OMRSeamMetrics.staffLineOverlapGate {
                return (.fragmented, nil, nil)
            }
            if best > 0 { return (.truncated, nil, Int((best * 20).rounded(.down))) }
            if let dy = bestOffsetDy {
                return (.offset, Int((dy / spacingPt * 20).rounded(.down)), nil)
            }
            return (anyLoose ? .both : .absent, nil, nil)
        }

        /// Fraction of `t`'s width that `p` overlaps.
        static func coverage(_ p: OMRPageLabels.Path, of t: OMRPageLabels.Path) -> Double {
            let width = t.rectPt[2] - t.rectPt[0]
            guard width > 0 else { return 0 }
            let overlap = min(p.rectPt[2], t.rectPt[2]) - max(p.rectPt[0], t.rectPt[0])
            return max(0, min(1, overlap / width))
        }

        /// Fraction of `t`'s width the UNION of `parts` covers — the
        /// question "was this line detected and then split?", which no
        /// single-prediction coverage can answer.
        static func unionCoverage(
            _ parts: [OMRPageLabels.Path], of t: OMRPageLabels.Path,
        ) -> Double {
            let width = t.rectPt[2] - t.rectPt[0]
            guard width > 0 else { return 0 }
            var spans: [(Double, Double)] = []
            for p in parts {
                let lo = max(p.rectPt[0], t.rectPt[0])
                let hi = min(p.rectPt[2], t.rectPt[2])
                if hi > lo { spans.append((lo, hi)) }
            }
            spans.sort { $0.0 < $1.0 }
            var total = 0.0
            var cursor = -Double.greatestFiniteMagnitude
            for span in spans {
                let lo = max(span.0, cursor)
                if span.1 > lo { total += span.1 - lo }
                cursor = max(cursor, span.1)
            }
            return max(0, min(1, total / width))
        }

        /// For each truth line, `<lines in its staff>|<index from the top>`.
        ///
        /// Staves are found by gap, not by assuming five: a page's truth
        /// lines are sorted by y and a new staff starts wherever the gap
        /// exceeds 1.75× the page's median gap. Assuming five would hide
        /// exactly the pages this is looking for — a one-line percussion
        /// staff, an ossia, a system whose lines are already incomplete in
        /// the labels.
        static func staffPositions(_ truth: [OMRPageLabels.Path]) -> [String] {
            let order = truth.indices.sorted { truth[$0].rectPt[1] < truth[$1].rectPt[1] }
            guard order.count > 1 else { return truth.map { _ in "\(truth.count)|0" } }
            var gaps: [Double] = []
            for i in 1 ..< order.count {
                gaps.append(truth[order[i]].rectPt[1] - truth[order[i - 1]].rectPt[1])
            }
            let median = gaps.sorted()[gaps.count / 2]
            var groups: [[Int]] = [[order[0]]]
            for i in 1 ..< order.count {
                if median > 0, gaps[i - 1] > 1.75 * median {
                    groups.append([order[i]])
                } else {
                    groups[groups.count - 1].append(order[i])
                }
            }
            var out = [String](repeating: "", count: truth.count)
            for group in groups {
                for (index, ti) in group.enumerated() {
                    out[ti] = "\(group.count)|\(index)"
                }
            }
            return out
        }

        /// The downstream consumer's verdict on this page, both ways.
        ///
        /// A per-LINE recall of 0.68 alongside a pitch p50 of 96 says the
        /// consumer is far more forgiving than the seam metric, so the
        /// seam number cannot be read as a score prediction. What the
        /// consumer actually does is slide a five-window over the y
        /// clusters (`PDFImporter.pathDetectedStaves`), advancing by FIVE
        /// on a hit and by ONE on a miss — so it survives losing lines
        /// until the survivors stop looking evenly spaced, and then loses
        /// a whole staff at once. Running it on the raster's paths and on
        /// the same paths with truth horizontals substituted is the
        /// `truthStaffLines` bisect mode at page granularity, which is the
        /// join between this seam and the score deltas.
        static func staves(
            predicted: [OMRPageLabels.Path],
            rasterPaths: [PathSegment], truthPaths: [PathSegment],
            glyphs: [ClassifiedGlyph], pageIndex: Int, spacingPt: Double,
            label: String, into totals: inout Totals, row: inout Row,
        ) {
            let substituted = rasterPaths.filter { $0.kind != .horizontal }
                + truthPaths.filter { $0.kind == .horizontal }
            let a = PDFImporter.detectStaves(
                paths: rasterPaths, classified: glyphs, pageIndex: pageIndex,
            )
            let b = PDFImporter.detectStaves(
                paths: substituted, classified: glyphs, pageIndex: pageIndex,
            )
            let tolerance = CGFloat(max(spacingPt, 1)) * 0.5
            var used = [Bool](repeating: false, count: a.count)
            var aligned = 0
            for staff in b {
                let mid = midline(staff.yLines)
                var partner: SheetMusicPDF.Staff?
                for (i, other) in a.enumerated()
                    where !used[i] && abs(midline(other.yLines) - mid) <= tolerance
                {
                    used[i] = true
                    aligned += 1
                    partner = other
                    break
                }
                if let partner {
                    compareGeometry(
                        raster: partner, truth: staff, spacingPt: spacingPt,
                        label: label, into: &totals.geometry,
                    )
                }
                evenness(
                    of: staff, predicted: predicted, spacingPt: spacingPt,
                    survived: partner != nil, label: label, into: &totals,
                )
            }
            row.stavesRaster = a.count
            row.stavesSubstituted = b.count
            row.stavesAligned = aligned
            totals.stavesRaster += a.count
            totals.stavesSubstituted += b.count
            totals.stavesAligned += aligned
            if a.count == b.count {
                totals.pagesStaffCountEqual += 1
            } else if a.count < b.count {
                totals.pagesRasterFewer += 1
            } else {
                totals.pagesRasterMore += 1
            }
        }

        private static func midline(_ ys: [CGFloat]) -> CGFloat {
            guard !ys.isEmpty else { return 0 }
            return ys.reduce(0, +) / CGFloat(ys.count)
        }

        /// Why a staff the truth lines produce can vanish from the raster
        /// even when the raster emitted all five of its lines.
        ///
        /// `pathDetectedStaves` does not ask whether five lines exist. It
        /// asks whether their four gaps have a COEFFICIENT OF VARIATION
        /// below 0.1 — and at this corpus's staff spacing of 4.6pt that
        /// budget is a standard deviation of 0.46pt, while a 200dpi raster
        /// row is 0.36pt and the emitted y is the integer midpoint of the
        /// line's ink rows. The seam metric's own dy gate is 0.25 × 4.6 =
        /// 1.15pt, so a set of lines can pass every line-level test and
        /// still be too unevenly spaced to be a staff.
        ///
        /// So: for each staff the substituted (truth-line) detection
        /// found, take the raster's nearest emitted line to each of its
        /// five, and record the CV of THOSE — split by whether the raster
        /// kept the staff. If the mechanism is the CV gate, the lost
        /// staves pile up just above 0.10 while the kept ones sit below,
        /// and the cumulative column says how many come back per candidate
        /// threshold.
        static func evenness(
            of staff: SheetMusicPDF.Staff, predicted: [OMRPageLabels.Path], spacingPt: Double,
            survived: Bool, label: String, into totals: inout Totals,
        ) {
            guard spacingPt > 0, staff.yLines.count == 5 else { return }
            var ys: [Double] = []
            for line in staff.yLines {
                let target = Double(line)
                let near = predicted
                    .map { abs($0.rectPt[1] - target) }
                    .min() ?? .greatestFiniteMagnitude
                guard near <= 0.5 * spacingPt,
                      let hit = predicted.first(where: {
                          abs($0.rectPt[1] - target) == near
                      })
                else { break }
                ys.append(hit.rectPt[1])
            }
            guard ys.count == 5 else {
                if survived {
                    totals.evenKeptIncomplete += 1
                } else {
                    totals.evenLostIncomplete += 1
                }
                return
            }
            // Mirrors `PDFImporter.gapCV`, which is private. Four gaps,
            // standard deviation over mean.
            let gaps = (1 ..< 5).map { ys[$0] - ys[$0 - 1] }
            let mean = gaps.reduce(0, +) / 4
            let variance = gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 4
            let cv = mean > 0 ? variance.squareRoot() / mean : .infinity
            let bucket = min(60, Int((cv * 200).rounded(.down)))
            if survived {
                totals.evenKept[bucket, default: 0] += 1
            } else {
                totals.evenLost[bucket, default: 0] += 1
                let truthGaps = (1 ..< 5)
                    .map { Double(staff.yLines[$0] - staff.yLines[$0 - 1]) }
                totals.lostDetail.append(
                    label + " cv=" + String(format: "%.3f", cv)
                        + " sp=" + String(format: "%.2f", spacingPt)
                        + " rasterGaps=" + gaps.map { String(format: "%.2f", $0) }
                        .joined(separator: ",")
                        + " truthGaps=" + truthGaps.map { String(format: "%.2f", $0) }
                        .joined(separator: ",")
                        + " dy=" + zip(ys, staff.yLines)
                        .map { String(format: "%+.2f", $0 - Double($1)) }
                        .joined(separator: ","),
                )
            }
        }
    }
#endif
