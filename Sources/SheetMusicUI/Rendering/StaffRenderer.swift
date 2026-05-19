import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
import SwiftUI

@available(macOS 15.0, *)
enum StaffRenderer {
    /// Right edge (in system-local coords) for the five staff lines
    /// in `system`. Anchored to the rightmost stroke of the last
    /// measure's terminal barline so the staff passes through every
    /// component of a double / end / end-repeat pair, instead of
    /// running 0.5 sp past a plain barline through the trailing
    /// gutter baked into each measure's width.
    static func endX(for system: LayoutSystem) -> CGFloat {
        guard let bar = system.trailingBarLine else {
            return system.size.width
        }
        return bar.x + BarLineRenderer.rightExtent(
            subtype: bar.subtype, sp: system.sp,
        )
    }

    /// Draw five horizontal staff lines. `origin` is the top-left of the
    /// top line; `width` is how far they run. The fifth (bottom) line lies
    /// at `origin.y + 4 * sp`.
    static func draw(
        context: inout GraphicsContext,
        origin: CGPoint,
        width: CGFloat,
        metrics: StaffMetrics,
    ) {
        for i in 0 ..< 5 {
            let y = origin.y + CGFloat(i) * metrics.sp
            var path = Path()
            path.move(to: CGPoint(x: origin.x, y: y))
            path.addLine(to: CGPoint(x: origin.x + width, y: y))
            context.stroke(
                path,
                with: .color(.primary),
                lineWidth: metrics.staffLineThickness,
            )
        }
    }

    /// Draw all brackets/braces at the left edge of `system`, dispatching
    /// on each `LayoutBracket.type`. Geometry mirrors
    /// `engraving/rendering/score/tdraw.cpp:1059-1122` so each type
    /// matches MuseScore's engraving exactly.
    static func drawBrackets(
        context: inout GraphicsContext,
        system: LayoutSystem,
        metrics: StaffMetrics,
    ) {
        guard !system.brackets.isEmpty,
              let firstStaffOrigin = system.staffOrigins.first
        else { return }
        let staffOriginX = system.origin.x + firstStaffOrigin.x
        for b in system.brackets {
            let topY = system.origin.y + b.topY
            let bottomY = system.origin.y + b.bottomY
            switch b.type {
            case .noBracket:
                continue
            case .brace:
                drawBrace(
                    context: &context,
                    staffOriginX: staffOriginX,
                    topY: topY, bottomY: bottomY,
                    staffCount: b.staffCount,
                    metrics: metrics,
                )
            case .normal:
                drawNormalBracket(
                    context: &context,
                    column: b.column,
                    staffOriginX: staffOriginX,
                    topY: topY, bottomY: bottomY,
                    metrics: metrics,
                )
            case .square:
                drawSquareBracket(
                    context: &context,
                    column: b.column,
                    staffOriginX: staffOriginX,
                    topY: topY, bottomY: bottomY,
                    metrics: metrics,
                )
            case .line:
                drawLineBracket(
                    context: &context,
                    column: b.column,
                    staffOriginX: staffOriginX,
                    topY: topY, bottomY: bottomY,
                    metrics: metrics,
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
    /// `bracketBottom` cap glyphs at each end. Mirrors `tdraw.cpp:1085`.
    private static func drawNormalBracket(
        context: inout GraphicsContext,
        column: Int,
        staffOriginX: CGFloat,
        topY: CGFloat, bottomY: CGFloat,
        metrics: StaffMetrics,
    ) {
        let sp = metrics.sp
        let x = bracketSpineX(
            column: column, staffOriginX: staffOriginX, sp: sp,
        )
        let w = sp * 0.45
        let bd = sp * 0.25
        var spine = Path()
        spine.move(to: CGPoint(x: x, y: topY - bd - w * 0.5))
        spine.addLine(to: CGPoint(x: x, y: bottomY + bd + w * 0.5))
        context.stroke(spine, with: .color(.primary), lineWidth: w)
        let glyphLeftX = x - w * 0.5
        let fontSize = sp * 4
        if let topPath = smuflGlyphPath(
            codepoint: 0xE003,
            fontSize: fontSize,
            originX: glyphLeftX,
            originY: topY - bd,
        ) {
            context.fill(Path(topPath), with: .color(.primary))
        }
        if let bottomPath = smuflGlyphPath(
            codepoint: 0xE004,
            fontSize: fontSize,
            originX: glyphLeftX,
            originY: bottomY + bd,
        ) {
            context.fill(Path(bottomPath), with: .color(.primary))
        }
    }

    /// Thin square bracket: spine plus two horizontal serifs of equal
    /// `staffLineThickness`. Mirrors `tdraw.cpp:1100`.
    private static func drawSquareBracket(
        context: inout GraphicsContext,
        column: Int,
        staffOriginX: CGFloat,
        topY: CGFloat, bottomY: CGFloat,
        metrics: StaffMetrics,
    ) {
        let sp = metrics.sp
        let x = bracketSpineX(
            column: column, staffOriginX: staffOriginX, sp: sp,
        )
        let lineW = metrics.staffLineThickness
        let serifLength = sp * 0.45
        var spine = Path()
        spine.move(to: CGPoint(x: x, y: topY))
        spine.addLine(to: CGPoint(x: x, y: bottomY))
        context.stroke(spine, with: .color(.primary), lineWidth: lineW)
        for y in [topY, bottomY] {
            var serif = Path()
            serif.move(to: CGPoint(x: x - lineW * 0.5, y: y))
            serif.addLine(to: CGPoint(x: x + serifLength, y: y))
            context.stroke(
                serif, with: .color(.primary), lineWidth: lineW,
            )
        }
    }

    /// Plain vertical line bracket. Width 0.67 × bracketWidth; ends
    /// extend `staffLineThickness/2` past the spanned staff edges.
    /// Mirrors `tdraw.cpp:1111`.
    private static func drawLineBracket(
        context: inout GraphicsContext,
        column: Int,
        staffOriginX: CGFloat,
        topY: CGFloat, bottomY: CGFloat,
        metrics: StaffMetrics,
    ) {
        let sp = metrics.sp
        let x = bracketSpineX(
            column: column, staffOriginX: staffOriginX, sp: sp,
        )
        let w = 0.67 * sp * 0.45
        let bd = metrics.staffLineThickness * 0.5
        var spine = Path()
        spine.move(to: CGPoint(x: x, y: topY - bd))
        spine.addLine(to: CGPoint(x: x, y: bottomY + bd))
        context.stroke(spine, with: .color(.primary), lineWidth: w)
    }

    /// Brace via the appropriate Bravura brace variant
    /// (`braceSmall`/`brace`/`braceLarge`/`braceLarger`), stretched in
    /// Y to fit the span and in X by the empirical `magx` formula
    /// from `Bracket::computeMagx`. Mirrors `tdraw.cpp:1068-1083`
    /// plus `bracket.cpp:84-94`.
    private static func drawBrace(
        context: inout GraphicsContext,
        staffOriginX: CGFloat,
        topY: CGFloat, bottomY: CGFloat,
        staffCount: Int,
        metrics: StaffMetrics,
    ) {
        let rightEdge = staffOriginX - metrics.sp * 0.3
        let (codepoint, magx) = SMuFLGlyph.braceVariant(
            staffCount: staffCount,
        )
        guard let path = smuflGlyphPathStretched(
            codepoint: codepoint,
            fontSize: metrics.sp * 4,
            rightEdgeX: rightEdge,
            topY: topY,
            bottomY: bottomY,
            xScale: magx,
        ) else { return }
        context.fill(Path(path), with: .color(.primary))
    }

    /// SMuFL glyph as a CGPath in screen coords, anchored by font
    /// origin (baseline-left) at `(originX, originY)`. Natural metrics.
    private static func smuflGlyphPath(
        codepoint: UInt16,
        fontSize: CGFloat,
        originX: CGFloat,
        originY: CGFloat,
    ) -> CGPath? {
        _ = SheetMusicLayoutApple.install
        let font = CTFontCreateWithName(
            BravuraFont.familyName as CFString, fontSize, nil,
        )
        var unichars: [UniChar] = [codepoint]
        var glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(
            font, &unichars, &glyphs, 1,
        ), let path = CTFontCreatePathForGlyph(font, glyphs[0], nil)
        else { return nil }
        var t = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1,
            tx: originX, ty: originY,
        )
        return path.copy(using: &t) ?? path
    }

    /// SMuFL glyph stretched so its bbox spans `[topY, bottomY]`
    /// vertically, with bbox right edge at `rightEdgeX`. `xScale`
    /// applies the brace magx multiplier; defaults to 1.
    private static func smuflGlyphPathStretched(
        codepoint: UInt16,
        fontSize: CGFloat,
        rightEdgeX: CGFloat,
        topY: CGFloat,
        bottomY: CGFloat,
        xScale: CGFloat = 1,
    ) -> CGPath? {
        _ = SheetMusicLayoutApple.install
        let font = CTFontCreateWithName(
            BravuraFont.familyName as CFString, fontSize, nil,
        )
        var unichars: [UniChar] = [codepoint]
        var glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(
            font, &unichars, &glyphs, 1,
        ), let path = CTFontCreatePathForGlyph(font, glyphs[0], nil)
        else { return nil }
        let bbox = path.boundingBox
        guard bbox.width > 0, bbox.height > 0 else { return nil }
        let scaleY = (bottomY - topY) / bbox.height
        var t = CGAffineTransform(
            a: xScale, b: 0, c: 0, d: -scaleY,
            tx: rightEdgeX - bbox.maxX * xScale,
            ty: topY + bbox.maxY * scaleY,
        )
        return path.copy(using: &t) ?? path
    }
}
