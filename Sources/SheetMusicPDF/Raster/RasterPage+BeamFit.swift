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
    /// none when it fails the straightness or slope gates.
    static func quads(
        for interval: [BeamColumn], mask: InkMask, spacingPx: Double,
        transform: PageTransform, pageIndex: Int,
    ) -> [PathSegment] {
        guard let levels = interval.first?.levels,
              let firstX = interval.first?.x, let lastX = interval.last?.x
        else { return [] }
        let tops = interval.map { (Double($0.x), Double($0.y0)) }
        let bottoms = interval.map { (Double($0.x), Double($0.y1 + 1)) }
        guard let topFit = leastSquares(tops), let botFit = leastSquares(bottoms),
              maxResidual(tops, topFit) <= beamStraightnessInSpaces * spacingPx,
              maxResidual(bottoms, botFit) <= beamStraightnessInSpaces * spacingPx
        else { return [] }

        // Pixel space is y-down and page space y-up, so a pixel-space
        // slope becomes its negation in page space; the 72/dpi scale
        // cancels between rise and run.
        guard abs(topFit.slope) <= beamMaxSlope,
              // A wedge — one edge steeper than the other — is not a
              // beam. Thickness constancy backstops the ladder, which
              // only ever saw the band's total.
              abs(topFit.slope - botFit.slope) <= beamMaxSlope / 2
        else { return [] }

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
