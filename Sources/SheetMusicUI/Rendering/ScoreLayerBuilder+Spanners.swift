import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, iOS 16.0, *)
extension ScoreLayerBuilder {
    // MARK: - Spanners

    static func drawSpanner(
        kind: LayoutElement.SpannerKind,
        from: CGPoint, to: CGPoint,
        continuesLeft: Bool, continuesRight: Bool,
        text: String, metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        switch kind {
        case .slur:
            drawSlur(
                from: from, to: to,
                metrics: metrics, height: height, into: parent
            )
        case let .volta(endings):
            drawVolta(
                from: from, to: to, endings: endings,
                continuesLeft: continuesLeft,
                continuesRight: continuesRight,
                metrics: metrics, height: height, into: parent
            )
        case .hairpinOpen, .hairpinClose:
            drawHairpin(
                from: from, to: to,
                open: kind == .hairpinOpen,
                metrics: metrics, height: height, into: parent
            )
        case .pedal:
            drawPedal(
                from: from, to: to,
                metrics: metrics, height: height, into: parent
            )
        case .ottava:
            drawOttava(
                from: from, to: to,
                metrics: metrics, height: height, into: parent
            )
        case .textLine:
            drawTextLine(
                from: from, to: to, text: text,
                metrics: metrics, height: height, into: parent
            )
        }
    }

    private static func drawSlur(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let mid = CGPoint(
            x: (from.x + to.x) / 2,
            y: min(from.y, to.y) - metrics.sp * 2
        )
        let p = CGMutablePath()
        p.move(to: from)
        p.addQuadCurve(to: to, control: mid)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * 0.15
        ))
    }

    private static func drawVolta(
        from: CGPoint, to: CGPoint,
        endings: [Int],
        continuesLeft: Bool, continuesRight: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let top = min(from.y, to.y)
        let p = CGMutablePath()
        if !continuesLeft {
            p.move(to: CGPoint(x: from.x, y: top + metrics.sp))
            p.addLine(to: CGPoint(x: from.x, y: top))
        } else {
            p.move(to: CGPoint(x: from.x, y: top))
        }
        p.addLine(to: CGPoint(x: to.x, y: top))
        if !continuesRight {
            p.addLine(to: CGPoint(x: to.x, y: top + metrics.sp))
        }
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * 0.15
        ))
        if !endings.isEmpty, !continuesLeft {
            let label = endings
                .map(String.init)
                .joined(separator: ", ") + "."
            if let layer = textLayer(
                text: label,
                at: CGPoint(
                    x: from.x + metrics.sp,
                    y: top + metrics.sp / 2
                ),
                size: metrics.sp * 2, italic: false,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    private static func drawHairpin(
        from: CGPoint, to: CGPoint, open: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let p = CGMutablePath()
        let y = max(from.y, to.y)
        if open {
            p.move(to: CGPoint(x: from.x, y: y))
            p.addLine(to: CGPoint(x: to.x, y: y - metrics.sp))
            p.move(to: CGPoint(x: from.x, y: y))
            p.addLine(to: CGPoint(x: to.x, y: y + metrics.sp))
        } else {
            p.move(to: CGPoint(x: from.x, y: y - metrics.sp))
            p.addLine(to: CGPoint(x: to.x, y: y))
            p.move(to: CGPoint(x: from.x, y: y + metrics.sp))
            p.addLine(to: CGPoint(x: to.x, y: y))
        }
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * 0.15
        ))
    }

    private static func drawPedal(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        if let layer = textLayer(
            text: "Ped.", at: from,
            size: metrics.sp * 2.5, italic: true,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height
        ) {
            parent.addSublayer(layer)
        }
        if let layer = textLayer(
            text: "*", at: to,
            size: metrics.sp * 3, italic: false,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height
        ) {
            parent.addSublayer(layer)
        }
    }

    private static func drawOttava(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        if let layer = textLayer(
            text: "8va", at: from,
            size: metrics.sp * 2.5, italic: true,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height
        ) {
            parent.addSublayer(layer)
        }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: from.x + metrics.sp * 3, y: from.y))
        p.addLine(to: to)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * 0.1,
            dashPattern: [3, 3]
        ))
    }

    private static func drawTextLine(
        from: CGPoint, to: CGPoint, text: String,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        if !text.isEmpty,
           let layer = textLayer(
               text: text, at: from,
               size: metrics.sp * 2.2, italic: true,
               anchor: CGPoint(x: 0, y: 0.5),
               height: height
           )
        {
            parent.addSublayer(layer)
        }
        let p = CGMutablePath()
        p.move(to: from)
        p.addLine(to: to)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * 0.1
        ))
    }

    // MARK: - Tie arc

    static func drawTieArc(
        from: CGPoint, to: CGPoint, above: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let headClearance = metrics.sp * 0.6
        let vertSign: CGFloat = above ? -1 : 1
        let startPt = CGPoint(
            x: from.x,
            y: from.y + headClearance * vertSign
        )
        let endPt = CGPoint(
            x: to.x,
            y: to.y + headClearance * vertSign
        )

        let minShoulder = metrics.sp * 0.3
        let maxShoulder = metrics.sp * 2.0
        let tieLen = abs(endPt.x - startPt.x)
        let tieLenSp = max(tieLen / metrics.sp, 1.0)
        let shoulderH: CGFloat = {
            let raw = minShoulder
                + metrics.sp * 0.3 * sqrt(tieLenSp - 1)
            return min(max(raw, minShoulder), maxShoulder)
        }()
        let midThickness = metrics.sp * 0.15

        let dx = endPt.x - startPt.x
        let dy = endPt.y - startPt.y
        let ctrl1 = CGPoint(
            x: startPt.x + dx * 0.2,
            y: startPt.y + dy * 0.2 + shoulderH * vertSign
        )
        let ctrl2 = CGPoint(
            x: startPt.x + dx * 0.8,
            y: startPt.y + dy * 0.8 + shoulderH * vertSign
        )
        let thickDy = midThickness * vertSign * -1

        let path = CGMutablePath()
        path.move(to: startPt)
        path.addCurve(
            to: endPt,
            control1: CGPoint(x: ctrl1.x, y: ctrl1.y - thickDy),
            control2: CGPoint(x: ctrl2.x, y: ctrl2.y - thickDy)
        )
        path.addCurve(
            to: startPt,
            control1: CGPoint(x: ctrl2.x, y: ctrl2.y + thickDy),
            control2: CGPoint(x: ctrl1.x, y: ctrl1.y + thickDy)
        )
        path.closeSubpath()
        parent.addSublayer(fillLayer(
            path: path, height: height
        ))
    }

    // MARK: - Glissando

    static func drawGlissando(
        from: CGPoint, to: CGPoint, wavy: Bool, text: String?,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.01 else { return }
        let angle = atan2(dy, dx)

        let linePath = CGMutablePath()
        if wavy {
            let waveAmp = metrics.sp * 0.3
            let segments = max(3, Int(length / (metrics.sp * 0.8)))
            let segLen = length / CGFloat(segments)
            linePath.move(to: .zero)
            for i in 1 ... segments {
                let x = segLen * CGFloat(i)
                let y = i.isMultiple(of: 2) ? waveAmp : -waveAmp
                linePath.addLine(to: CGPoint(x: x, y: y))
            }
        } else {
            linePath.move(to: .zero)
            linePath.addLine(to: CGPoint(x: length, y: 0))
        }
        // Want: P → rotate(P) → + from.
        // Matrix: T_from · R.  In CGAffineTransform chained API, each
        // method post-multiplies its operation onto the receiver, so
        // the chain must be translate-then-rotate:
        //   I.translatedBy(from) · R = T_from · R
        var transform = CGAffineTransform(
            translationX: from.x, y: from.y
        )
        transform = transform.rotated(by: angle)
        if let transformed = linePath.copy(using: &transform) {
            parent.addSublayer(strokeLayer(
                path: transformed, height: height,
                lineWidth: metrics.sp * 0.15
            ))
        }

        if let text, !text.isEmpty {
            let localX = length / 2
            let localY = -(metrics.sp * 0.5)
            let worldX = cos(angle) * localX
                - sin(angle) * localY + from.x
            let worldY = sin(angle) * localX
                + cos(angle) * localY + from.y
            if let layer = textLayer(
                text: text,
                at: CGPoint(x: worldX, y: worldY),
                size: metrics.sp * 1.8,
                italic: true,
                anchor: CGPoint(x: 0.5, y: 0.5),
                rotation: angle,
                height: height
            ) {
                parent.addSublayer(layer)
            }
        }
    }
}
