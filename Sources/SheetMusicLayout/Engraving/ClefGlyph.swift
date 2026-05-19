#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// Maps a typed `NotatedClef` to the SMuFL codepoint that renders it and
/// the staff-space Y offset from the staff-middle reference line.
///
/// The Y offset is in staff-spaces (sp), not points. Renderers multiply
/// by their `StaffMetrics.sp` to convert. Positive offsets move DOWN in
/// y-down screen coordinates (so a treble clef whose curl sits below the
/// middle line uses `+1`).
public enum ClefGlyph {
    /// SMuFL codepoint + Y offset (staff-spaces, relative to the staff
    /// middle line) for `clef`.
    public static func glyph(
        for clef: NotatedClef,
    ) -> (codepoint: UInt32, yOffsetSp: CGFloat) {
        switch clef {
        case .treble: (SMuFLCodepoint.gClef, 1)
        case .treble8va: (SMuFLCodepoint.gClef8va, 1)
        case .treble8vb: (SMuFLCodepoint.gClef8vb, 1)
        case .treble15ma: (SMuFLCodepoint.gClef15ma, 1)
        case .treble15mb: (SMuFLCodepoint.gClef15mb, 1)
        case .bass: (SMuFLCodepoint.fClef, -1)
        case .bass8va: (SMuFLCodepoint.fClef8va, -1)
        case .bass8vb: (SMuFLCodepoint.fClef8vb, -1)
        case .soprano: (SMuFLCodepoint.cClef, 2)
        case .alto: (SMuFLCodepoint.cClef, 0)
        case .tenor: (SMuFLCodepoint.cClef, -1)
        case .baritone: (SMuFLCodepoint.cClef, -2)
        case .percussion: (SMuFLCodepoint.percussionClef, 0)
        case .percussion2: (SMuFLCodepoint.percussionClef2, 0)
        }
    }
}
