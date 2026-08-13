#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Shared geometry for placing accidental glyphs to the left of a notehead.
/// Single source of truth consumed by the CALayer renderer, the SwiftUI
/// Canvas renderer, and the Android bridge so all three agree on offsets.
public enum AccidentalPlacement {
    /// Gap between the accidental group's right edge and the notehead's
    /// left edge, in staff spaces.
    public static let gapSp: CGFloat = 0.16

    /// Returns the x-coordinate of the **typographic left edge** of the
    /// accidental glyph group (accidental alone, or left-enclosure when
    /// bracketed). The group's right edge sits `gapSp * sp` left of
    /// `noteheadLeftX`.
    ///
    /// - Parameters:
    ///   - noteheadLeftX: Left edge of the notehead's typographic advance.
    ///     Use `noteheadCenterX - StemGeometry.attachDx(sp: sp)` for Bravura
    ///     (half-advance = 0.59 sp).
    ///   - advanceWidth: Total typographic advance of the accidental group
    ///     (accidental only when no bracket; left-enclosure + accidental +
    ///     right-enclosure when bracketed).
    ///   - sp: One staff space in points.
    public static func leftEdgeX(
        noteheadLeftX: CGFloat,
        advanceWidth: CGFloat,
        sp: CGFloat,
    ) -> CGFloat {
        noteheadLeftX - gapSp * sp - advanceWidth
    }
}
