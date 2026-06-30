import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum NoteheadParenthesisRenderer {
    /// Draw round parentheses around a notehead in the SwiftUI Canvas path.
    /// Shares `NoteheadParenthesisGlyph` / `NoteheadParenthesisPlacement` with
    /// the CALayer and Android paths so the three renderers can't disagree.
    ///
    /// - Parameters:
    ///   - context: SwiftUI `GraphicsContext` to draw into.
    ///   - parentheses: Which parentheses to render (left, right, both, or none).
    ///   - origin: Center of the notehead in canvas coordinates.
    ///   - color: Notehead color (parens match the head).
    ///   - metrics: Staff sizing metrics.
    static func draw(
        context: inout GraphicsContext,
        parentheses: NoteParentheses,
        origin: CGPoint,
        color: Color = .primary,
        metrics: StaffMetrics,
    ) {
        guard parentheses != .none else { return }
        let (leftCp, rightCp) = NoteheadParenthesisGlyph.glyphs(for: parentheses)
        let bravuraFont = LayoutFont(
            face: SMuFLFamily.bravura,
            pointSize: metrics.glyphFontSize,
        )
        if let leftCp, let lSc = UnicodeScalar(leftCp) {
            let adv = FontMetrics.provider.typographicWidth(text: String(lSc), font: bravuraFont)
            let x = NoteheadParenthesisPlacement.leftParenCenterX(
                noteheadCenterX: origin.x, parenAdvance: adv, sp: metrics.sp,
            )
            context.drawGlyph(
                Character(lSc), at: CGPoint(x: x, y: origin.y),
                size: metrics.glyphFontSize, color: color,
            )
        }
        if let rightCp, let rSc = UnicodeScalar(rightCp) {
            let adv = FontMetrics.provider.typographicWidth(text: String(rSc), font: bravuraFont)
            let x = NoteheadParenthesisPlacement.rightParenCenterX(
                noteheadCenterX: origin.x, parenAdvance: adv, sp: metrics.sp,
            )
            context.drawGlyph(
                Character(rSc), at: CGPoint(x: x, y: origin.y),
                size: metrics.glyphFontSize, color: color,
            )
        }
    }
}
