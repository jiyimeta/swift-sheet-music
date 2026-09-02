#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// Crosses the detector's own drop record (`RasterBeamProbe`) against
    /// the unmatched truth beams, so "where does a beam level die" is
    /// answered by overlap on a real page rather than by reading the code.
    ///
    /// `OMRBeamDiagnostics` already says WHAT the loss looks like from
    /// outside — 114 of 199 unmatched truth beams have a 0.5 sp prediction
    /// one beam pitch away. It cannot say which stage dropped the missing
    /// one, because from outside a slab that never opened and an interval
    /// the straightness gate threw away look identical. This joins the two
    /// halves: every interval the pipeline discards is kept with its
    /// page-space band, and an unmatched truth beam is attributed to a drop
    /// when a discarded band actually sits on it.
    ///
    /// Inert unless `OMR_BEAM_SLAB_PROBE=1`.
    enum OMRBeamSlabProbe {
        /// Vertical slack when asking whether a discarded band sits on a
        /// truth beam. A quarter of a staff space is half the gap between
        /// two stacked levels, so it cannot reach the neighbour's own band.
        static let bandToleranceInSpaces = 0.25

        struct Totals {
            var pages = 0
            var fnTotal = 0
            /// Unmatched truth beams WITH a predicted beam within one
            /// stack gap — the 114 — split by the drop that covers them.
            var fnNear = 0
            var fnNearOnShort = 0
            var fnNearOnResidual = 0
            /// …of which the covering band's geometry spans MORE levels
            /// than the label the smoothing gave it.
            var fnNearOnResidualMulti = 0
            /// …of which the covering band's own level counts disagree
            /// with its label in either direction, and — the number that
            /// decides the repair — how many would have survived each
            /// candidate fit.
            var fnNearOnResidualMismatched = 0
            var fnNearRecoverableByLabelExclusion = 0
            var fnNearRecoverableByTrim = 0
            /// The covering band's missed residual, in 0.05 sp buckets,
            /// and its worst single-column top-edge step in 0.25 sp.
            var fnNearResidual: [Int: Int] = [:]
            var fnNearStep: [Int: Int] = [:]
            var fnNearOnSlope = 0
            var fnNearOnNoDrop = 0
            /// The covering band's height and column count, in quarter
            /// staff spaces and in columns, for the near ones.
            var fnNearBandHeight: [Int: Int] = [:]
            var fnNearBandColumns: [Int: Int] = [:]
            /// The rest of the unmatched truth beams, same split.
            var fnFarOnDrop = 0
            var fnFarOnNoDrop = 0
            var bands = 0
            var bandsShort = 0
            var bandsResidual = 0
            var bandsSlope = 0
            /// Discarded bands whose geometry spans MORE levels than the
            /// label the smoothing gave them — the mismatch signature.
            var bandsMultiLevelGeometry = 0
            var bandsResidualMultiLevelGeometry = 0
            /// Bands that do / do not sit on any unmatched truth beam.
            var bandsOnFn = 0
            var bandsOnNothing = 0
            /// THE NULL. A band sitting on a truth beam the detector DID
            /// find cannot have caused a loss, so this is the rate at
            /// which the overlap test attributes by coincidence. Without
            /// it, "every one of the 114 has a discarded band on it" is
            /// unreadable: 57,807 bands over 69 pages would sit on
            /// everything.
            var residualBandsOnFn = 0
            var residualBandsOnMatched = 0
            var shortBandsOnFn = 0
            var shortBandsOnMatched = 0
        }

        /// One page. `bands` is `RasterBeamProbe.bands` as left by the
        /// analysis of this page.
        static func accumulate(
            bands: [RasterBeamProbe.Band], predicted: [OMRPageLabels.Beam],
            truth: [OMRPageLabels.Beam], spacingPt: Double, into totals: inout Totals,
        ) {
            totals.pages += 1
            guard spacingPt > 0 else { return }
            let assign = OMRSeamMetrics.beamAssignment(
                predicted: predicted, truth: truth, staffSpacingPt: spacingPt,
            )
            let matched = Set(assign.map(\.ti))
            countBands(bands, truth: truth, matched: matched, spacingPt: spacingPt, into: &totals)
            for (ti, t) in truth.enumerated() where !matched.contains(ti) {
                totals.fnTotal += 1
                let near = predicted.contains {
                    (gap($0, t) ?? .infinity)
                        <= OMRBeamDiagnostics.stackGapInSpaces * spacingPt
                }
                let band = bands
                    .filter { covers($0, t, spacingPt: spacingPt) }
                    .min { rank($0.reason) < rank($1.reason) }
                switch (near, band?.reason) {
                case (true, .short): totals.fnNearOnShort += 1
                case (true, .residual): totals.fnNearOnResidual += 1
                case (true, .slope): totals.fnNearOnSlope += 1
                case (true, nil): totals.fnNearOnNoDrop += 1
                case (false, nil): totals.fnFarOnNoDrop += 1
                case (false, _): totals.fnFarOnDrop += 1
                }
                guard near else { continue }
                totals.fnNear += 1
                guard let band else { continue }
                let height = (band.top - band.bottom) / spacingPt
                totals.fnNearBandHeight[Int((height * 4).rounded()), default: 0] += 1
                totals.fnNearBandColumns[min(band.columns, 64), default: 0] += 1
                guard band.reason == .residual else { continue }
                if band.maxColumnLevels > band.levels { totals.fnNearOnResidualMulti += 1 }
                if band.maxColumnLevels != band.levels || band.minColumnLevels != band.levels {
                    totals.fnNearOnResidualMismatched += 1
                }
                if band.recoverableByLabelExclusion {
                    totals.fnNearRecoverableByLabelExclusion += 1
                }
                if band.recoverableByTrim { totals.fnNearRecoverableByTrim += 1 }
                totals.fnNearResidual[
                    min(Int((band.residualInSpaces * 20).rounded()), 40), default: 0,
                ] += 1
                totals.fnNearStep[
                    min(Int((band.stepInSpaces * 4).rounded()), 20), default: 0,
                ] += 1
            }
        }

        /// Residual first: when several discarded bands sit on one truth
        /// beam, the gate that threw away a fitted slab is the finding, and
        /// an extent drop on a one-column fragment beside it is not.
        private static func rank(_ reason: RasterBeamProbe.DropReason) -> Int {
            switch reason {
            case .residual: 0
            case .slope: 1
            case .short: 2
            }
        }

        private static func countBands(
            _ bands: [RasterBeamProbe.Band], truth: [OMRPageLabels.Beam],
            matched: Set<Int>, spacingPt: Double, into totals: inout Totals,
        ) {
            for band in bands {
                totals.bands += 1
                switch band.reason {
                case .short: totals.bandsShort += 1
                case .residual: totals.bandsResidual += 1
                case .slope: totals.bandsSlope += 1
                }
                if band.maxColumnLevels > band.levels {
                    totals.bandsMultiLevelGeometry += 1
                    if band.reason == .residual {
                        totals.bandsResidualMultiLevelGeometry += 1
                    }
                }
                var onFn = false
                var onMatched = false
                for (ti, t) in truth.enumerated() where covers(band, t, spacingPt: spacingPt) {
                    if matched.contains(ti) { onMatched = true } else { onFn = true }
                }
                if onFn { totals.bandsOnFn += 1 } else { totals.bandsOnNothing += 1 }
                switch band.reason {
                case .residual:
                    if onFn { totals.residualBandsOnFn += 1 }
                    if onMatched { totals.residualBandsOnMatched += 1 }
                case .short:
                    if onFn { totals.shortBandsOnFn += 1 }
                    if onMatched { totals.shortBandsOnMatched += 1 }
                case .slope: break
                }
            }
        }

        /// Whether a discarded band sits on `t`: they overlap in x, and
        /// `t`'s mid-line at the overlap midpoint falls inside the band.
        static func covers(
            _ band: RasterBeamProbe.Band, _ t: OMRPageLabels.Beam, spacingPt: Double,
        ) -> Bool {
            let lo = max(band.x0, t.x0)
            let hi = min(band.x1, t.x1)
            guard hi > lo else { return false }
            let mid = (lo + hi) / 2
            let y = ((t.topSlope * mid + t.topIntercept)
                + (t.botSlope * mid + t.botIntercept)) / 2
            let slack = bandToleranceInSpaces * spacingPt
            return y <= band.top + slack && y >= band.bottom - slack
        }

        /// |Δ top edge| at the midpoint of two beams' x-overlap.
        private static func gap(
            _ a: OMRPageLabels.Beam, _ b: OMRPageLabels.Beam,
        ) -> Double? {
            let lo = max(a.x0, b.x0)
            let hi = min(a.x1, b.x1)
            guard hi > lo else { return nil }
            let mid = (lo + hi) / 2
            return abs(
                (a.topSlope * mid + a.topIntercept) - (b.topSlope * mid + b.topIntercept),
            )
        }

        private static func histogram(
            _ buckets: [Int: Int], tag: String, unit: String, scale: Int,
        ) {
            for k in buckets.keys.sorted() {
                let value = scale == 1 ? String(k) : String(Double(k) / Double(scale))
                print("[beamslab][\(tag)] \(unit)=\(value) n=\(buckets[k] ?? 0)")
            }
        }

        static func report(_ t: Totals) {
            let c = RasterBeamProbe.counters
            print(
                "[beamslab][fn] total=\(t.fnTotal) near=\(t.fnNear) "
                    + "nearOnResidual=\(t.fnNearOnResidual) "
                    + "nearOnResidualMulti=\(t.fnNearOnResidualMulti) "
                    + "nearOnShort=\(t.fnNearOnShort) "
                    + "nearOnSlope=\(t.fnNearOnSlope) nearOnNoDrop=\(t.fnNearOnNoDrop) "
                    + "farOnDrop=\(t.fnFarOnDrop) farOnNoDrop=\(t.fnFarOnNoDrop)",
            )
            print(
                "[beamslab][null] residualOnFn=\(t.residualBandsOnFn) "
                    + "residualOnMatched=\(t.residualBandsOnMatched) "
                    + "shortOnFn=\(t.shortBandsOnFn) shortOnMatched=\(t.shortBandsOnMatched)",
            )
            print(
                "[beamslab][fnfix] mismatched=\(t.fnNearOnResidualMismatched) "
                    + "byLabelExclusion=\(t.fnNearRecoverableByLabelExclusion) "
                    + "byTrim=\(t.fnNearRecoverableByTrim) "
                    + "dropsByLabelExclusion="
                    + "\(c.dropResidualRecoverableByLabelExclusion) "
                    + "dropsByTrim=\(c.dropResidualRecoverableByTrim)",
            )
            histogram(t.fnNearBandHeight, tag: "fnbandheight", unit: "sp", scale: 4)
            histogram(t.fnNearBandColumns, tag: "fnbandcols", unit: "cols", scale: 1)
            histogram(t.fnNearResidual, tag: "fnresidual", unit: "sp", scale: 20)
            histogram(t.fnNearStep, tag: "fnstep", unit: "sp", scale: 4)
            print(
                "[beamslab][bands] total=\(t.bands) short=\(t.bandsShort) "
                    + "residual=\(t.bandsResidual) slope=\(t.bandsSlope) "
                    + "multiLevelGeometry=\(t.bandsMultiLevelGeometry) "
                    + "residualMultiLevel=\(t.bandsResidualMultiLevelGeometry) "
                    + "onFn=\(t.bandsOnFn) onNothing=\(t.bandsOnNothing)",
            )
            print(
                "[beamslab][intervals] total=\(c.intervals) emitted=\(c.intervalsEmitted) "
                    + "emittedMismatched=\(c.intervalsEmittedMismatched) "
                    + "dropShort=\(c.dropShort) dropShortMismatched=\(c.dropShortMismatched) "
                    + "dropResidual=\(c.dropResidual) "
                    + "dropResidualMismatched=\(c.dropResidualMismatched) "
                    + "dropSlope=\(c.dropSlope)",
            )
            print(
                "[beamslab][link] slabs=\(c.slabs) mixedLevels=\(c.slabsMixedLevels) "
                    + "runs=\(c.runsTotal) shared=\(c.runsShared) "
                    + "takeSame=\(c.runsTakenSameLevels) takeThicker=\(c.runsTakenThicker) "
                    + "takeThickerOneOpen=\(c.runsTakenThickerOneOpen) "
                    + "takeThinner=\(c.runsTakenThinner) opened=\(c.runsOpenedNew) "
                    + "openedOverlapping=\(c.runsOpenedOverlappingOpen) "
                    + "starvedColumns=\(c.slabsStarvedColumns)",
            )
        }
    }
#endif
