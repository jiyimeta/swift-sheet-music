import SheetMusicLayout
import SwiftUI

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
@available(macOS 15.0, *)
enum TupletRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        text: String,
        hasBracket: Bool,
        isAbove: Bool,
        metrics: StaffMetrics,
        color: Color = .primary,
    ) {
        let segments = TupletBracketGeometry.segments(
            from: from, to: to, isAbove: isAbove, sp: metrics.sp,
        )
        let fontSize = TupletBracketGeometry.labelFontSizeSp * metrics.sp
        // Draw the number first so we can cut a gap in the bracket
        // around it.
        context.drawExpressionText(
            text,
            at: segments.labelCenter,
            size: fontSize,
            italic: true,
            color: color,
            anchor: .center,
        )
        guard hasBracket else { return }
        let lineWidth = TupletBracketGeometry.lineThicknessSp * metrics.sp
        stroke(
            from: segments.leftHookFrom, to: segments.leftHookTo,
            width: lineWidth, color: color, into: &context,
        )
        stroke(
            from: segments.rightHookFrom, to: segments.rightHookTo,
            width: lineWidth, color: color, into: &context,
        )
        stroke(
            from: segments.leftSegFrom, to: segments.leftSegTo,
            width: lineWidth, color: color, into: &context,
        )
        stroke(
            from: segments.rightSegFrom, to: segments.rightSegTo,
            width: lineWidth, color: color, into: &context,
        )
    }

    private static func stroke(
        from: CGPoint, to: CGPoint,
        width: CGFloat, color: Color,
        into context: inout GraphicsContext,
    ) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), lineWidth: width)
    }
}
