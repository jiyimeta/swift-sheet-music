#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// Why the beam seam costs duration points, in NOTE-level units.
    ///
    /// `beamPR` answers "how many beams did the detector find"; it cannot
    /// answer "how many notes lost a beam level, and to which mechanism" —
    /// and those are different questions, because the match criterion is
    /// purely vertical (see `OMRSeamMetrics.beamPR`) and because one
    /// missing beam over a six-note run costs six notes while one over a
    /// two-note run costs two.
    ///
    /// The ledger below mirrors `PDFImporter.fullBeamSpans`: a beam covers
    /// a stem when the stem's x is inside the beam's x-range padded by
    /// `beamEndpointPad` AND one of the stem's ends is within
    /// `BeamReach.fullSpatia` of the beam's mid-edge at that x. Counting
    /// that predicate on both sides gives each stem a truth level and a
    /// predicted level; every lost level is then attributed to exactly one
    /// of the three mechanisms a raster beam detector can fail by:
    ///
    ///   * TRUNCATION (`trunc`) — the truth beam HAS a predicted partner,
    ///     but the partner's x-range stops short of this stem.
    ///   * LEVEL MISS (`levelMiss`) — the truth beam has no partner, and a
    ///     predicted beam x-overlaps it ONE BEAM PITCH away (0.75 sp): the
    ///     detector put a slab across this run and emitted one rung too
    ///     few, so 16ths read as 8ths.
    ///   * ABSENT BEAM (`absentMiss`) — the truth beam has no partner and
    ///     nothing was predicted anywhere near it.
    ///
    /// Gained levels (a predicted beam covering a stem with no truth
    /// partner) are counted separately; those promote quarters to eighths.
    /// `windowDrop` re-measures the truncation shortfall with NO pad,
    /// which is what `PDFImporter.beamWindow` hands a tuplet.
    enum OMRBeamDiagnostics {
        /// Mirrors `PDFImporter.beamEndpointPad` (pt) and
        /// `PDFImporter.BeamReach.fullSpatia` (staff spaces). Duplicated
        /// rather than read across because the importer's values are
        /// `CGFloat` on a type this helper does not otherwise touch, and
        /// because a diagnostic that silently followed a future retune
        /// would stop describing the run it was read against.
        static let endpointPadPt = 1.5
        static let fullReachInSpaces = 2.0
        /// Two truth beams closer than this are one stack.
        ///
        /// MEASURED IN TOP-EDGE DISTANCE, which is what the metric has:
        /// adjacent levels of a stack are `beamSingleThickness +
        /// beamGap` = 0.5 + 0.25 = 0.75 sp apart top-to-top, and the level
        /// after that is 1.5 sp. 1.0 sits in that gap. (The first version
        /// of this probe used 0.6 — the INK gap rather than the edge
        /// distance — and consequently reported that not one of the 199
        /// unmatched truth beams had a stacked neighbour, which is not a
        /// property a real corpus can have.)
        static let stackGapInSpaces = 1.0

        struct Totals {
            var pages = 0
            /// Truth stems carrying at least one truth beam level.
            var beamedStems = 0
            var exactStems = 0
            var lostAllStems = 0
            var underCountStems = 0
            var overCountStems = 0
            /// Level-instances (stem × beam), the unit the shares below
            /// are fractions of.
            var truthLevels = 0
            var lostLevels = 0
            var lostByTruncation = 0
            var lostByFusionMiss = 0
            var lostByThinMiss = 0
            var gainedLevels = 0
            /// Stem inclusions a matched beam's RAW x-range loses — the
            /// same shortfall as `lostByTruncation`, re-measured without
            /// `beamEndpointPad`. `PDFImporter.beamWindow` bounds a
            /// tuplet's member run by the raw `quad.xRange` with no pad at
            /// all, so this, not the padded count, is what a tuplet sees.
            var windowDrops = 0
            /// Matched beams the prediction demotes from FULL to STUB:
            /// truth spans ≥ 2 stems, prediction spans ≤ 1. A stub adds a
            /// SECONDARY level to one owner instead of a primary to the
            /// group, so the whole run's duration changes without any
            /// level going missing in the ledger above.
            var demotedToStub = 0
            /// Truth beams that matched nothing, by mechanism.
            var fnTotal = 0
            var fnFusion = 0
            var fnStackAllLost = 0
            var fnIsolated = 0
            /// Unmatched truth beams by x-extent (0.25 sp buckets) and by
            /// how deep their truth stack is.
            var fnExtent: [Int: Int] = [:]
            var fnDepth: [Int: Int] = [:]
            /// Unmatched truth beams by top-edge distance to the NEAREST
            /// x-overlapping predicted beam, in 0.25 sp buckets (key 99 =
            /// no predicted beam overlaps it in x at all). This is the
            /// histogram that separates "the detector put a slab there but
            /// at the wrong level" — a fusion / level-count error, which
            /// lands near 0.75 sp — from "nothing was detected here".
            var fnNearestPred: [Int: Int] = [:]
            /// Of the unmatched truth beams that DO have a predicted beam
            /// one beam-pitch away: whether the missing one is the top of
            /// its truth stack, and how thick that near prediction is
            /// (0.25 sp buckets).
            ///
            /// These two settle which failure it is. A ladder
            /// misquantization — a fused 1.25 sp band read as one beam —
            /// would emit a 1.25 sp segment covering the whole band, so
            /// the missing truth beam would be the LOWER one and the near
            /// prediction would be thick. A slab that was linked but then
            /// lost a level emits a normal 0.5 sp beam.
            var fnTopOfStack = 0
            var fnBottomOfStack = 0
            var fnNearPredThickness: [Int: Int] = [:]
            /// Predicted beams that matched nothing.
            var fpTotal = 0
            var fpNearMatchedTruth = 0
            var fpIsolated = 0
            var fpExtent: [Int: Int] = [:]
            /// Per MATCHED end: how far the prediction's x-range stops
            /// short of the truth's, in 0.5 pt buckets (key -1 = the
            /// prediction overhangs).
            var shortfall: [Int: Int] = [:]
            var endsBeyondPad = 0
            var endsTotal = 0
        }

        /// One page's contribution, plus the same numbers for its own row.
        static func accumulate(
            predicted: [OMRPageLabels.Beam], truth: [OMRPageLabels.Beam],
            truthPaths: [OMRPageLabels.Path], spacingPt: Double,
            into totals: inout Totals,
        ) -> Totals {
            var page = Totals()
            page.pages = 1
            guard spacingPt > 0 else {
                totals.pages += 1
                return page
            }
            let assign = OMRSeamMetrics.beamAssignment(
                predicted: predicted, truth: truth, staffSpacingPt: spacingPt,
            )
            var partner = [Int: Int]() // truth index → predicted index
            for pair in assign {
                partner[pair.ti] = pair.pi
            }

            classifyBeams(
                predicted: predicted, truth: truth, partner: partner,
                spacingPt: spacingPt, into: &page,
            )
            let stems = truthPaths.filter { $0.kind == "vertical" }
            ledger(
                predicted: predicted, truth: truth, partner: partner,
                stems: stems, spacingPt: spacingPt, into: &page,
            )
            stubDemotion(
                predicted: predicted, truth: truth, partner: partner,
                stems: stems, spacingPt: spacingPt, into: &page,
            )
            merge(page, into: &totals)
            return page
        }

        // MARK: - Mechanism classification of the unmatched beams

        private static func classifyBeams(
            predicted: [OMRPageLabels.Beam], truth: [OMRPageLabels.Beam],
            partner: [Int: Int], spacingPt: Double, into page: inout Totals,
        ) {
            let matchedP = Set(partner.values)
            for (ti, t) in truth.enumerated() {
                if let pi = partner[ti] {
                    accumulateShortfall(predicted[pi], truth: t, into: &page)
                    continue
                }
                let neighbours = stackNeighbours(of: ti, in: truth, spacingPt: spacingPt)
                page.fnTotal += 1
                page.fnExtent[Int(((t.x1 - t.x0) / spacingPt * 4).rounded(.down)), default: 0] += 1
                page.fnDepth[neighbours.count + 1, default: 0] += 1
                let gaps = predicted.indices.compactMap { pi in
                    overlapMidGap(predicted[pi], t).map { (gap: $0, pi: pi) }
                }
                let nearest = gaps.min { $0.gap < $1.gap }
                page.fnNearestPred[
                    nearest.map { Int(($0.gap / spacingPt * 4).rounded()) } ?? 99, default: 0,
                ] += 1
                if let nearest, nearest.gap <= stackGapInSpaces * spacingPt {
                    let thick = predicted[nearest.pi].lineWidthPt / spacingPt
                    page.fnNearPredThickness[Int((thick * 4).rounded()), default: 0] += 1
                    // A beam's top edge is ABOVE its neighbour's in page
                    // space, where y grows upward — so the topmost member
                    // of a stack has the LARGEST top-edge y.
                    let above = neighbours.contains { other in
                        topEdgeAtOverlapMid(truth[other], t).map { $0 > 0 } ?? false
                    }
                    if above { page.fnBottomOfStack += 1 } else { page.fnTopOfStack += 1 }
                }
                if neighbours.contains(where: { partner[$0] != nil }) {
                    page.fnFusion += 1
                } else if neighbours.isEmpty {
                    page.fnIsolated += 1
                } else {
                    page.fnStackAllLost += 1
                }
            }
            for (pi, p) in predicted.enumerated() where !matchedP.contains(pi) {
                page.fpTotal += 1
                page.fpExtent[Int(((p.x1 - p.x0) / spacingPt * 4).rounded(.down)), default: 0] += 1
                let near = truth.indices.contains { ti in
                    partner[ti] != nil
                        && (overlapMidGap(p, truth[ti]) ?? .infinity)
                        <= stackGapInSpaces * spacingPt
                }
                if near { page.fpNearMatchedTruth += 1 } else { page.fpIsolated += 1 }
            }
        }

        private static func accumulateShortfall(
            _ p: OMRPageLabels.Beam, truth t: OMRPageLabels.Beam, into page: inout Totals,
        ) {
            for shortfall in [p.x0 - t.x0, t.x1 - p.x1] {
                page.endsTotal += 1
                if shortfall > endpointPadPt { page.endsBeyondPad += 1 }
                let key = shortfall <= 0 ? -1 : Int((shortfall * 2).rounded(.down))
                page.shortfall[key, default: 0] += 1
            }
        }

        /// Indices of the truth beams stacked with `ti` — x-overlapping and
        /// within `stackGapInSpaces` of it at the overlap midpoint.
        private static func stackNeighbours(
            of ti: Int, in truth: [OMRPageLabels.Beam], spacingPt: Double,
        ) -> [Int] {
            truth.indices.filter { other in
                other != ti
                    && (overlapMidGap(truth[ti], truth[other]) ?? .infinity)
                    <= stackGapInSpaces * spacingPt
            }
        }

        /// Signed `a.top − b.top` at the midpoint of their x-overlap; nil
        /// when they do not overlap in x. Positive means `a` sits above
        /// `b` (page space is y-up).
        private static func topEdgeAtOverlapMid(
            _ a: OMRPageLabels.Beam, _ b: OMRPageLabels.Beam,
        ) -> Double? {
            let lo = max(a.x0, b.x0)
            let hi = min(a.x1, b.x1)
            guard hi > lo else { return nil }
            let mid = (lo + hi) / 2
            return (a.topSlope * mid + a.topIntercept)
                - (b.topSlope * mid + b.topIntercept)
        }

        /// |Δ top edge| at the midpoint of two beams' x-overlap, or nil
        /// when they do not overlap in x at all.
        private static func overlapMidGap(
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

        // MARK: - Note-level ledger

        /// Whether `beam` would be counted as covering `stem` by
        /// `PDFImporter.fullBeamSpans`.
        static func covers(
            _ beam: OMRPageLabels.Beam, stem: OMRPageLabels.Path, spacingPt: Double,
            padPt: Double = endpointPadPt,
        ) -> Bool {
            let x = (stem.rectPt[0] + stem.rectPt[2]) / 2
            guard x >= beam.x0 - padPt, x <= beam.x1 + padPt else {
                return false
            }
            let top = beam.topSlope * x + beam.topIntercept
            let bot = beam.botSlope * x + beam.botIntercept
            let mid = (top + bot) / 2
            let d = min(abs(stem.rectPt[1] - mid), abs(stem.rectPt[3] - mid))
            return d <= fullReachInSpaces * spacingPt
        }

        private static func ledger(
            predicted: [OMRPageLabels.Beam], truth: [OMRPageLabels.Beam],
            partner: [Int: Int], stems: [OMRPageLabels.Path],
            spacingPt: Double, into page: inout Totals,
        ) {
            for stem in stems {
                let truthCover = truth.indices.filter {
                    covers(truth[$0], stem: stem, spacingPt: spacingPt)
                }
                let predCover = predicted.indices.filter {
                    covers(predicted[$0], stem: stem, spacingPt: spacingPt)
                }
                guard !truthCover.isEmpty else {
                    page.gainedLevels += predCover.count
                    if !predCover.isEmpty { page.overCountStems += 1 }
                    continue
                }
                page.beamedStems += 1
                page.truthLevels += truthCover.count
                var lost = 0
                for ti in truthCover {
                    guard let pi = partner[ti] else {
                        lost += 1
                        attributeMiss(
                            ti: ti, truth: truth, predicted: predicted,
                            spacingPt: spacingPt, into: &page,
                        )
                        continue
                    }
                    if !covers(predicted[pi], stem: stem, spacingPt: spacingPt) {
                        lost += 1
                        page.lostByTruncation += 1
                    } else if !covers(
                        predicted[pi], stem: stem, spacingPt: spacingPt, padPt: 0,
                    ) {
                        page.windowDrops += 1
                    }
                }
                page.lostLevels += lost
                if predCover.count > truthCover.count {
                    page.gainedLevels += predCover.count - truthCover.count
                    page.overCountStems += 1
                }
                if lost == 0, predCover.count == truthCover.count {
                    page.exactStems += 1
                } else if lost == truthCover.count, predCover.isEmpty {
                    page.lostAllStems += 1
                } else if lost > 0 {
                    page.underCountStems += 1
                }
            }
        }

        /// A missing truth beam is a LEVEL miss when the detector did put a
        /// slab across it and merely emitted one rung too few — measured
        /// as a predicted beam x-overlapping it within `stackGapInSpaces`,
        /// i.e. the one-beam-pitch signature — and an ABSENT beam
        /// otherwise. Measured rather than inferred from the truth stack:
        /// a partial secondary beam makes the primary's own stems look
        /// "stacked" even where they carry one level.
        private static func attributeMiss(
            ti: Int, truth: [OMRPageLabels.Beam], predicted: [OMRPageLabels.Beam],
            spacingPt: Double, into page: inout Totals,
        ) {
            let nearest = predicted.compactMap { overlapMidGap($0, truth[ti]) }.min()
            if let nearest, nearest <= stackGapInSpaces * spacingPt {
                page.lostByFusionMiss += 1
            } else {
                page.lostByThinMiss += 1
            }
        }

        /// Matched beams the prediction demotes from full to stub.
        static func stubDemotion(
            predicted: [OMRPageLabels.Beam], truth: [OMRPageLabels.Beam],
            partner: [Int: Int], stems: [OMRPageLabels.Path],
            spacingPt: Double, into page: inout Totals,
        ) {
            for (ti, pi) in partner {
                let tSpan = stems.count { covers(truth[ti], stem: $0, spacingPt: spacingPt) }
                guard tSpan >= 2 else { continue }
                let pSpan = stems.count {
                    covers(predicted[pi], stem: $0, spacingPt: spacingPt)
                }
                if pSpan <= 1 { page.demotedToStub += 1 }
            }
        }

        // MARK: - Accumulation and reporting

        static func merge(_ src: Totals, into dst: inout Totals) {
            dst.pages += src.pages
            dst.beamedStems += src.beamedStems
            dst.exactStems += src.exactStems
            dst.lostAllStems += src.lostAllStems
            dst.underCountStems += src.underCountStems
            dst.overCountStems += src.overCountStems
            dst.truthLevels += src.truthLevels
            dst.lostLevels += src.lostLevels
            dst.lostByTruncation += src.lostByTruncation
            dst.lostByFusionMiss += src.lostByFusionMiss
            dst.lostByThinMiss += src.lostByThinMiss
            dst.gainedLevels += src.gainedLevels
            dst.windowDrops += src.windowDrops
            dst.demotedToStub += src.demotedToStub
            dst.fnTotal += src.fnTotal
            dst.fnFusion += src.fnFusion
            dst.fnStackAllLost += src.fnStackAllLost
            dst.fnIsolated += src.fnIsolated
            dst.fpTotal += src.fpTotal
            dst.fpNearMatchedTruth += src.fpNearMatchedTruth
            dst.fpIsolated += src.fpIsolated
            dst.endsBeyondPad += src.endsBeyondPad
            dst.endsTotal += src.endsTotal
            for (k, v) in src.fnExtent {
                dst.fnExtent[k, default: 0] += v
            }
            for (k, v) in src.fnDepth {
                dst.fnDepth[k, default: 0] += v
            }
            for (k, v) in src.fnNearestPred {
                dst.fnNearestPred[k, default: 0] += v
            }
            for (k, v) in src.fnNearPredThickness {
                dst.fnNearPredThickness[k, default: 0] += v
            }
            dst.fnTopOfStack += src.fnTopOfStack
            dst.fnBottomOfStack += src.fnBottomOfStack
            for (k, v) in src.fpExtent {
                dst.fpExtent[k, default: 0] += v
            }
            for (k, v) in src.shortfall {
                dst.shortfall[k, default: 0] += v
            }
        }

        /// The one-line form, used for both the per-page rows and the
        /// aggregate so the two are diffable.
        static func row(_ t: Totals) -> String {
            "beamedStems=\(t.beamedStems) exact=\(t.exactStems) "
                + "lostAll=\(t.lostAllStems) under=\(t.underCountStems) "
                + "over=\(t.overCountStems) truthLevels=\(t.truthLevels) "
                + "lost=\(t.lostLevels) trunc=\(t.lostByTruncation) "
                + "levelMiss=\(t.lostByFusionMiss) absentMiss=\(t.lostByThinMiss) "
                + "gained=\(t.gainedLevels) windowDrop=\(t.windowDrops) "
                + "stubDemote=\(t.demotedToStub) fn=\(t.fnTotal) fp=\(t.fpTotal)"
        }

        static func report(_ t: Totals) {
            print("[beamdiag][SUMMARY] pages=\(t.pages) " + row(t))
            print(
                "[beamdiag][fn] total=\(t.fnTotal) stackNeighbourMatched=\(t.fnFusion) "
                    + "stackAllLost=\(t.fnStackAllLost) isolated=\(t.fnIsolated)",
            )
            print(
                "[beamdiag][fp] total=\(t.fpTotal) "
                    + "nearMatchedTruth=\(t.fpNearMatchedTruth) isolated=\(t.fpIsolated)",
            )
            print(
                "[beamdiag][ends] total=\(t.endsTotal) beyondPad=\(t.endsBeyondPad) "
                    + "padPt=\(endpointPadPt)",
            )
            for k in t.shortfall.keys.sorted() {
                let label = k < 0 ? "overhang" : String(format: "%.1f", Double(k) / 2)
                print("[beamdiag][shortfall] pt=\(label) n=\(t.shortfall[k] ?? 0)")
            }
            for k in t.fnExtent.keys.sorted() {
                print("[beamdiag][fnextent] sp=\(Double(k) / 4) n=\(t.fnExtent[k] ?? 0)")
            }
            for k in t.fnDepth.keys.sorted() {
                print("[beamdiag][fndepth] stack=\(k) n=\(t.fnDepth[k] ?? 0)")
            }
            print(
                "[beamdiag][fnstack] top=\(t.fnTopOfStack) bottom=\(t.fnBottomOfStack)",
            )
            for k in t.fnNearPredThickness.keys.sorted() {
                print(
                    "[beamdiag][fnpredthick] sp=\(Double(k) / 4) "
                        + "n=\(t.fnNearPredThickness[k] ?? 0)",
                )
            }
            for k in t.fnNearestPred.keys.sorted() {
                let label = k == 99 ? "none" : String(Double(k) / 4)
                print("[beamdiag][fnpredgap] sp=\(label) n=\(t.fnNearestPred[k] ?? 0)")
            }
            for k in t.fpExtent.keys.sorted() {
                print("[beamdiag][fpextent] sp=\(Double(k) / 4) n=\(t.fpExtent[k] ?? 0)")
            }
        }
    }
#endif
