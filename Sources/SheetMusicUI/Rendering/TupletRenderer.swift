import SwiftUI
import SheetMusicLayout

/// Draws a tuplet marking — either a square bracket with hooks at each
/// end and a number in the middle (non-beamed tuplets), or just the
/// number centred over the beam (beamed tuplets).
///
/// Follows MuseScore's convention from
/// `src/engraving/rendering/score/tupletlayout.cpp`:
/// - `hasBracket == true` draws `|‾‾‾ N ‾‾‾|` with short vertical
///   hooks on each end.
/// - `hasBracket == false` draws just the number.
///
/// The label is drawn in an italic serif, matching engraved scores.
@available(macOS 15.0, iOS 16.0, *)
enum TupletRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        text: String,
        hasBracket: Bool,
        isAbove: Bool,
        metrics: StaffMetrics,
        color: Color = .primary
    ) {
        let fontSize = metrics.sp * 2
        let labelX = (from.x + to.x) / 2
        let labelY = (from.y + to.y) / 2
        // Draw the number first so we can cut a gap in the bracket
        // around it.
        context.drawExpressionText(
            text,
            at: CGPoint(x: labelX, y: labelY),
            size: fontSize,
            italic: true,
            color: color,
            anchor: .center)
        guard hasBracket else { return }
        // Approximate label width for the gap; errs on the side of
        // being slightly wide so the bracket never touches the glyphs.
        let labelHalfWidth = fontSize * 0.4
        let hook: CGFloat = metrics.sp * 0.8
        let hookSign: CGFloat = isAbove ? 1 : -1
        let hookDy = hook * hookSign
        let lineWidth: CGFloat = metrics.sp * 0.12
        // Left hook
        var leftHook = Path()
        leftHook.move(to: CGPoint(x: from.x, y: from.y + hookDy))
        leftHook.addLine(to: from)
        context.stroke(
            leftHook, with: .color(color), lineWidth: lineWidth)
        // Right hook
        var rightHook = Path()
        rightHook.move(to: CGPoint(x: to.x, y: to.y + hookDy))
        rightHook.addLine(to: to)
        context.stroke(
            rightHook, with: .color(color), lineWidth: lineWidth)
        // Horizontal — two segments, interrupted by the label.
        var leftSeg = Path()
        leftSeg.move(to: from)
        leftSeg.addLine(to: CGPoint(
            x: labelX - labelHalfWidth,
            y: interpY(from: from, to: to, x: labelX - labelHalfWidth)))
        context.stroke(
            leftSeg, with: .color(color), lineWidth: lineWidth)
        var rightSeg = Path()
        rightSeg.move(to: CGPoint(
            x: labelX + labelHalfWidth,
            y: interpY(from: from, to: to, x: labelX + labelHalfWidth)))
        rightSeg.addLine(to: to)
        context.stroke(
            rightSeg, with: .color(color), lineWidth: lineWidth)
    }

    private static func interpY(
        from: CGPoint, to: CGPoint, x: CGFloat
    ) -> CGFloat {
        let span = to.x - from.x
        guard abs(span) > 0.01 else { return from.y }
        let t = (x - from.x) / span
        return from.y + (to.y - from.y) * t
    }
}
