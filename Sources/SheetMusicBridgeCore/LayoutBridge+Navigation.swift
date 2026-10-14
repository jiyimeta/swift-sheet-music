import SheetMusicCore
import SheetMusicLayout

extension LayoutBridge {
    /// The color a marker or jump is painted in: its author color — unless it is selected (the selection tint is
    /// already in force) or drawn in the invisible pass (the pass's grey wins, as MuseScore greys every hidden element
    /// whatever its color). `nil` leaves the ambient color alone.
    static func navigationArgb(_ color: ScoreColor?, markArgb: UInt32?, ambientArgb: UInt32) -> UInt32? {
        guard markArgb == nil, ambientArgb == blackARGB else { return nil }
        return color.flatMap(argb(from:))
    }
}
