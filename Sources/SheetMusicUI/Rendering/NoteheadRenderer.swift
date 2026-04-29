import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum NoteheadRenderer {
    /// Pick the SMuFL glyph for a note, accounting for an optional
    /// head-type override (percussion cross, diamond, triangle, etc.)
    /// and the duration (whole, half, filled).
    static func glyph(
        for duration: NoteDuration,
        headType: String? = nil
    ) -> Character {
        switch headType {
        case "cross":
            switch duration {
            case .whole: return SMuFLGlyph.noteheadXWhole
            case .half:  return SMuFLGlyph.noteheadXHalf
            default:     return SMuFLGlyph.noteheadXBlack
            }
        case "diamond":
            switch duration {
            case .whole: return SMuFLGlyph.noteheadDiamondWhole
            case .half:  return SMuFLGlyph.noteheadDiamondHalf
            default:     return SMuFLGlyph.noteheadDiamondBlack
            }
        case "triangle-up":
            return SMuFLGlyph.noteheadTriangleUpBlack
        case "triangle-down":
            return SMuFLGlyph.noteheadTriangleDownBlack
        default:
            // "normal" or nil → standard notehead
            switch duration {
            case .whole: return SMuFLGlyph.noteheadWhole
            case .half:  return SMuFLGlyph.noteheadHalf
            default:     return SMuFLGlyph.noteheadBlack
            }
        }
    }

    static func drawHead(
        context: inout GraphicsContext,
        at origin: CGPoint,
        duration: NoteDuration,
        headType: String? = nil,
        metrics: StaffMetrics
    ) {
        context.drawGlyph(
            glyph(for: duration, headType: headType),
            at: origin,
            size: metrics.glyphFontSize
        )
    }
}
