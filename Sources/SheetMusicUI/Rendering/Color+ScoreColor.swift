import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
extension Color {
    /// Convert MuseScore's 8-bit RGBA `ScoreColor` into a SwiftUI
    /// `Color`. Used by the Canvas renderer to honour author-supplied
    /// `<color>` on noteheads, stems, beams, lyrics, etc. A `nil`
    /// source colour maps to `.primary` (default ink) at the call site.
    init(scoreColor: ScoreColor) {
        self.init(
            red: Double(scoreColor.red) / 255,
            green: Double(scoreColor.green) / 255,
            blue: Double(scoreColor.blue) / 255,
            opacity: Double(scoreColor.alpha) / 255,
        )
    }
}
