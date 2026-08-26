#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// WHERE a beam level dies inside the raster pipeline, counted on a real
/// corpus rather than argued from a synthetic page.
///
/// The seam ledger says 114 of 199 unmatched truth beams carry a 0.5 sp
/// prediction exactly one beam pitch away — a stacked pair with one member
/// missing. That signature is reachable from at least four places, and the
/// program's record is that reading the code picks the wrong one:
///
///   * the second slab never OPENS (the stack fuses from the first column
///     of its shorter member), so nothing is there to keep;
///   * an open slab STARVES because a merged column went to its neighbour
///     and its bridge ran out;
///   * an interval is dropped by `beamMinExtentInSpaces` after the level
///     labels fragment it;
///   * an interval is dropped by the `maxResidual` straightness gate
///     because the median smoothing relabelled a band-spanning column
///     without touching its y-geometry.
///
/// Every one of those is counted below, and the DROPPED intervals are kept
/// with their page-space band so the harness can ask the only question
/// that settles it: does a dropped band actually sit on top of one of the
/// 114? Inert unless `OMR_BEAM_SLAB_PROBE=1`, so a build without the
/// variable set runs the shipped path untouched.
enum RasterBeamProbe {
    /// Why an interval produced no beam.
    enum DropReason: String {
        /// Shorter than `beamMinExtentInSpaces`.
        case short
        /// Failed the `maxResidual` straightness gate.
        case residual
        /// Failed the slope or the wedge gate.
        case slope
    }

    /// A dropped interval's page-space footprint, in the SAME frame the
    /// emitted beams are converted to, so the harness can overlap it with
    /// the truth beams directly.
    struct Band {
        var reason: DropReason
        var pageIndex: Int
        var x0: Double
        var x1: Double
        /// Page space is y-up, so `top` ≥ `bottom`.
        var top: Double
        var bottom: Double
        /// The interval's smoothed level label.
        var levels: Int
        var columns: Int
        /// The largest / smallest level count any single column's OWN
        /// y-extent quantizes to; 0 when a column lands on no rung at
        /// all. Either one differing from `levels` is the
        /// smoothing/geometry mismatch signature.
        var maxColumnLevels: Int
        var minColumnLevels: Int
        /// The worst edge residual the fit actually saw, in staff spaces,
        /// and the biggest single-column step in the top edge. Zero for a
        /// drop that never reached the fit.
        var residualInSpaces: Double
        var stepInSpaces: Double
        /// WOULD the interval have passed the straightness gate if the
        /// columns whose own geometry disagrees with the smoothed label
        /// were kept out of the fit? And if instead the fit simply
        /// discarded its own outliers?
        ///
        /// These two are the counterfactuals for the only two repairs
        /// worth making, measured on the corpus BEFORE either was
        /// written: 4 of the 114 by label, 93 by residual. The program's
        /// record is that a fix aimed at a mechanism whose corpus share
        /// was never measured lands as a null, and the label story — the
        /// one the previous round handed over as the likely culprit —
        /// would have been exactly that.
        ///
        /// `recoverableByTrim` MIRRORS the shipped `bandFit` refit, so
        /// with that refit in place it must now read zero: an interval
        /// still recorded here as a residual drop is one the refit
        /// already declined.
        var recoverableByLabelExclusion: Bool
        var recoverableByTrim: Bool
    }

    struct Counters {
        var slabs = 0
        /// Slabs whose columns do not all agree on a level count.
        var slabsMixedLevels = 0
        var intervals = 0
        var intervalsEmitted = 0
        /// Emitted intervals holding a column whose own y-extent
        /// quantizes to a different level count than the label.
        var intervalsEmittedMismatched = 0
        var dropShort = 0
        var dropShortMismatched = 0
        var dropResidual = 0
        var dropResidualMismatched = 0
        var dropResidualRecoverableByLabelExclusion = 0
        var dropResidualRecoverableByTrim = 0
        var dropSlope = 0
        var runsTotal = 0
        /// Runs handed out as rungs across several open slabs.
        var runsShared = 0
        var runsTakenSameLevels = 0
        /// A run THICKER than the slab taking it — a fusion arriving —
        /// split by how many open slabs it covers. One means there was
        /// nobody to share with: the stack fused before its second member
        /// ever opened a slab.
        var runsTakenThicker = 0
        var runsTakenThickerOneOpen = 0
        var runsTakenThinner = 0
        var runsOpenedNew = 0
        /// A new slab opened on a run that y-overlaps a slab already
        /// open — contention, not a fresh beam.
        var runsOpenedOverlappingOpen = 0
        /// A column where a slab got nothing WHILE a run overlapped it:
        /// the run went to another slab. This is starvation; the plain
        /// `missing` case is a stem or the beam's end.
        var slabsStarvedColumns = 0
    }

    static let enabled =
        ProcessInfo.processInfo.environment["OMR_BEAM_SLAB_PROBE"] == "1"
    nonisolated(unsafe) static var counters = Counters()
    nonisolated(unsafe) static var bands: [Band] = []

    static func resetBands() {
        bands.removeAll(keepingCapacity: true)
    }

    static func resetAll() {
        counters = Counters()
        bands.removeAll(keepingCapacity: true)
    }

    // MARK: - Linking

    static func noteRuns(_ count: Int) {
        guard enabled else { return }
        counters.runsTotal += count
    }

    static func noteShare() {
        guard enabled else { return }
        counters.runsShared += 1
    }

    static func noteTake(
        run: RasterPage.BeamColumn, slabLevels: Int, openCovering: Int,
    ) {
        guard enabled else { return }
        if run.levels == slabLevels {
            counters.runsTakenSameLevels += 1
        } else if run.levels > slabLevels {
            counters.runsTakenThicker += 1
            if openCovering <= 1 { counters.runsTakenThickerOneOpen += 1 }
        } else {
            counters.runsTakenThinner += 1
        }
    }

    static func noteStarved() {
        guard enabled else { return }
        counters.slabsStarvedColumns += 1
    }

    static func noteOpen(overlapsOpen: Bool) {
        guard enabled else { return }
        counters.runsOpenedNew += 1
        if overlapsOpen { counters.runsOpenedOverlappingOpen += 1 }
    }

    static func noteSlab(_ slab: [RasterPage.BeamColumn]) {
        guard enabled else { return }
        counters.slabs += 1
        if let first = slab.first, slab.contains(where: { $0.levels != first.levels }) {
            counters.slabsMixedLevels += 1
        }
    }

    // MARK: - Fitting

    static func noteInterval(
        _ interval: [RasterPage.BeamColumn], spacingPx: Double,
        drop: DropReason?, transform: PageTransform, pageIndex: Int,
    ) {
        guard enabled, let first = interval.first, let last = interval.last else { return }
        counters.intervals += 1
        let own = columnLevels(interval, spacingPx: spacingPx)
        let peak = own.max() ?? 0
        let floor = own.min() ?? 0
        let mismatched = peak != first.levels || floor != first.levels
        switch drop {
        case nil:
            counters.intervalsEmitted += 1
            if mismatched { counters.intervalsEmittedMismatched += 1 }
            return
        case .short:
            counters.dropShort += 1
            if mismatched { counters.dropShortMismatched += 1 }
        case .residual:
            counters.dropResidual += 1
            if mismatched { counters.dropResidualMismatched += 1 }
        case .slope:
            counters.dropSlope += 1
        }
        var band = Band(
            reason: drop ?? .short, pageIndex: pageIndex,
            x0: Double(transform.point(x: Double(first.x), y: 0).x),
            x1: Double(transform.point(x: Double(last.x + 1), y: 0).x),
            top: Double(transform.point(x: 0, y: Double(interval.map(\.y0).min() ?? first.y0)).y),
            bottom: Double(
                transform.point(x: 0, y: Double((interval.map(\.y1).max() ?? last.y1) + 1)).y,
            ),
            levels: first.levels, columns: interval.count,
            maxColumnLevels: peak, minColumnLevels: floor,
            residualInSpaces: 0, stepInSpaces: 0,
            recoverableByLabelExclusion: false, recoverableByTrim: false,
        )
        if drop == .residual {
            describeResidual(interval, own: own, spacingPx: spacingPx, into: &band)
            if band.recoverableByLabelExclusion {
                counters.dropResidualRecoverableByLabelExclusion += 1
            }
            if band.recoverableByTrim { counters.dropResidualRecoverableByTrim += 1 }
        }
        bands.append(band)
    }

    /// Each column's OWN level count, re-quantized from its y-extent.
    ///
    /// Re-quantized rather than remembered on the column: the label
    /// `BeamColumn.levels` carries is the SMOOTHED one by the time an
    /// interval exists, and the whole question is whether that label still
    /// describes the geometry underneath it.
    private static func columnLevels(
        _ interval: [RasterPage.BeamColumn], spacingPx: Double,
    ) -> [Int] {
        interval.map {
            RasterPage.beamLevels(
                runLengthPx: Double($0.y1 - $0.y0 + 1), spacingPx: spacingPx,
            ) ?? 0
        }
    }

    /// How badly the straightness gate was missed, and whether either
    /// candidate repair would have cleared it.
    private static func describeResidual(
        _ interval: [RasterPage.BeamColumn], own: [Int], spacingPx: Double,
        into band: inout Band,
    ) {
        let tops = interval.map { (Double($0.x), Double($0.y0)) }
        let bottoms = interval.map { (Double($0.x), Double($0.y1 + 1)) }
        if let topFit = RasterPage.leastSquares(tops),
           let botFit = RasterPage.leastSquares(bottoms)
        {
            band.residualInSpaces = max(
                RasterPage.maxResidual(tops, topFit),
                RasterPage.maxResidual(bottoms, botFit),
            ) / spacingPx
            band.recoverableByTrim = straight(
                keeping: interval.indices.filter {
                    abs(Double(interval[$0].y0) - topFit.y(at: Double(interval[$0].x)))
                        <= RasterPage.beamStraightnessInSpaces * spacingPx
                        && abs(Double(interval[$0].y1 + 1)
                            - botFit.y(at: Double(interval[$0].x)))
                        <= RasterPage.beamStraightnessInSpaces * spacingPx
                },
                of: interval, spacingPx: spacingPx,
            )
        }
        band.stepInSpaces = zip(interval, interval.dropFirst())
            .map { abs(Double($1.y0 - $0.y0)) / spacingPx }
            .max() ?? 0
        band.recoverableByLabelExclusion = straight(
            keeping: interval.indices.filter { own[$0] == interval[$0].levels },
            of: interval, spacingPx: spacingPx,
        )
    }

    /// Whether the kept columns alone clear the straightness gate while
    /// still being most of the interval and still spanning a beam.
    private static func straight(
        keeping kept: [Int], of interval: [RasterPage.BeamColumn], spacingPx: Double,
    ) -> Bool {
        guard kept.count >= 2,
              Double(kept.count) >= RasterPage.beamTrimKeepFraction * Double(interval.count),
              let lo = kept.first, let hi = kept.last,
              Double(interval[hi].x - interval[lo].x + 1)
              >= RasterPage.beamMinExtentInSpaces * spacingPx
        else { return false }
        let tops = kept.map { (Double(interval[$0].x), Double(interval[$0].y0)) }
        let bottoms = kept.map { (Double(interval[$0].x), Double(interval[$0].y1 + 1)) }
        guard let topFit = RasterPage.leastSquares(tops),
              let botFit = RasterPage.leastSquares(bottoms)
        else { return false }
        let gate = RasterPage.beamStraightnessInSpaces * spacingPx
        return RasterPage.maxResidual(tops, topFit) <= gate
            && RasterPage.maxResidual(bottoms, botFit) <= gate
    }
}
