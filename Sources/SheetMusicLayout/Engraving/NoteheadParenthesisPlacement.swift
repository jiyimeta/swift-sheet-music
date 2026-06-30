#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Shared geometry for placing round parentheses to the left and right of a
/// notehead. Single source of truth consumed by the CALayer renderer, the
/// SwiftUI Canvas renderer, and the Android bridge so all three agree on
/// offsets. Mirrors `AccidentalPlacement`.
public enum NoteheadParenthesisPlacement {
    /// Gap between a parenthesis's inner edge and the notehead's edge,
    /// in staff spaces. Tuned visually against the real fixture.
    public static let gapSp: CGFloat = 0.16

    /// Center x of the LEFT parenthesis (renderers draw center-anchored
    /// glyphs). The parenthesis's right edge sits `gapSp * sp` left of the
    /// notehead's left edge; `StemGeometry.attachDx` is the notehead's
    /// half-advance (Bravura `noteheadBlack` half-width = 0.59 sp).
    public static func leftParenCenterX(
        noteheadCenterX: CGFloat,
        parenAdvance: CGFloat,
        sp: CGFloat,
    ) -> CGFloat {
        noteheadCenterX - StemGeometry.attachDx(sp: sp) - gapSp * sp - parenAdvance / 2
    }

    /// Center x of the RIGHT parenthesis. Its left edge sits `gapSp * sp`
    /// right of the notehead's right edge.
    public static func rightParenCenterX(
        noteheadCenterX: CGFloat,
        parenAdvance: CGFloat,
        sp: CGFloat,
    ) -> CGFloat {
        noteheadCenterX + StemGeometry.attachDx(sp: sp) + gapSp * sp + parenAdvance / 2
    }
}
