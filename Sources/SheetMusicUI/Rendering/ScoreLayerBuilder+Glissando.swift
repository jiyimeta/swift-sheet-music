import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    // MARK: - Glissando

    static func drawGlissando(
        from: CGPoint, to: CGPoint, wavy: Bool, text: String?,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
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
            translationX: from.x, y: from.y,
        )
        transform = transform.rotated(by: angle)
        if let transformed = linePath.copy(using: &transform) {
            parent.addSublayer(strokeLayer(
                path: transformed, height: height,
                lineWidth: metrics.sp * 0.15,
            ))
        }

        if let text, !text.isEmpty {
            drawGlissandoText(
                text, from: from, length: length, angle: angle,
                wavy: wavy, metrics: metrics, height: height,
                into: parent,
            )
        }
    }

    /// Centred label above the glissando line. Font defaults from
    /// `TextStyleType.glissando` (Edwin 8 pt italic, spatium-dependent)
    /// and the width gate mirrors `tdraw.cpp:1580`. Anchored at
    /// bottom-center so the descender clears the line by the spacing
    /// from `tdraw.cpp:1584` (0.1 sp straight, 0.4 sp wavy).
    private static func drawGlissandoText(
        _ text: String,
        from: CGPoint, length: CGFloat, angle: CGFloat,
        wavy: Bool, metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer,
    ) {
        let style = ResolvedTextStyle.resolve(
            .glissando, metrics: metrics,
        )
        let font = style.ctFont
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font],
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let textWidth = CGFloat(
            CTLineGetTypographicBounds(line, nil, nil, nil),
        )
        guard textWidth < length else { return }
        let clearance = metrics.sp * (wavy ? 0.4 : 0.1)
        let localX = length / 2
        let localY = -clearance
        let worldX = cos(angle) * localX
            - sin(angle) * localY + from.x
        let worldY = sin(angle) * localX
            + cos(angle) * localY + from.y
        if let layer = textLayer(
            text: text,
            at: CGPoint(x: worldX, y: worldY),
            size: style.pointSize,
            italic: style.isItalic,
            anchor: CGPoint(x: 0.5, y: 1.0),
            rotation: angle,
            color: inkColor,
            font: font,
            height: height,
        ) {
            parent.addSublayer(layer)
        }
    }
}
