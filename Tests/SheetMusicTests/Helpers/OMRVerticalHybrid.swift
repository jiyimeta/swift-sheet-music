#if !os(Android) && !os(WASI)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF

    /// Decompose the vertical oracle's advantage into the three things the
    /// oracle has and the raster detector does not, one at a time.
    ///
    /// `truthVerticals` replaces the whole predicted vertical set with the
    /// labels', and wins ~+2.5 durP50 / +4.6 durMean. That single number
    /// hides three distinct defects, each with a different fix:
    ///
    ///   1. ENDPOINTS — 95% of matched detections sit >=80% inside their
    ///      truth partner but only 36% sit >=90%: the column is found, its
    ///      two ends are 10-20% of its length off. `isStem`'s head-to-end
    ///      test and stem/beam association both read those ends.
    ///   2. FALSE POSITIVES — the oracle has no junk verticals at all;
    ///      the detector's sub-3.0sp band has 0.115 precision.
    ///   3. MISSES — the oracle carries verticals the detector's length
    ///      floor deliberately cuts (471 truth verticals at 1.5/2.0sp).
    ///      Lowering the floor to reach them admits 87% junk with them;
    ///      the oracle gets them CLEAN, which is a different experiment.
    ///
    /// …plus a fourth, which is not a detector defect at all and is the
    /// reason this enum prices it separately: the oracle's segments carry
    /// `detectedFromRaster == false`, and `PDFImporter.isStem` gates its
    /// 0.25sp head-to-end test on exactly that flag. Part of
    /// `truthVerticals`' win may simply be the test being SKIPPED. Any
    /// reading of the other three that ignores this is unsafe, so
    /// `.unflagRaster` measures it on its own.
    ///
    /// MATCHING IS COVERAGE-BASED, not centre-based, for the reason
    /// `OMRVerticalGranularity` documents at length: the labels split a
    /// system-spanning barline per staff while the raster merges the
    /// column, so centre matching scores one correct answer as one false
    /// negative plus several false positives — which would make this
    /// decomposition garbage rather than merely noisy.
    ///
    /// MEASURED, v2-eval, 32 renders (2026-08-27):
    ///
    ///     mode                     durP50  durMean  pitchP50  pitchMean
    ///     full                       82.0     71.6      96.5       76.5
    ///     snapVerticalEndpoints      43.0     44.6      69.0       62.0
    ///     dropVerticalFalsePositives 80.5     70.9     100.0       78.5
    ///     addVerticalMisses          82.0     71.6      98.5       76.8
    ///     unflagVerticals            59.0     59.6      72.0       62.6
    ///     cleanUnflagVerticals       81.5     73.4     100.0       79.4
    ///     snapUnflagVerticals        59.0     59.6      71.5       62.6
    ///     allVerticalComponents      84.5     76.2     100.0       79.5
    ///     truthVerticals             84.5     76.2     100.0       79.5
    ///
    /// Three things that were NOT the expected answer:
    ///
    ///   * ENDPOINTS ARE WORTH ZERO. `snapUnflag` equals `unflag` to the
    ///     0.1 in every column: once the head-to-end gate is off, taking
    ///     the labels' exact y-extents changes nothing. With the gate ON,
    ///     snapping COSTS 39 durP50 — half of all detected ends sit
    ///     0.25-0.5sp from the label's (5442 ends under 0.25sp, 5035
    ///     between 0.25 and 0.5, 251 between 0.5 and 0.75, 96 above, none
    ///     past 1.0sp), and the gate's tolerance is 0.25sp. The raster's
    ///     own ends are what that constant was calibrated against; the
    ///     labels' are a different convention, not a better measurement.
    ///   * MISSES ARE WORTH ZERO for duration — `addVerticalMisses` is
    ///     byte-identical to `full` on all 32 renders (it moves pitch
    ///     p50 96.5 -> 98.5 and nothing else). The 339 sub-floor truths
    ///     per 42 pages simply do not carry rhythm.
    ///   * THE WIN IS AN INTERACTION, not a component. Dropping the junk
    ///     alone LOSES 0.7 durMean; clearing the flag alone loses 12.0;
    ///     doing both GAINS 1.9. The gate is load-bearing only because
    ///     24% of the vertical set is junk.
    ///
    /// `allVerticalComponents` reproducing `truthVerticals` on every
    /// render is a HARNESS CHECK, not a fifth result: applying all four
    /// edits reconstructs the oracle's set by construction. Its value is
    /// that it would NOT reconstruct it if this matching were wrong —
    /// a centre-based match would leave merged barlines dropped and
    /// re-added as several fragments, and the two would diverge.
    enum OMRVerticalHybrid {
        enum Operation {
            /// Matched detections take their truth partner's y-extent
            /// (and centre x). Unmatched detections and missed truths are
            /// left exactly as they are.
            case snapEndpoints
            /// Drop detections no truth vertical explains.
            case dropFalsePositives
            /// Add truth verticals no detection covers.
            case addMisses
            /// Geometry untouched; only the raster provenance flag is
            /// cleared, which is what `truthVerticals` also does to every
            /// vertical as a side effect of substituting them.
            case unflagRaster
        }

        /// Coverage fraction at which a truth counts as covered and a
        /// detection as explained. 0.8, not 0.9: the established endpoint
        /// finding is that 95% of matched detections clear 0.8 while only
        /// 36% clear 0.9, so 0.9 here would reclassify the very endpoint
        /// error this enum is trying to price as a miss + a false
        /// positive, and the decomposition would double-count it.
        static let coverage = 0.8

        /// Above this a "vertical" is not music — the labels carry the A4
        /// page's own left and right edges as 184sp verticals. A border
        /// truth shares its x with nothing musical, but it swallows
        /// anything that does share it, so it is excluded from EXPLAINING
        /// a false positive and from being a SNAP target. It is NOT
        /// excluded from `addMisses`: `truthVerticals` feeds the borders
        /// too, and dropping them here would put this mode off the
        /// oracle's path for a reason unrelated to the detector.
        static let absurdHeightInSpaces = 30.0

        struct Stats {
            var detections = 0
            var truths = 0
            /// Detections explained by a non-absurd truth at their x.
            var explained = 0
            var falsePositives = 0
            /// …of which a page-border truth WOULD have explained, had
            /// borders been allowed to explain. Reported so the choice
            /// above can be read rather than assumed away.
            var fpExplainedOnlyByBorder = 0
            var truthsCovered = 0
            var truthsMissed = 0
            /// `addMisses`: how many added truths are page borders.
            var addedBorders = 0
            /// `snapEndpoints` outcomes.
            var snapSingle = 0
            var snapMerged = 0
            var snapNone = 0
            /// Detections left alone because no truth matched them at
            /// all — the false positives, which `snapEndpoints` must not
            /// touch.
            var snapNotMatched = 0
            /// Detections left alone because another detection claims the
            /// same truth — the detector fragmented one column.
            var snapShared = 0
            /// Endpoint shift histogram in quarter staff spaces, both
            /// ends pooled.
            var shiftBucket: [Int: Int] = [:]
            /// Snap targets refused for being more than 4x the
            /// detection's length — a fragment against a whole barline,
            /// which is a granularity defect and not an endpoint one.
            var snapRejectedByLength = 0
            /// How far, in staff spaces, snapping moved the two ends.
            var snapShiftTopSp = 0.0
            var snapShiftBottomSp = 0.0

            mutating func add(_ other: Stats) {
                detections += other.detections
                truths += other.truths
                explained += other.explained
                falsePositives += other.falsePositives
                fpExplainedOnlyByBorder += other.fpExplainedOnlyByBorder
                truthsCovered += other.truthsCovered
                truthsMissed += other.truthsMissed
                addedBorders += other.addedBorders
                snapSingle += other.snapSingle
                snapMerged += other.snapMerged
                snapNone += other.snapNone
                snapNotMatched += other.snapNotMatched
                snapShared += other.snapShared
                for (k, v) in other.shiftBucket {
                    shiftBucket[k, default: 0] += v
                }
                snapRejectedByLength += other.snapRejectedByLength
                snapShiftTopSp += other.snapShiftTopSp
                snapShiftBottomSp += other.snapShiftBottomSp
            }

            var line: String {
                "det=\(detections) truth=\(truths) explained=\(explained) "
                    + "fp=\(falsePositives) fpBorderOnly=\(fpExplainedOnlyByBorder) "
                    + "covered=\(truthsCovered) missed=\(truthsMissed) "
                    + "addedBorders=\(addedBorders) snapSingle=\(snapSingle) "
                    + "snapMerged=\(snapMerged) snapNone=\(snapNone) "
                    + "snapNotMatched=\(snapNotMatched) snapShared=\(snapShared) "
                    + "snapRejectedByLength=\(snapRejectedByLength) "
                    + String(
                        format: "snapShiftTopSp=%.3f snapShiftBottomSp=%.3f ",
                        snapShiftTopSp, snapShiftBottomSp,
                    )
                    + shiftBucket.keys.sorted()
                    .map { "q\($0)=\(shiftBucket[$0] ?? 0)" }
                    .joined(separator: " ")
            }
        }

        static func midX(_ p: PathSegment) -> Double {
            Double(p.rect.midX)
        }

        static func extent(_ p: PathSegment) -> (Double, Double) {
            (Double(p.rect.minY), Double(p.rect.maxY))
        }

        static func length(_ p: PathSegment) -> Double {
            Double(p.rect.height)
        }

        /// Is each detection accounted for by the truth verticals that
        /// share its x? Page borders are excluded from the accounting
        /// (see `absurdHeightInSpaces`), and the ones a border ALONE
        /// would have explained are counted so that choice stays visible.
        private static func explained(
            detected: [PathSegment], detectedX: [Double], truth: [PathSegment],
            truthX: [Double], xTol: Double, border: Double, stats: inout Stats,
        ) -> [Bool] {
            var flags = [Bool](repeating: false, count: detected.count)
            for (i, d) in detected.enumerated() {
                let partners = truth.indices.filter { abs(truthX[$0] - detectedX[i]) <= xTol }
                let musical = partners.filter { length(truth[$0]) < border }
                let covMusical = OMRVerticalGranularity.coveredFraction(
                    of: extent(d), by: musical.map { extent(truth[$0]) },
                )
                let covAll = OMRVerticalGranularity.coveredFraction(
                    of: extent(d), by: partners.map { extent(truth[$0]) },
                )
                flags[i] = covMusical >= coverage
                if flags[i] {
                    stats.explained += 1
                } else {
                    stats.falsePositives += 1
                    if covAll >= coverage { stats.fpExplainedOnlyByBorder += 1 }
                }
            }
            return flags
        }

        /// …and the other direction: is each truth vertical's y-extent
        /// covered by the detections that share its x?
        private static func covered(
            detected: [PathSegment], detectedX: [Double], truth: [PathSegment],
            truthX: [Double], xTol: Double, stats: inout Stats,
        ) -> [Bool] {
            var flags = [Bool](repeating: false, count: truth.count)
            for (j, t) in truth.enumerated() {
                let partners = detected.indices.filter { abs(detectedX[$0] - truthX[j]) <= xTol }
                let cov = OMRVerticalGranularity.coveredFraction(
                    of: extent(t), by: partners.map { extent(detected[$0]) },
                )
                flags[j] = cov >= coverage
                if flags[j] { stats.truthsCovered += 1 } else { stats.truthsMissed += 1 }
            }
            return flags
        }

        /// One page. `detected` and `truth` are the VERTICALS only, in the
        /// same frame; every other path kind is the caller's business.
        ///
        /// `kept` is ALIGNED with `detected` (nil = dropped) and `added`
        /// is appended after every raster path, so a mode that edits
        /// nothing reproduces `.full`'s path ORDER exactly and not merely
        /// its contents — `buildScore` reads paths in order, and a
        /// reordering would show up in the decomposition as a vertical
        /// effect it is not.
        static func apply(
            _ operation: Operation, detected: [PathSegment], truth: [PathSegment],
            spacing: Double,
        ) -> (kept: [PathSegment?], added: [PathSegment], stats: Stats) {
            var stats = Stats()
            stats.detections = detected.count
            stats.truths = truth.count
            guard spacing > 0 else { return (detected.map(\.self), [], stats) }
            let xTol = 0.5 * spacing
            let border = absurdHeightInSpaces * spacing
            let truthX = truth.map(midX)
            let detectedX = detected.map(midX)

            let explainedFlags = explained(
                detected: detected, detectedX: detectedX, truth: truth,
                truthX: truthX, xTol: xTol, border: border, stats: &stats,
            )
            let coveredFlags = covered(
                detected: detected, detectedX: detectedX, truth: truth,
                truthX: truthX, xTol: xTol, stats: &stats,
            )

            switch operation {
            case .dropFalsePositives:
                return (detected.indices.map { explainedFlags[$0] ? detected[$0] : nil }, [], stats)
            case .addMisses:
                var added: [PathSegment] = []
                for (j, t) in truth.enumerated() where !coveredFlags[j] {
                    if length(t) >= border { stats.addedBorders += 1 }
                    added.append(asDetection(t))
                }
                return (detected.map(\.self), added, stats)
            case .unflagRaster:
                let out = detected.map { d -> PathSegment? in
                    var p = d
                    p.detectedFromRaster = false
                    return p
                }
                return (out, [], stats)
            case .snapEndpoints:
                let out = snapAll(
                    detected: detected, detectedX: detectedX, truth: truth,
                    truthX: truthX, explainedFlags: explainedFlags, xTol: xTol,
                    border: border, spacing: spacing, stats: &stats,
                )
                return (out, [], stats)
            }
        }

        /// Every detection, snapped in two passes: the targets first, so
        /// the second pass can see when two detections claim one truth.
        ///
        /// ONLY matched detections snap. MEASURED, and it is the
        /// difference between a diagnosis and a disaster: snapping
        /// unmatched ones too (they still OVERLAP a truth often enough)
        /// promotes junk strokes to full stem / barline length and takes
        /// the mode to durP50 42.0 / pitchP50 69.0 — against 82.0 / 96.5
        /// for `full`. A false positive is component (2)'s business;
        /// lengthening it here would price the two components together
        /// and call the sum "endpoints".
        private static func snapAll(
            detected: [PathSegment], detectedX: [Double], truth: [PathSegment],
            truthX: [Double], explainedFlags: [Bool], xTol: Double,
            border: Double, spacing: Double, stats: inout Stats,
        ) -> [PathSegment?] {
            var targets: [[Int]] = []
            var claimants: [Int: Int] = [:]
            for i in detected.indices {
                let t = explainedFlags[i]
                    ? snapTargets(
                        detected[i], truth: truth, truthX: truthX,
                        x: detectedX[i], xTol: xTol, border: border, stats: &stats,
                    )
                    : []
                targets.append(t)
                if t.count == 1 { claimants[t[0], default: 0] += 1 }
            }
            var out: [PathSegment?] = []
            for i in detected.indices {
                out.append(snapped(
                    detected[i], targets: targets[i], truth: truth,
                    truthX: truthX, claimants: claimants,
                    explained: explainedFlags[i], spacing: spacing, stats: &stats,
                ))
            }
            return out
        }

        /// A truth vertical reshaped into what the raster detector would
        /// have emitted for the same column: centre x, degenerate width,
        /// stroke width in `lineWidth`, and — crucially —
        /// `detectedFromRaster: true`, so an added vertical faces the same
        /// `isStem` head-to-end gate every detected one does. Handing it
        /// the oracle's own flag would smuggle `.unflagRaster`'s effect
        /// into `.addMisses`, and the two would no longer decompose.
        static func asDetection(_ truth: PathSegment) -> PathSegment {
            PathSegment(
                kind: .vertical,
                rect: CGRect(
                    x: truth.rect.midX, y: truth.rect.minY,
                    width: 0, height: truth.rect.height,
                ),
                lineWidth: truth.rect.width > 0 ? truth.rect.width : truth.lineWidth,
                pageIndex: truth.pageIndex,
                quad: nil,
                detectedFromRaster: true,
            )
        }

        /// MERGED-BARLINE SNAP POLICY: a detection whose x-window holds
        /// several truth segments it overlaps (the labels' per-staff split
        /// of one system barline) is snapped to the UNION HULL of those
        /// segments rather than to any one of them — snapping to one would
        /// shrink a correct full-system column to a single staff and
        /// invent a defect the detector does not have. `snapMerged` counts
        /// how often this fires.
        static func snapTargets(
            _ d: PathSegment, truth: [PathSegment], truthX: [Double], x: Double,
            xTol: Double, border: Double, stats: inout Stats,
        ) -> [Int] {
            let dExtent = extent(d)
            var targets: [Int] = []
            for j in truth.indices where abs(truthX[j] - x) <= xTol {
                let t = extent(truth[j])
                guard min(t.1, dExtent.1) - max(t.0, dExtent.0) > 0 else { continue }
                guard length(truth[j]) < border else { continue }
                guard length(truth[j]) <= 4 * max(length(d), 1e-9) else {
                    stats.snapRejectedByLength += 1
                    continue
                }
                targets.append(j)
            }
            return targets
        }

        /// One detection, snapped or left alone.
        ///
        /// SHARED-TARGET POLICY, and it is the second thing this mode had
        /// to be taught the hard way: when SEVERAL detections claim the
        /// same single truth — the detector split one stem into fragments
        /// — snapping them all replaces one broken column with two or
        /// three IDENTICAL full-length ones at the same x, which
        /// `nearestStem` / `stemCluster` read as competing stems. That is
        /// a fragmentation defect wearing an endpoint costume, so those
        /// detections are left exactly as they are and counted in
        /// `snapShared`.
        private static func snapped(
            _ d: PathSegment, targets: [Int], truth: [PathSegment],
            truthX: [Double], claimants: [Int: Int], explained: Bool,
            spacing: Double, stats: inout Stats,
        ) -> PathSegment {
            guard explained else {
                stats.snapNotMatched += 1
                return d
            }
            guard !targets.isEmpty else {
                stats.snapNone += 1
                return d
            }
            if targets.count == 1, (claimants[targets[0]] ?? 0) > 1 {
                stats.snapShared += 1
                return d
            }
            let dExtent = extent(d)
            let lo = targets.map { extent(truth[$0]).0 }.min() ?? dExtent.0
            let hi = targets.map { extent(truth[$0]).1 }.max() ?? dExtent.1
            if targets.count == 1 { stats.snapSingle += 1 } else { stats.snapMerged += 1 }
            record(shiftBottom: abs(lo - dExtent.0) / spacing, into: &stats)
            record(shiftTop: abs(hi - dExtent.1) / spacing, into: &stats)
            var out = d
            let newX = targets.count == 1 ? truthX[targets[0]] : Double(d.rect.midX)
            out.rect = CGRect(x: newX, y: lo, width: 0, height: hi - lo)
            return out
        }

        /// Endpoint error is only actionable as a DISTRIBUTION: a mean of
        /// 0.2sp is compatible both with every end being 0.2sp out (fix
        /// the detector's edge estimate) and with 95% being exact and a
        /// tail of whole staff spaces (fix whatever truncates those
        /// columns). The buckets separate the two.
        private static func record(shiftBottom: Double, into stats: inout Stats) {
            stats.snapShiftBottomSp += shiftBottom
            stats.shiftBucket[bucket(shiftBottom), default: 0] += 1
        }

        private static func record(shiftTop: Double, into stats: inout Stats) {
            stats.snapShiftTopSp += shiftTop
            stats.shiftBucket[bucket(shiftTop), default: 0] += 1
        }

        /// Quarter-staff-space buckets to 1sp, then whole ones, capped.
        static func bucket(_ shiftSp: Double) -> Int {
            min(20, Int((shiftSp * 4).rounded(.down)))
        }
    }
#endif
