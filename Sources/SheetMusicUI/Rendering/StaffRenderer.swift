import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum StaffRenderer {
    /// Draw five horizontal staff lines. `origin` is the top-left of the
    /// top line; `width` is how far they run. The fifth (bottom) line lies
    /// at `origin.y + 4 * sp`.
    static func draw(
        context: inout GraphicsContext,
        origin: CGPoint,
        width: CGFloat,
        metrics: StaffMetrics
    ) {
        for i in 0 ..< 5 {
            let y = origin.y + CGFloat(i) * metrics.sp
            var path = Path()
            path.move(to: CGPoint(x: origin.x, y: y))
            path.addLine(to: CGPoint(x: origin.x + width, y: y))
            context.stroke(
                path,
                with: .color(.primary),
                lineWidth: metrics.staffLineThickness
            )
        }
    }

    /// Draw all brackets/braces at the left edge of `system`, dispatching
    /// on each `LayoutBracket.type`.
    static func drawBrackets(
        context: inout GraphicsContext,
        system: LayoutSystem,
        metrics: StaffMetrics
    ) {
        guard !system.brackets.isEmpty,
              let firstStaffOrigin = system.staffOrigins.first
        else { return }
        let staffOriginX = system.origin.x + firstStaffOrigin.x
        for b in system.brackets {
            switch b.type {
            case .noBracket:
                continue
            case .brace:
                drawBrace(
                    context: &context,
                    bracket: b,
                    staffOriginX: staffOriginX,
                    systemOriginY: system.origin.y,
                    metrics: metrics
                )
            case .normal:
                drawAngleBracket(
                    context: &context,
                    bracket: b,
                    staffOriginX: staffOriginX,
                    systemOriginY: system.origin.y,
                    spineWidth: metrics.sp * 0.3,
                    serifWidth: metrics.sp * 0.25,
                    serifLength: metrics.sp * 0.8,
                    metrics: metrics
                )
            case .square:
                drawAngleBracket(
                    context: &context,
                    bracket: b,
                    staffOriginX: staffOriginX,
                    systemOriginY: system.origin.y,
                    spineWidth: metrics.sp * 0.15,
                    serifWidth: metrics.sp * 0.15,
                    serifLength: metrics.sp * 0.5,
                    metrics: metrics
                )
            case .line:
                drawLineBracket(
                    context: &context,
                    bracket: b,
                    staffOriginX: staffOriginX,
                    systemOriginY: system.origin.y,
                    metrics: metrics
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
        context: inout GraphicsContext,
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        systemOriginY: CGFloat,
        spineWidth: CGFloat,
        serifWidth: CGFloat,
        serifLength: CGFloat,
        metrics: StaffMetrics
    ) {
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: metrics.sp
        )
        let topY = systemOriginY + b.topY
        let botY = systemOriginY + b.bottomY
        var spine = Path()
        spine.move(to: CGPoint(x: x, y: topY))
        spine.addLine(to: CGPoint(x: x, y: botY))
        context.stroke(
            spine, with: .color(.primary), lineWidth: spineWidth
        )
        for y in [topY, botY] {
            var serif = Path()
            serif.move(to: CGPoint(x: x, y: y))
            serif.addLine(to: CGPoint(x: x + serifLength, y: y))
            context.stroke(
                serif, with: .color(.primary), lineWidth: serifWidth
            )
        }
    }

    private static func drawLineBracket(
        context: inout GraphicsContext,
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        systemOriginY: CGFloat,
        metrics: StaffMetrics
    ) {
        let x = bracketSpineX(
            column: b.column, staffOriginX: staffOriginX, sp: metrics.sp
        )
        var spine = Path()
        spine.move(to: CGPoint(x: x, y: systemOriginY + b.topY))
        spine.addLine(to: CGPoint(x: x, y: systemOriginY + b.bottomY))
        context.stroke(
            spine, with: .color(.primary), lineWidth: metrics.sp * 0.15
        )
    }

    /// SMuFL brace glyph (Bravura Private Use Area codepoint).
    /// `UnicodeScalar(0xE000)` is always valid (PUA block), so the
    /// literal character avoids a force-unwrap at each call site.
    private static let braceCharacter: Character = "\u{E000}"

    /// Brace via Bravura `U+E000`. Y-scaled to fit the requested span.
    private static func drawBrace(
        context: inout GraphicsContext,
        bracket b: LayoutBracket,
        staffOriginX: CGFloat,
        systemOriginY: CGFloat,
        metrics: StaffMetrics
    ) {
        _ = BravuraFont.register
        let target = b.bottomY - b.topY
        let nominalSize = metrics.sp * 4
        let braceText = Text(String(braceCharacter))
            .font(.custom(BravuraFont.familyName, fixedSize: nominalSize))
        let resolved = context.resolve(braceText)
        let measured = resolved.measure(in: CGSize(
            width: 100, height: 1000
        ))
        guard measured.height > 0 else { return }
        let yScale = target / measured.height
        let xPos = staffOriginX - metrics.sp * 0.3 - measured.width
        let yPos = systemOriginY + b.topY
        var sub = context
        sub.translateBy(x: xPos, y: yPos)
        sub.scaleBy(x: 1, y: yScale)
        sub.draw(resolved, at: .zero, anchor: .topLeading)
    }
}
