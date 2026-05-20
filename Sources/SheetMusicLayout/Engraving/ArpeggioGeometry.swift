#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Vertical stack of arpeggio "wiggle" SMuFL segments drawn to the
/// left of a chord, with an optional arrow glyph at one end.
///
/// SMuFL `wiggleArpeggiatoUp` (and the arrow variants) are drawn
/// horizontally in the font; vertical arpeggios rotate each segment
/// -90° around its anchor. Mirrors MuseScore's `Arpeggio::draw`
/// (`painter->rotate(-90)`).
public enum ArpeggioGeometry {
    /// One placed glyph in the stack. `origin` is the rotation
    /// anchor (also the glyph's reference point before rotation).
    /// Apple/Android both apply a -90° rotation around `origin` to
    /// orient the horizontal SMuFL glyph vertically.
    public struct Segment: Sendable, Equatable {
        public let codepoint: UInt32
        public let origin: CGPoint
    }

    /// X offset from the top notehead to the wiggle column.
    public static func xOffsetSp(sp: CGFloat) -> CGFloat {
        sp * 1.5
    }

    /// Resolve the full segment list for an arpeggio spanning from
    /// `top` to `bottom`. `subtype` selects the arrow variant
    /// (`"up"`, `"down"`, or nil for no arrow).
    public static func segments(
        top: CGPoint, bottom: CGPoint, subtype: String?, sp: CGFloat,
    ) -> [Segment] {
        var result: [Segment] = []
        let x = top.x - xOffsetSp(sp: sp)
        var y = top.y
        while y <= bottom.y {
            result.append(Segment(
                codepoint: SMuFLCodepoint.arpeggioWiggle,
                origin: CGPoint(x: x, y: y),
            ))
            y += sp
        }
        switch subtype {
        case "up":
            result.append(Segment(
                codepoint: SMuFLCodepoint.arpeggioUpArrow,
                origin: CGPoint(x: x, y: top.y - sp),
            ))
        case "down":
            result.append(Segment(
                codepoint: SMuFLCodepoint.arpeggioDownArrow,
                origin: CGPoint(x: x, y: bottom.y + sp),
            ))
        default:
            break
        }
        return result
    }
}
