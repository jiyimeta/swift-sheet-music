import SheetMusicFoundation

/// SMuFL codepoint selection for the standard measure-repeat glyphs
/// (1, 2, or 4 bars). Unknown counts fall back to the 1-bar symbol,
/// matching MuseScore's behavior when the count is not one of the
/// engraved variants.
public enum MeasureRepeatGlyph {
    public static func codepoint(forCount count: Int) -> UInt32 {
        switch count {
        case 2: return SMuFLCodepoint.repeat2Bars
        case 4: return SMuFLCodepoint.repeat4Bars
        default: return SMuFLCodepoint.repeat1Bar
        }
    }
}
