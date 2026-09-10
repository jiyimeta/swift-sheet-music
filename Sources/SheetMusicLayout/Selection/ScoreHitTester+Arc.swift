#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

@available(macOS 15.0, *)
extension ScoreHitTester {
    /// Returns nil only for non-arcs. A rejected arc never falls through to rectangle acceptance.
    func arcContains(_ element: LayoutElement, point: CGPoint) -> Bool? {
        guard let curve = arcCenterline(element) else { return nil }
        let sp = document.metrics.sp
        return curve.distance(to: point, accuracy: sp * 0.001).value <= sp * Self.curveHitToleranceSp
    }

    /// Actual curve extrema plus the renderer's lens/stroke thickness, without hit tolerance.
    func arcInkRects(_ element: LayoutElement) -> [CGRect]? {
        guard let curve = arcCenterline(element) else { return nil }
        let sp = document.metrics.sp
        if case .tieArc = element {
            // The filled lens shares its tips; only the two interior controls move vertically.
            let thickness = sp * 0.15
            let outer = ArcBezier(points: curve.points.enumerated().map { index, point in
                CGPoint(x: point.x, y: point.y - (index == 1 || index == 2 ? thickness : 0))
            })
            let inner = ArcBezier(points: curve.points.enumerated().map { index, point in
                CGPoint(x: point.x, y: point.y + (index == 1 || index == 2 ? thickness : 0))
            })
            return [outer.bounds.union(inner.bounds)]
        }
        let radius = sp * SpannerGeometry.strokeThicknessSp / 2
        return [curve.bounds.insetBy(dx: -radius, dy: -radius)]
    }

    private func arcCenterline(_ element: LayoutElement) -> ArcBezier? {
        let sp = document.metrics.sp
        switch element {
        case let .tieArc(from, to, above, _):
            let controls = TieArcGeometry.controlPoints(
                from: from, to: to, above: above,
                heightSp: TieArcGeometry.shoulderHeightSp(tieLengthSp: abs(to.x - from.x) / sp),
                sp: sp,
            )
            return ArcBezier(points: [controls.p0, controls.p1, controls.p2, controls.p3])
        case let .spannerSegment(.slur, from, to, _, _, _, _):
            return ArcBezier(points: [from, SpannerGeometry.slurControlPoint(from: from, to: to, sp: sp), to])
        default:
            return nil
        }
    }
}

/// A quadratic or cubic, independent of renderer path APIs.
struct ArcBezier {
    let points: [CGPoint]

    struct Distance {
        let value: CGFloat
        /// Geometric error bound, excluding floating-point roundoff, even if the depth cap is reached.
        let errorBound: CGFloat
        let segmentCount: Int
    }

    /// Adaptive de Casteljau subdivision, at most 20 levels. No fixed-rate sampling.
    ///
    /// A chord's degree-elevated controls are L_i = P_0 + i/n (P_n - P_0). The curve/chord
    /// difference is a Bernstein combination of P_i - L_i, so its norm is bounded by their
    /// maximum norm. This bounds Hausdorff distance in both directions and hence point-distance
    /// error, including loops, steep curves and coincident endpoints. The returned maximum leaf
    /// bound remains honest at the depth cap; ordinary score-sized curves reach the requested
    /// 0.001 sp accuracy before that cap. Arithmetic uses CGFloat with its normal rounding.
    func distance(to point: CGPoint, accuracy: CGFloat, depth: Int = 20) -> Distance {
        let first = points[0]
        let last = points[points.count - 1]
        let degree = CGFloat(points.count - 1)
        let error = points.enumerated().map { index, control in
            let fraction = CGFloat(index) / degree
            return Self.length(
                control.x - (first.x + fraction * (last.x - first.x)),
                control.y - (first.y + fraction * (last.y - first.y)),
            )
        }.max() ?? 0
        if error <= accuracy || depth == 0 {
            return Distance(value: Self.segmentDistance(point, first, last), errorBound: error, segmentCount: 1)
        }
        var row = points
        var left = [first]
        var right = [last]
        while row.count > 1 {
            row = zip(row, row.dropFirst()).map { a, b in
                CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
            left.append(row[0])
            right.append(row[row.count - 1])
        }
        let lhs = ArcBezier(points: left).distance(to: point, accuracy: accuracy, depth: depth - 1)
        let rhs = ArcBezier(points: Array(right.reversed())).distance(to: point, accuracy: accuracy, depth: depth - 1)
        return Distance(
            value: min(lhs.value, rhs.value), errorBound: max(lhs.errorBound, rhs.errorBound),
            segmentCount: lhs.segmentCount + rhs.segmentCount,
        )
    }

    private static func length(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        (x * x + y * y).squareRoot()
    }

    private static func segmentDistance(_ point: CGPoint, _ from: CGPoint, _ to: CGPoint) -> CGFloat {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let squared = dx * dx + dy * dy
        guard squared > 0 else { return length(point.x - from.x, point.y - from.y) }
        let t = min(max(((point.x - from.x) * dx + (point.y - from.y) * dy) / squared, 0), 1)
        return length(point.x - (from.x + t * dx), point.y - (from.y + t * dy))
    }

    var bounds: CGRect {
        let times = [CGFloat(0), 1] + extrema(points.map(\.x)) + extrema(points.map(\.y))
        let values = times.map(evaluate)
        let minX = values.map(\.x).min() ?? 0
        let maxX = values.map(\.x).max() ?? 0
        let minY = values.map(\.y).min() ?? 0
        let maxY = values.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func evaluate(_ t: CGFloat) -> CGPoint {
        var row = points
        while row.count > 1 {
            row = zip(row, row.dropFirst()).map { a, b in
                CGPoint(x: (1 - t) * a.x + t * b.x, y: (1 - t) * a.y + t * b.y)
            }
        }
        return row[0]
    }

    private func extrema(_ coordinates: [CGFloat]) -> [CGFloat] {
        let p0 = coordinates[0]
        let p1 = coordinates[1]
        let p2 = coordinates[2]
        if coordinates.count == 3 {
            let denominator = p0 - 2 * p1 + p2
            guard denominator != 0 else { return [] }
            return [(p0 - p1) / denominator].filter { $0 > 0 && $0 < 1 }
        }
        let p3 = coordinates[3]
        let a = -p0 + 3 * p1 - 3 * p2 + p3
        let b = 2 * (p0 - 2 * p1 + p2)
        let c = p1 - p0
        if a == 0 {
            return b == 0 ? [] : [-c / b].filter { $0 > 0 && $0 < 1 }
        }
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return [] }
        let root = discriminant.squareRoot()
        let q = -0.5 * (b + (b < 0 ? -root : root))
        let roots: [CGFloat] = q == 0 ? [-b / (2 * a)] : [q / a, c / q]
        return roots.filter { $0 > 0 && $0 < 1 }
    }
}
