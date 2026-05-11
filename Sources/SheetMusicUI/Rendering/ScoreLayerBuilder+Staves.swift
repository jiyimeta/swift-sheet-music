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
        into parent: CALayer,
    ) {
        let staffEndX = StaffRenderer.endX(for: system)
        for origin in system.staffOrigins {
            let path = CGMutablePath()
            let width = staffEndX - origin.x
            for i in 0 ..< 5 {
                let y = origin.y + CGFloat(i) * metrics.sp
                path.move(to: CGPoint(x: origin.x, y: y))
                path.addLine(
                    to: CGPoint(x: origin.x + width, y: y),
                )
            }
            parent.addSublayer(strokeLayer(
                path: path,
                height: height,
                lineWidth: metrics.staffLineThickness,
            ))
        }
    }

    static func drawBrackets(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
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
                    metrics: metrics, height: height, into: parent,
                )
            case .normal:
                drawNormalBracket(
                    bracket: b, staffOriginX: staffOriginX,
                    metrics: metrics, height: height, into: parent,
                )
            case .square:
                drawSquareBracket(
                    bracket: b, staffOriginX: staffOriginX,
                    metrics: metrics, height: height, into: parent,
                )
            case .line:
                drawLineBracket(
                    bracket: b, staffOriginX: staffOriginX,
                    metrics: metrics, height: height, into: parent,
                )
            }
        }
    }

    private static func bracketSpineX(
        column: Int, staffOriginX: CGFloat, sp: CGFloat,
    ) -> CGFloat {
        staffOriginX - sp * 0.5 - CGFloat(column) * sp
    }

    /// Thick bracket: 0.45 sp spine plus SMuFL `bracketTop` /
    /// `bracketBottom` cap glyphs at each end. Mirrors
    /// `engraving/rendering/score/tdraw.cpp:1085-1098`.
    private static func drawNormalBracket(
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        let sp = metrics.sp
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: sp,
        )
        let w = sp * 0.45 // Sid::bracketWidth
        let bd = sp * 0.25 // bracket-distance offset
        let spine = CGMutablePath()
        spine.move(to: CGPoint(x: x, y: b.topY - bd - w * 0.5))
        spine.addLine(to: CGPoint(x: x, y: b.bottomY + bd + w * 0.5))
        parent.addSublayer(strokeLayer(
            path: spine, height: height, lineWidth: w,
        ))
        let glyphLeftX = x - w * 0.5
        let fontSize = sp * 4 // Bravura: 1 em = 4 sp
        if let topPath = smuflGlyphPath(
            codepoint: 0xE003, // SMuFLGlyph.bracketTop
            fontSize: fontSize,
            originX: glyphLeftX,
            originY: b.topY - bd,
        ) {
            parent.addSublayer(fillLayer(path: topPath, height: height))
        }
        if let bottomPath = smuflGlyphPath(
            codepoint: 0xE004, // SMuFLGlyph.bracketBottom
            fontSize: fontSize,
            originX: glyphLeftX,
            originY: b.bottomY + bd,
        ) {
            parent.addSublayer(fillLayer(path: bottomPath, height: height))
        }
    }

    /// Thin square bracket: spine plus two horizontal serifs of equal
    /// `staffLineThickness`. Mirrors
    /// `engraving/rendering/score/tdraw.cpp:1100-1108`.
    private static func drawSquareBracket(
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        let sp = metrics.sp
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: sp,
        )
        let lineW = metrics.staffLineThickness
        let serifLength = sp * 0.45
        let topPt = CGPoint(x: x, y: b.topY)
        let botPt = CGPoint(x: x, y: b.bottomY)
        let spine = CGMutablePath()
        spine.move(to: topPt)
        spine.addLine(to: botPt)
        parent.addSublayer(strokeLayer(
            path: spine, height: height, lineWidth: lineW,
        ))
        for point in [topPt, botPt] {
            let serif = CGMutablePath()
            serif.move(to: CGPoint(x: point.x - lineW * 0.5, y: point.y))
            serif.addLine(to: CGPoint(
                x: point.x + serifLength, y: point.y,
            ))
            parent.addSublayer(strokeLayer(
                path: serif, height: height, lineWidth: lineW,
            ))
        }
    }

    /// Plain vertical line bracket. Width is 0.67 × bracketWidth; ends
    /// extend `staffLineThickness/2` past the spanned staff edges.
    /// Mirrors `engraving/rendering/score/tdraw.cpp:1111-1118`.
    private static func drawLineBracket(
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        let sp = metrics.sp
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: sp,
        )
        let w = 0.67 * sp * 0.45
        let bd = metrics.staffLineThickness * 0.5
        let spine = CGMutablePath()
        spine.move(to: CGPoint(x: x, y: b.topY - bd))
        spine.addLine(to: CGPoint(x: x, y: b.bottomY + bd))
        parent.addSublayer(strokeLayer(
            path: spine, height: height, lineWidth: w,
        ))
    }

    /// Brace via the appropriate Bravura brace variant
    /// (`braceSmall`/`brace`/`braceLarge`/`braceLarger`), stretched in
    /// Y to fit the span and in X by the empirical `magx` formula
    /// `v + (v−1) × 1.625` from MuseScore's
    /// `Bracket::computeMagx`. Glyph's right edge sits `sp * 0.3` left
    /// of the staff. Mirrors `tdraw.cpp:1068-1083` plus
    /// `bracket.cpp:84-94`.
    private static func drawBrace(
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        let rightEdge = staffOriginX - metrics.sp * 0.3
        let (codepoint, magx) = SMuFLGlyph.braceVariant(
            staffCount: b.staffCount,
        )
        guard let path = smuflGlyphPathStretched(
            codepoint: codepoint,
            fontSize: metrics.sp * 4,
            rightEdgeX: rightEdge,
            topY: b.topY,
            bottomY: b.bottomY,
            xScale: magx,
        ) else { return }
        parent.addSublayer(fillLayer(path: path, height: height))
    }

    /// SMuFL glyph as a CGPath in y-down system coords, anchored by
    /// the glyph's font origin (baseline-left) at `(originX, originY)`.
    /// No vertical scaling — uses the glyph's natural metrics for the
    /// given font size.
    private static func smuflGlyphPath(
        codepoint: UInt16,
        fontSize: CGFloat,
        originX: CGFloat,
        originY: CGFloat,
    ) -> CGPath? {
        let font = bravuraFont(size: fontSize)
        var unichars: [UniChar] = [codepoint]
        var glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(
            font, &unichars, &glyphs, 1,
        ), let path = CTFontCreatePathForGlyph(font, glyphs[0], nil)
        else { return nil }
        // Font path is y-up (baseline at y=0). Map: screen.y = originY - font.y.
        var t = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1,
            tx: originX, ty: originY,
        )
        return path.copy(using: &t) ?? path
    }

    /// SMuFL glyph stretched so its bbox spans `[topY, bottomY]`
    /// vertically, with bbox right edge at `rightEdgeX`. `xScale`
    /// applies an additional horizontal magnification (the `magx`
    /// from `Bracket::computeMagx`) — defaults to 1 for non-brace
    /// glyphs that draw at their natural width.
    private static func smuflGlyphPathStretched(
        codepoint: UInt16,
        fontSize: CGFloat,
        rightEdgeX: CGFloat,
        topY: CGFloat,
        bottomY: CGFloat,
        xScale: CGFloat = 1,
    ) -> CGPath? {
        let font = bravuraFont(size: fontSize)
        var unichars: [UniChar] = [codepoint]
        var glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(
            font, &unichars, &glyphs, 1,
        ), let path = CTFontCreatePathForGlyph(font, glyphs[0], nil)
        else { return nil }
        let bbox = path.boundingBox
        guard bbox.width > 0, bbox.height > 0 else { return nil }
        let scaleY = (bottomY - topY) / bbox.height
        // font (y-up) → screen (y-down).
        //   bbox.maxX → rightEdgeX, bbox.minX → rightEdgeX - bbox.width*xScale.
        //   bbox.maxY → topY, bbox.minY → bottomY.
        var t = CGAffineTransform(
            a: xScale, b: 0, c: 0, d: -scaleY,
            tx: rightEdgeX - bbox.maxX * xScale,
            ty: topY + bbox.maxY * scaleY,
        )
        return path.copy(using: &t) ?? path
    }

    static func drawPartLabels(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        for label in system.partLabels {
            guard !label.text.isEmpty else { continue }
            if let layer = textLayer(
                text: label.text,
                at: label.origin,
                size: metrics.sp * 2.5,
                italic: false,
                anchor: CGPoint(x: 1, y: 0.5),
                height: height,
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
        into parent: CALayer,
    ) {
        guard let first = system.staffOrigins.first,
              let last = system.staffOrigins.last
        else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: first.x, y: first.y))
        path.addLine(to: CGPoint(
            x: first.x, y: last.y + metrics.staffHeight,
        ))
        parent.addSublayer(strokeLayer(
            path: path,
            height: height,
            lineWidth: metrics.staffLineThickness,
        ))
    }
}
