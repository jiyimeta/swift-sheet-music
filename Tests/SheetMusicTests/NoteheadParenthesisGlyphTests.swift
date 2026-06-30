#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

struct NoteheadParenthesisGlyphTests {
    @Test func glyphsPerMode() {
        let both = NoteheadParenthesisGlyph.glyphs(for: .both)
        #expect(both.left == SMuFLCodepoint.noteheadParenthesisLeft)
        #expect(both.right == SMuFLCodepoint.noteheadParenthesisRight)

        let left = NoteheadParenthesisGlyph.glyphs(for: .left)
        #expect(left.left == SMuFLCodepoint.noteheadParenthesisLeft)
        #expect(left.right == nil)

        let right = NoteheadParenthesisGlyph.glyphs(for: .right)
        #expect(right.left == nil)
        #expect(right.right == SMuFLCodepoint.noteheadParenthesisRight)

        let none = NoteheadParenthesisGlyph.glyphs(for: .none)
        #expect(none.left == nil && none.right == nil)
    }

    @Test func placementBracketsTheNotehead() {
        let sp: CGFloat = 10
        let center: CGFloat = 100
        let adv: CGFloat = 4
        let leftX = NoteheadParenthesisPlacement.leftParenCenterX(
            noteheadCenterX: center, parenAdvance: adv, sp: sp,
        )
        let rightX = NoteheadParenthesisPlacement.rightParenCenterX(
            noteheadCenterX: center, parenAdvance: adv, sp: sp,
        )
        // Left paren center sits left of the notehead center; right paren right of it.
        #expect(leftX < center)
        #expect(rightX > center)
        // Symmetric about the notehead center for equal advances.
        #expect(abs((center - leftX) - (rightX - center)) < 0.0001)
    }
}
