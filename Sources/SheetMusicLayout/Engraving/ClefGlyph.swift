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

    /// Extra Y offset, in staff spaces, that `clef` picks up on a staff
    /// drawing other than five lines. Added to the emitted clef origin,
    /// so every renderer inherits it through `LayoutElement.clef`
    /// without knowing the staff's line count.
    ///
    /// Only the percussion clefs move. MuseScore centers them on the
    /// staff's own height — `TLayout` `tlayout.cpp:1706-1710`,
    /// `case ClefType::PERC / PERC2: yoff = lineDist * (lines - 1) * 0.5`
    /// — while every pitched clef keeps `tlayout.cpp:1687`'s
    /// `yoff = lineDist * (5 - ClefInfo::line(clefType))`, a hardcoded
    /// 5 that never consults `lines()`. That is the same reference-frame
    /// rule `StaffLineGeometry.topStep` records for note positions: a G
    /// clef on a three-line staff stays anchored where a five-line staff
    /// would put it, and "fixing" it would desynchronize the clef from
    /// the notes it governs.
    ///
    /// Listed case by case rather than defaulted so a clef type added
    /// later has to state which side of that rule it falls on.
    public static func staffCenteringOffsetSp(
        for clef: NotatedClef, lineGeometry: StaffLineGeometry,
    ) -> CGFloat {
        switch clef {
        case .treble, .treble8va, .treble8vb, .treble15ma, .treble15mb,
             .bass, .bass8va, .bass8vb,
             .soprano, .alto, .tenor, .baritone:
            0
        case .percussion, .percussion2:
            lineGeometry.centerOffsetSp
        }
    }
}
