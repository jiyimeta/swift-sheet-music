import SheetMusicCore

/// SMuFL codepoints for the round parentheses drawn around a notehead.
/// Single source of truth so the CALayer renderer, the SwiftUI Canvas
/// renderer, and the Android bridge agree. Mirrors `AccidentalGlyph.enclosure`.
public enum NoteheadParenthesisGlyph {
    /// Returns the left/right parenthesis codepoints for `parentheses`.
    /// A side is `nil` when it should not be drawn.
    public static func glyphs(
        for parentheses: NoteParentheses,
    ) -> (left: UInt32?, right: UInt32?) {
        (
            left: parentheses.hasLeft ? SMuFLCodepoint.noteheadParenthesisLeft : nil,
            right: parentheses.hasRight ? SMuFLCodepoint.noteheadParenthesisRight : nil,
        )
    }
}
