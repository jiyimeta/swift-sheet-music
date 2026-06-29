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
        let length = GlissandoGeometry.length(from: from, to: to)
        guard length > 0.01 else { return }
        let angle = GlissandoGeometry.angle(from: from, to: to)

        if wavy {
            // Repeat wiggleGlissando (U+EAAF) along the line, centred.
            // Each glyph is placed at its world position and rotated to
            // match the glissando slope. Mirrors MuseScore tdraw.cpp:1585-1596.
            // swiftlint:disable:next force_unwrapping
            let ch = Character(UnicodeScalar(SMuFLCodepoint.wiggleGlissando)!)
            let glyphFont = LayoutFont(
                face: SMuFLFamily.bravura, pointSize: metrics.glyphFontSize,
            )
            let advance = FontMetrics.provider.typographicWidth(
                text: String(ch), font: glyphFont,
            )
            let run = GlissandoGeometry.wavyGlyphRun(
                length: length, advance: advance,
            )
            for i in 0 ..< run.count {
                let localX = run.startX + CGFloat(i) * advance
                let worldPt = GlissandoGeometry.toWorld(
                    local: CGPoint(x: localX, y: 0),
                    from: from, angle: angle,
                )
                if let layer = glyphLayer(
                    ch, at: worldPt,
                    size: metrics.glyphFontSize,
                    anchor: CGPoint(x: 0.5, y: 0.5),
                    rotation: angle,
                    height: height,
                ) {
                    parent.addSublayer(layer)
                }
            }
        } else {
            // Straight line: build in local frame, then transform to world.
            // Want: P → rotate(P) → + from.
            // Matrix: T_from · R.  In CGAffineTransform chained API, each
            // method post-multiplies its operation onto the receiver, so
            // the chain must be translate-then-rotate:
            //   I.translatedBy(from) · R = T_from · R
            let linePath = CGMutablePath()
            linePath.move(to: .zero)
            linePath.addLine(to: CGPoint(x: length, y: 0))
            var transform = CGAffineTransform(
                translationX: from.x, y: from.y,
            )
            transform = transform.rotated(by: angle)
            if let transformed = linePath.copy(using: &transform) {
                parent.addSublayer(strokeLayer(
                    path: transformed, height: height,
                    lineWidth: metrics.sp
                        * GlissandoGeometry.lineThicknessSp,
                ))
            }
        }

        if let text, !text.isEmpty {
            drawGlissandoText(
                text, from: from, length: length, angle: angle,
                wavy: wavy, metrics: metrics, height: height,
                into: parent,
            )
        }
    }

    /// Centered label above the glissando line. Font defaults from
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
        let anchorLocal = GlissandoGeometry.textAnchorLocal(
            length: length, wavy: wavy, sp: metrics.sp,
        )
        let world = GlissandoGeometry.toWorld(
            local: anchorLocal, from: from, angle: angle,
        )
        if let layer = textLayer(
            text: text,
            at: world,
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
