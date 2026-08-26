#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

extension RasterPage {
    /// A straight-line fit `y = slope·x + intercept`, in pixel space.
    struct EdgeFit {
        var slope: Double
        var intercept: Double

        func y(at x: Double) -> Double {
            slope * x + intercept
        }
    }

    /// How far past a fitted slab's last column the beam's x-range may be
    /// extended, in staff spaces, while the ink still spans the fitted
    /// band. See `extendedSpan`.
    ///
    /// NOT BINDING, and that is the finding. Swept through the hybrid on
    /// 198 renders, 0.2 / 0.35 / 0.6 all measure pitch p50 94, dur p50
    /// 78 — identical to the digit. The walk stops because the ink stops,
    /// which is the beam's real end; the bound only exists so that a
    /// notehead abutting a beam end (~1.3 sp wide, and it fills the band
    /// too) cannot be walked into. 0.35 is the middle of the measured
    /// plateau rather than either edge.
    static let beamEndExtendInSpaces = 0.35

    /// One constant-level interval of a slab → its `k` beam segments, or
    /// none when it fails the straightness or slope gates. See `bandFit`
    /// for what "straight" means once speckle is allowed for.
    static func quads(
        for interval: [BeamColumn], mask: InkMask, spacingPx: Double,
        transform: PageTransform, pageIndex: Int,
    ) -> [PathSegment] {
        guard let levels = interval.first?.levels else { return [] }
        guard let band = bandFit(for: interval, spacingPx: spacingPx) else {
            RasterBeamProbe.noteInterval(
                interval, spacingPx: spacingPx, drop: .residual,
                transform: transform, pageIndex: pageIndex,
            )
            return []
        }
        let (topFit, botFit, firstX, lastX) = (band.top, band.bottom, band.firstX, band.lastX)

        // Pixel space is y-down and page space y-up, so a pixel-space
        // slope becomes its negation in page space; the 72/dpi scale
        // cancels between rise and run.
        guard abs(topFit.slope) <= beamMaxSlope,
              // A wedge — one edge steeper than the other — is not a
              // beam. Thickness constancy backstops the ladder, which
              // only ever saw the band's total.
              abs(topFit.slope - botFit.slope) <= beamMaxSlope / 2
        else {
            RasterBeamProbe.noteInterval(
                interval, spacingPx: spacingPx, drop: .slope,
                transform: transform, pageIndex: pageIndex,
            )
            return []
        }
        RasterBeamProbe.noteInterval(
            interval, spacingPx: spacingPx, drop: nil,
            transform: transform, pageIndex: pageIndex,
        )

        let (xLeft, xRight) = extendedSpan(
            firstX: firstX, lastX: lastX, mask: mask, spacingPx: spacingPx,
            topFit: topFit, botFit: botFit,
        )
        return (0 ..< levels).map { level in
            segment(
                level: level, of: levels, topFit: topFit, botFit: botFit,
                xLeft: xLeft, xRight: xRight,
                transform: transform, pageIndex: pageIndex,
            )
        }
    }

    /// Smallest share of an interval's columns a refit may keep, as a
    /// fraction. `OMR_BEAM_TRIM_KEEP` overrides it for a sweep, and 1.0
    /// switches the refit off entirely — a refit only ever runs on an
    /// interval whose plain fit already failed, so at least one column
    /// misses the gate and no refit can keep them all.
    ///
    /// This fraction is the whole safety argument for the second pass.
    /// Speckle is LOCAL: one or two columns miss the gate and the rest
    /// of the edge is already straight, so a refit keeps nearly all of
    /// them. A curve misses it EVERYWHERE — the columns within tolerance
    /// of a chord through a parabola are two thin bands either side of
    /// its quarter points, about a third of the run — so a slur grazing a
    /// stem row cannot be trimmed into a beam. Slurs are still not
    /// detected as anything, which is why that has to be structural here
    /// rather than left to a threshold.
    ///
    /// Swept on v2-eval. DURATION IS FLAT ACROSS THE WHOLE RANGE — every
    /// value gives dur p50 82.0, mean 69.7, and the SAME 13 renders
    /// better / 0 worse against the pre-refit baseline, per render to the
    /// digit. So the objective this stage is tuned against cannot choose,
    /// and the beam seam's own precision is the tiebreaker:
    ///
    ///     value   beams tp   fp    fn
    ///     (none)      2353   383   199
    ///     0.50        2528   924    24
    ///     0.75        2528   924    24
    ///     0.90        2521   574    31
    ///     0.95        2519   442    33
    ///
    /// 0.90 rather than 0.95 because the ceiling is what binds on SHORT
    /// intervals, not the ratio: a refit needs `ceil(f·n)` columns, so
    /// 0.95 cannot trim a single column until an interval is 20 wide.
    /// The shortest legal beam is 1.1 sp — about 14 columns at 200dpi,
    /// and the measured minimum, a dotted-eighth's hook, is 1.3 — so 0.95
    /// would be structurally blind to speckle on exactly the partial
    /// beams that decide a dotted rhythm. 0.90 is blind only below 10
    /// columns, which is under the extent gate anyway.
    static let beamTrimKeepFraction = sweepOverride("OMR_BEAM_TRIM_KEEP") ?? 0.9

    /// The band's two fitted edges and the x-range they were fitted
    /// over, or nil when the ink is not straight enough to be a beam.
    ///
    /// TWO PASSES, and the ordering is the point. The first is the plain
    /// least-squares fit over every column; when it clears
    /// `beamStraightnessInSpaces` this function returns it unchanged, so
    /// every beam the stage already emits is emitted exactly as before.
    /// The second pass only ever sees an interval the first REJECTED: it
    /// drops the columns that miss the gate and refits the rest.
    ///
    /// Measured on v2-eval, which is why the second pass exists at all:
    /// all 114 of the unmatched truth beams that carry a prediction one
    /// beam pitch away sit under an interval this gate discarded, and 83
    /// of them miss it by less than 0.13 sp — one or two columns of
    /// speckle on an otherwise straight edge, not curved ink. A refit
    /// without those columns clears 93 of the 114. (The fusion story this
    /// was expected to be — a band-spanning column the median smoothing
    /// relabelled — accounts for 30 of them, and excluding columns by
    /// label rather than by residual recovers 4.)
    static func bandFit(
        for interval: [BeamColumn], spacingPx: Double,
    ) -> (top: EdgeFit, bottom: EdgeFit, firstX: Int, lastX: Int)? {
        guard let first = interval.first, let last = interval.last else { return nil }
        let tops = interval.map { (Double($0.x), Double($0.y0)) }
        let bottoms = interval.map { (Double($0.x), Double($0.y1 + 1)) }
        guard let topFit = leastSquares(tops), let botFit = leastSquares(bottoms) else {
            return nil
        }
        let gate = beamStraightnessInSpaces * spacingPx
        if maxResidual(tops, topFit) <= gate, maxResidual(bottoms, botFit) <= gate {
            return (topFit, botFit, first.x, last.x)
        }
        let kept = interval.indices.filter {
            abs(tops[$0].1 - topFit.y(at: tops[$0].0)) <= gate
                && abs(bottoms[$0].1 - botFit.y(at: bottoms[$0].0)) <= gate
        }
        return refit(kept: kept, of: interval, tops: tops, bottoms: bottoms, spacingPx: spacingPx)
    }

    /// The refit over `kept`, subject to keeping enough of the interval
    /// and still spanning a beam.
    private static func refit(
        kept: [Int], of interval: [BeamColumn],
        tops: [(Double, Double)], bottoms: [(Double, Double)], spacingPx: Double,
    ) -> (top: EdgeFit, bottom: EdgeFit, firstX: Int, lastX: Int)? {
        guard kept.count >= 2,
              Double(kept.count) >= beamTrimKeepFraction * Double(interval.count),
              let lo = kept.first, let hi = kept.last,
              Double(interval[hi].x - interval[lo].x + 1) >= beamMinExtentInSpaces * spacingPx,
              let topFit = leastSquares(kept.map { tops[$0] }),
              let botFit = leastSquares(kept.map { bottoms[$0] })
        else { return nil }
        let gate = beamStraightnessInSpaces * spacingPx
        guard maxResidual(kept.map { tops[$0] }, topFit) <= gate,
              maxResidual(kept.map { bottoms[$0] }, botFit) <= gate
        else { return nil }
        return (topFit, botFit, interval[lo].x, interval[hi].x)
    }

    /// Level `i` of a `k`-level band, placed at FIXED FRACTIONS of the
    /// fitted band rather than by stepping down from the top edge.
    ///
    /// Fractions are exact at both fitted edges and accumulate no error,
    /// and each level inherits both slopes. Re-scanning the ink for a
    /// faint local minimum between levels would be worse, not better: at
    /// these dpis the gap is 3–8 px and, once degraded, its "minimum" is
    /// one or two grey pixels — noisier than the model it would replace.
    private static func segment(
        level: Int, of levels: Int, topFit: EdgeFit, botFit: EdgeFit,
        xLeft: Double, xRight: Double,
        transform: PageTransform, pageIndex: Int,
    ) -> PathSegment {
        let total = ladderThicknessInSpaces(levels: levels)
        let pitch = beamSingleThicknessInSpaces + beamGapInSpaces
        let fracTop = Double(level) * pitch / total
        let fracBot = (Double(level) * pitch + beamSingleThicknessInSpaces) / total

        func edge(_ fraction: Double, at x: Double) -> Double {
            let top = topFit.y(at: x)
            return top + fraction * (botFit.y(at: x) - top)
        }

        let topLeft = transform.point(x: xLeft, y: edge(fracTop, at: xLeft))
        let topRight = transform.point(x: xRight, y: edge(fracTop, at: xRight))
        let botLeft = transform.point(x: xLeft, y: edge(fracBot, at: xLeft))
        let botRight = transform.point(x: xRight, y: edge(fracBot, at: xRight))

        let topSlope = (topRight.y - topLeft.y) / (topRight.x - topLeft.x)
        let botSlope = (botRight.y - botLeft.y) / (botRight.x - botLeft.x)
        let quad = BeamQuad(
            xRange: topLeft.x ... topRight.x,
            topSlope: topSlope,
            topIntercept: topLeft.y - topSlope * topLeft.x,
            botSlope: botSlope,
            botIntercept: botLeft.y - botSlope * botLeft.x,
            pageIndex: pageIndex,
        )
        let minY = min(botLeft.y, botRight.y)
        let maxY = max(topLeft.y, topRight.y)
        return PathSegment(
            kind: .beam,
            rect: CGRect(
                x: topLeft.x, y: minY,
                width: topRight.x - topLeft.x, height: maxY - minY,
            ),
            lineWidth: abs(topLeft.y - botLeft.y),
            pageIndex: pageIndex,
            quad: quad,
        )
    }

    /// The slab's x-span, walked outward at both ends across columns
    /// whose ink still fills the fitted band.
    ///
    /// A slab CANNOT include the columns where its own outermost stems
    /// stand: there the ink run is beam + stem merged, lands on no ladder
    /// rung, and contributes no column. But a beam ends flush with the
    /// OUTER edge of those stems, so the fitted range stops about half a
    /// stem width inside the beam at each end — measured over 299 pages
    /// as an x-coverage of p50 0.90, p01 0.85 against the labels.
    ///
    /// That shortfall is not cosmetic. `PDFImporter.beamWindow` takes the
    /// narrowest beam whose x-range contains a tuplet digit and uses that
    /// range as the member-run window, so a range that stops inside its
    /// own outer stems loses the run's end notes: with the raster's beams
    /// the corpus recovers 27 of 660 triplet notes, with the ORACLE's
    /// beams 579, and duration p50 goes 74 -> 78 against a ceiling of 82.
    /// `beamEndpointPad` downstream is 1.5pt precisely because a vector
    /// beam's endpoints DO coincide with its outermost stems; restoring
    /// that property makes the raster meet the contract the back-end was
    /// fitted to rather than exceed it.
    ///
    /// The walk is post-fit and feeds nothing back into the fit: the
    /// added columns are never fit points, so neither `leastSquares` nor
    /// the `maxResidual` gate can be moved by them. It is symmetric —
    /// both ends use the already-fitted band, so there is no end that
    /// lacks one. And it is bounded, because the stopping rule alone is
    /// not enough: a notehead abutting a beam end also fills the band,
    /// and unbounded walking would swallow it. A stem is ~0.15 sp wide
    /// and a notehead ~1.3 sp, so the bound sits between them.
    static func extendedSpan(
        firstX: Int, lastX: Int, mask: InkMask, spacingPx: Double,
        topFit: EdgeFit, botFit: EdgeFit,
    ) -> (left: Double, right: Double) {
        let limit = max(1, Int((beamEndExtendInSpaces * spacingPx).rounded()))
        var left = firstX
        while left > 0, firstX - (left - 1) <= limit,
              bandIsInked(mask, x: left - 1, topFit: topFit, botFit: botFit)
        {
            left -= 1
        }
        var right = lastX
        while right < mask.width - 1, (right + 1) - lastX <= limit,
              bandIsInked(mask, x: right + 1, topFit: topFit, botFit: botFit)
        {
            right += 1
        }
        return (Double(left), Double(right + 1))
    }

    /// Whether column `x` is inked across the whole fitted band.
    ///
    /// Every row of the band must be ink. A partial overlap is what a
    /// neighbouring glyph or the page's next beam looks like; only the
    /// beam's own continuation fills it.
    private static func bandIsInked(
        _ mask: InkMask, x: Int, topFit: EdgeFit, botFit: EdgeFit,
    ) -> Bool {
        guard x >= 0, x < mask.width else { return false }
        let top = Int(topFit.y(at: Double(x)).rounded())
        let bottom = Int(botFit.y(at: Double(x)).rounded())
        guard top <= bottom, top >= 0, bottom < mask.height else { return false }
        for y in top ... bottom where !mask[x, y] {
            return false
        }
        return true
    }

    static func leastSquares(_ points: [(Double, Double)]) -> EdgeFit? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }
        var sumX = 0.0
        var sumY = 0.0
        var sumXX = 0.0
        var sumXY = 0.0
        for (x, y) in points {
            sumX += x
            sumY += y
            sumXX += x * x
            sumXY += x * y
        }
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > 1e-9 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denominator
        return EdgeFit(slope: slope, intercept: (sumY - slope * sumX) / n)
    }

    static func maxResidual(_ points: [(Double, Double)], _ fit: EdgeFit) -> Double {
        var worst = 0.0
        for (x, y) in points {
            worst = max(worst, abs(y - fit.y(at: x)))
        }
        return worst
    }
}
