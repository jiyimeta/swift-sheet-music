import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

extension LayoutBridge {
    /// The circle constant: a quarter ellipse is one cubic with control points this fraction of each radius out.
    private static let ellipseKappa = 0.5522847498

    /// A `LayoutFigure`, already translated to page points, as the opcodes the draw program has: lines and outlines
    /// stroked, a round cap as a filled disc at each end, ellipses as four cubics filled or stroked, runs through
    /// `emitRichRuns` inside a `setRotation` pair when turned. The color is set first and reset to black last.
    static func encodeFigure(_ figure: LayoutFigure, color: ScoreColor?, into out: inout [DrawCommand]) {
        let argb = color.flatMap(argb(from:))
        if let argb { out.append(.setColor(argb: argb)) }
        for primitive in figure.primitives {
            switch primitive {
            case let .line(from, to, width, cap):
                out.append(.moveTo(x: Double(from.x) * ptToMMScale, y: Double(from.y) * ptToMMScale))
                out.append(.lineTo(x: Double(to.x) * ptToMMScale, y: Double(to.y) * ptToMMScale))
                out.append(.stroke(width: Double(width) * ptToMMScale))
                if cap == .round {
                    let radius = Double(width) / 2
                    for end in [(Double(from.x), Double(from.y)), (Double(to.x), Double(to.y))] {
                        appendEllipse(centerX: end.0, centerY: end.1, rx: radius, ry: radius, into: &out)
                        out.append(.fillPath)
                    }
                }
            case let .polyline(points, width):
                guard let first = points.first else { continue }
                out.append(.moveTo(x: Double(first.x) * ptToMMScale, y: Double(first.y) * ptToMMScale))
                for point in points.dropFirst() {
                    out.append(.lineTo(x: Double(point.x) * ptToMMScale, y: Double(point.y) * ptToMMScale))
                }
                out.append(.stroke(width: Double(width) * ptToMMScale))
            case let .ellipse(rect, isFilled, width):
                appendEllipse(
                    centerX: Double(rect.midX), centerY: Double(rect.midY),
                    rx: Double(rect.width) / 2, ry: Double(rect.height) / 2, into: &out,
                )
                out.append(isFilled ? .fillPath : .stroke(width: Double(width) * ptToMMScale))
            case let .rectOutline(rect, width):
                let corners = [
                    (rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.maxX, rect.maxY), (rect.minX, rect.maxY),
                    (rect.minX, rect.minY),
                ].map { (Double($0.0) * ptToMMScale, Double($0.1) * ptToMMScale) }
                out.append(.moveTo(x: corners[0].0, y: corners[0].1))
                for corner in corners.dropFirst() {
                    out.append(.lineTo(x: corner.0, y: corner.1))
                }
                out.append(.stroke(width: Double(width) * ptToMMScale))
            case let .run(run, rotation, pivot):
                let turned = rotation != 0
                if turned {
                    out.append(.setRotation(
                        radians: Double(rotation),
                        pivotX: Double(pivot.x) * ptToMMScale, pivotY: Double(pivot.y) * ptToMMScale,
                    ))
                }
                emitRichRuns([run], decorations: [], into: &out)
                if turned { out.append(.setRotation(radians: 0, pivotX: 0, pivotY: 0)) }
            }
        }
        if argb != nil { out.append(.setColor(argb: blackARGB)) }
    }

    /// An ellipse in page points as a closed path of four cubics, starting at its rightmost point.
    private static func appendEllipse(
        centerX: Double, centerY: Double, rx: Double, ry: Double, into out: inout [DrawCommand],
    ) {
        let cx = centerX * ptToMMScale, cy = centerY * ptToMMScale
        let rx = rx * ptToMMScale, ry = ry * ptToMMScale
        let kx = rx * ellipseKappa, ky = ry * ellipseKappa
        out.append(.moveTo(x: cx + rx, y: cy))
        out.append(.cubicTo(cx1: cx + rx, cy1: cy + ky, cx2: cx + kx, cy2: cy + ry, x: cx, y: cy + ry))
        out.append(.cubicTo(cx1: cx - kx, cy1: cy + ry, cx2: cx - rx, cy2: cy + ky, x: cx - rx, y: cy))
        out.append(.cubicTo(cx1: cx - rx, cy1: cy - ky, cx2: cx - kx, cy2: cy - ry, x: cx, y: cy - ry))
        out.append(.cubicTo(cx1: cx + kx, cy1: cy - ry, cx2: cx + rx, cy2: cy - ky, x: cx + rx, y: cy))
    }
}
