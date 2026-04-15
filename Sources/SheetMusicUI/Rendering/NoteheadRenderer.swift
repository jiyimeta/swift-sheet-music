#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
enum NoteheadRenderer {
    static func glyph(for duration: NoteDuration) -> Character {
        switch duration {
        case .whole: return SMuFLGlyph.noteheadWhole
        case .half: return SMuFLGlyph.noteheadHalf
        default: return SMuFLGlyph.noteheadBlack
        }
    }

    static func drawHead(
        context: inout GraphicsContext,
        at origin: CGPoint,
        duration: NoteDuration,
        metrics: StaffMetrics
    ) {
        context.drawGlyph(
            glyph(for: duration),
            at: origin,
            size: metrics.glyphFontSize
        )
    }
}
#endif
