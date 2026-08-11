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

    /// One constant-level interval of a slab → its `k` beam segments, or
    /// none when it fails the straightness or slope gates.
    static func quads(
        for interval: [BeamColumn], spacingPx: Double,
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

        let xLeft = Double(firstX)
        let xRight = Double(lastX + 1)
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
