import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum AccidentalRenderer {
    /// Draw an accidental (plus optional bracket enclosure) for a notehead.
    ///
    /// Uses `AccidentalPlacement.leftEdgeX` as the shared source of truth so
    /// the Canvas path agrees with the CALayer (`ScoreLayerBuilder+Chord`) and
    /// Android bridge (`LayoutBridge+Chord`) renderers.
    ///
    /// - Parameters:
    ///   - context: SwiftUI `GraphicsContext` to draw into.
    ///   - accidental: The accidental to render.
    ///   - bracket: Optional parenthesis / bracket enclosure (`.none` = none).
    ///   - origin: Center of the notehead in canvas coordinates.
    ///   - metrics: Staff sizing metrics.
    static func draw(
        context: inout GraphicsContext,
        accidental: Accidental,
        bracket: AccidentalBracket = .none,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        // Glyph table is shared with the CALayer and Android paths via
        // `AccidentalGlyph` so the three renderers can't disagree.
        // swiftlint:disable:next force_unwrapping
        let accChar = Character(UnicodeScalar(AccidentalGlyph.codepoint(accidental))!)
        let bravuraFont = LayoutFont(
            face: SMuFLFamily.bravura,
            pointSize: metrics.glyphFontSize,
        )
        let accAdv = FontMetrics.provider.typographicWidth(
            text: String(accChar), font: bravuraFont,
        )
        // Measure optional bracket enclosure advances.
        var leftBracketAdv: CGFloat = 0
        var rightBracketAdv: CGFloat = 0
        var leftBracketChar: Character?
        var rightBracketChar: Character?
        if let (lCp, rCp) = AccidentalGlyph.enclosure(bracket),
           let lSc = UnicodeScalar(lCp), let rSc = UnicodeScalar(rCp)
        {
            leftBracketChar = Character(lSc)
            rightBracketChar = Character(rSc)
            leftBracketAdv = FontMetrics.provider.typographicWidth(
                text: String(lSc), font: bravuraFont,
            )
            rightBracketAdv = FontMetrics.provider.typographicWidth(
                text: String(rSc), font: bravuraFont,
            )
        }
        let totalAdv = leftBracketAdv + accAdv + rightBracketAdv
        // Notehead left edge = center - half-advance (Bravura: 0.59 sp).
        let noteheadLeftX = origin.x - StemGeometry.attachDx(sp: metrics.sp)
        let leftEdgeX = AccidentalPlacement.leftEdgeX(
            noteheadLeftX: noteheadLeftX,
            advanceWidth: totalAdv,
            sp: metrics.sp,
        )
        // Left bracket.
        if let lChar = leftBracketChar {
            context.drawGlyph(
                lChar,
                at: CGPoint(x: leftEdgeX + leftBracketAdv / 2, y: origin.y),
                size: metrics.glyphFontSize,
            )
        }
        // Accidental.
        context.drawGlyph(
            accChar,
            at: CGPoint(
                x: leftEdgeX + leftBracketAdv + accAdv / 2,
                y: origin.y,
            ),
            size: metrics.glyphFontSize,
        )
        // Right bracket.
        if let rChar = rightBracketChar {
            context.drawGlyph(
                rChar,
                at: CGPoint(
                    x: leftEdgeX + leftBracketAdv + accAdv + rightBracketAdv / 2,
                    y: origin.y,
                ),
                size: metrics.glyphFontSize,
            )
        }
    }
}
