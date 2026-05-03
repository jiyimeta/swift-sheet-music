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
    // MARK: - Staves, brackets, part labels

    static func drawStaves(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        for origin in system.staffOrigins {
            let path = CGMutablePath()
            let width = system.size.width - origin.x
            for i in 0 ..< 5 {
                let y = origin.y + CGFloat(i) * metrics.sp
                path.move(to: CGPoint(x: origin.x, y: y))
                path.addLine(
                    to: CGPoint(x: origin.x + width, y: y))
            }
            parent.addSublayer(strokeLayer(
                path: path,
                height: height,
                lineWidth: metrics.staffLineThickness
            ))
        }
    }

    static func drawBrackets(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        guard !system.brackets.isEmpty else { return }
        let staffOriginX = system.staffOrigins.first?.x ?? 0
        for b in system.brackets {
            switch b.type {
            case .noBracket:
                continue
            case .brace:
                drawBrace(
                    bracket: b, staffOriginX: staffOriginX,
                    metrics: metrics, height: height, into: parent
                )
            case .normal:
                drawAngleBracket(
                    bracket: b, staffOriginX: staffOriginX,
                    spineWidth: metrics.sp * 0.3,
                    serifWidth: metrics.sp * 0.25,
                    serifLength: metrics.sp * 0.8,
                    metrics: metrics, height: height, into: parent
                )
            case .square:
                drawAngleBracket(
                    bracket: b, staffOriginX: staffOriginX,
                    spineWidth: metrics.sp * 0.15,
                    serifWidth: metrics.sp * 0.15,
                    serifLength: metrics.sp * 0.5,
                    metrics: metrics, height: height, into: parent
                )
            case .line:
                drawLineBracket(
                    bracket: b, staffOriginX: staffOriginX,
                    metrics: metrics, height: height, into: parent
                )
            }
        }
    }

    private static func bracketSpineX(
        column: Int, staffOriginX: CGFloat, sp: CGFloat
    ) -> CGFloat {
        staffOriginX - sp * 0.5 - CGFloat(column) * sp
    }

    private static func drawAngleBracket(
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        spineWidth: CGFloat,
        serifWidth: CGFloat,
        serifLength: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: metrics.sp
        )
        let topPt = CGPoint(x: x, y: b.topY)
        let botPt = CGPoint(x: x, y: b.bottomY)
        let spine = CGMutablePath()
        spine.move(to: topPt)
        spine.addLine(to: botPt)
        parent.addSublayer(strokeLayer(
            path: spine, height: height, lineWidth: spineWidth
        ))
        for point in [topPt, botPt] {
            let serif = CGMutablePath()
            serif.move(to: point)
            serif.addLine(to: CGPoint(
                x: point.x + serifLength, y: point.y
            ))
            parent.addSublayer(strokeLayer(
                path: serif, height: height, lineWidth: serifWidth
            ))
        }
    }

    private static func drawLineBracket(
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: metrics.sp
        )
        let spine = CGMutablePath()
        spine.move(to: CGPoint(x: x, y: b.topY))
        spine.addLine(to: CGPoint(x: x, y: b.bottomY))
        parent.addSublayer(strokeLayer(
            path: spine, height: height, lineWidth: metrics.sp * 0.15
        ))
    }

    /// SMuFL brace glyph (Bravura Private Use Area codepoint).
    /// `UnicodeScalar(0xE000)` is always valid (PUA block), so the
    /// literal character avoids a force-unwrap at each call site.
    private static let braceCharacter: Character = "\u{E000}"

    /// Brace via Bravura `U+E000`. Y-scaled to fit the requested span.
    /// Glyph's right edge sits sp*0.3 to the left of the staff origin
    /// (braces sit closest to the staff; nested columns don't apply).
    private static func drawBrace(
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        _ = BravuraFont.register
        let fontSize = metrics.sp * 4
        let font = CTFontCreateWithName(
            BravuraFont.familyName as CFString,
            fontSize, nil
        )
        var unichars: [UniChar] = [0xE000]
        var glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(
            font, &unichars, &glyphs, 1
        ) else { return }
        var bbox = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(
            font, .horizontal, &glyphs, &bbox, 1
        )
        let nativeHeight = bbox.height
        guard nativeHeight > 0 else { return }
        let target = b.bottomY - b.topY
        let yScale = target / nativeHeight
        let layer = CATextLayer()
        layer.string = String(braceCharacter)
        layer.font = font
        layer.fontSize = fontSize
        layer.alignmentMode = .left
        layer.foregroundColor = CGColor(gray: 0, alpha: 1)
        let glyphWidth = bbox.width
        let x = staffOriginX - metrics.sp * 0.3 - glyphWidth
        let frame = CGRect(
            x: x, y: height - b.bottomY,
            width: glyphWidth,
            height: nativeHeight
        )
        layer.frame = frame
        layer.contentsScale = 2
        layer.transform = CATransform3DMakeScale(1, yScale, 1)
        parent.addSublayer(layer)
    }

    static func drawPartLabels(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        for label in system.partLabels {
            guard !label.text.isEmpty else { continue }
            if let layer = textLayer(
                text: label.text,
                at: label.origin,
                size: metrics.sp * 2.5,
                italic: false,
                anchor: CGPoint(x: 1, y: 0.5),
                height: height
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    /// Vertical line at the left edge of every system, joining the top
    /// of the topmost staff to the bottom of the bottommost staff. This
    /// is the "system barline" — MuseScore's
    /// `engraving/dom/measure.cpp` always emits one at the system head.
    static func drawSystemBar(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        guard let first = system.staffOrigins.first,
              let last = system.staffOrigins.last
        else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: first.x, y: first.y))
        path.addLine(to: CGPoint(
            x: first.x, y: last.y + metrics.staffHeight
        ))
        parent.addSublayer(strokeLayer(
            path: path,
            height: height,
            lineWidth: metrics.staffLineThickness
        ))
    }
}
