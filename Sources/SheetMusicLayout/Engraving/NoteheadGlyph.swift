import SheetMusicCore

/// SMuFL codepoint selector for noteheads.
///
/// Picks the glyph from `(duration, headType)`. `headType` is the raw
/// string MuseScore stores on `Note.headType` ("normal" / nil for the
/// default, plus "cross", "diamond", "triangle-up", "triangle-down").
/// Unknown head types fall back to the standard family.
///
/// The standard / cross / diamond families have whole / half / black
/// variants. The triangle families only have a black variant in
/// Bravura (whole/half are not part of SMuFL), so triangle heads
/// always use the black glyph regardless of `duration`.
public enum NoteheadGlyph {
    public static func codepoint(
        duration: NoteDuration, headType: String?,
    ) -> UInt32 {
        switch headType {
        case "cross":
            switch duration {
            case .whole: return SMuFLCodepoint.noteheadXWhole
            case .half: return SMuFLCodepoint.noteheadXHalf
            default: return SMuFLCodepoint.noteheadXBlack
            }
        case "diamond":
            switch duration {
            case .whole: return SMuFLCodepoint.noteheadDiamondWhole
            case .half: return SMuFLCodepoint.noteheadDiamondHalf
            default: return SMuFLCodepoint.noteheadDiamondBlack
            }
        case "triangle-up":
            return SMuFLCodepoint.noteheadTriangleUpBlack
        case "triangle-down":
            return SMuFLCodepoint.noteheadTriangleDownBlack
        default:
            switch duration {
            case .whole: return SMuFLCodepoint.noteheadWhole
            case .half: return SMuFLCodepoint.noteheadHalf
            default: return SMuFLCodepoint.noteheadBlack
            }
        }
    }
}
