#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// Where a chord's leading grace notes sit, and how far left of their chord they reach.
///
/// MuseScore lays a chord's before-graces out as one group (`TLayout::layoutGraceNotesGroup`): right to left, each
/// grace as close to its right-hand neighbour as their shapes allow, `Sid::graceToGraceNoteDist` (0.3 sp) apart, and
/// the whole group as close to its chord as the chord's own shape — its accidentals included — allows,
/// `Sid::graceToMainNoteDist` (0.45 sp) apart. The room the group takes is then part of the chord's SHAPE, which the
/// horizontal spacing keeps clear of the previous chord (`HorizontalSpacing::minHorizontalDistance`, the paddings at
/// `horizontalspacing.cpp:1498–1506`) — a floor, not a width added to the duration's. A grace only widens the gap
/// before its chord when that gap was too narrow to hold it.
///
/// This engine used to do neither. Each grace stood a fixed 1.5 sp further left of its chord's x, so a grace on a note
/// with an accidental was drawn on top of the accidental; and 1.5 sp per grace was added to the PREVIOUS column's
/// spacing weight, which the system's stretch then multiplied — one acciaccatura before a sixteenth spread its beat
/// several staff spaces wider than MuseScore does, and graces on a bar's first chord got no room at all (reported
/// 2026-10-11).
///
/// The shapes here are horizontal extents, like the rest of the collision floor (`ColumnInk`), with one concession to
/// MuseScore's two-dimensional shapes: a grace's flag is drawn a stem's length above its head, where it rides over the
/// accidental of the note to its right, so it keeps clear of that note's HEAD only. The MuseScore 4 reference render
/// of the report's bar shows the same — the flag ends 0.27 sp short of the next head, over the sharp before it.
extension LayoutEngine {
    /// MuseScore's `Sid::graceToMainNoteDist`: between a chord's leading graces and the chord's own ink.
    static let graceToMainNoteDistSp: CGFloat = 0.45
    /// MuseScore's `Sid::graceToGraceNoteDist`: between two neighbouring graces.
    static let graceToGraceNoteDistSp: CGFloat = 0.3
    /// How close a grace's flag comes to the notehead on its right — see the extension's header.
    static let graceFlagClearanceSp: CGFloat = 0.2
    /// What the previous column's `ColumnInk.reach` padding (note → accidental, 0.35 sp) is short of MuseScore's
    /// main-note-to-grace padding (`graceToMainNoteDist`, 0.45 sp); added to a grace group's reach so the floor between
    /// the two is MuseScore's.
    static let graceReachPaddingTopUpSp: CGFloat = 0.1

    /// One grace chord's horizontal ink, measured from its own x (its noteheads' center, where `stemOrigin` sits).
    struct GraceInk: Equatable {
        /// To the left edge of its leftmost accidental, else of its noteheads.
        var left: CGFloat
        /// To the right edge of its noteheads.
        var headRight: CGFloat
        /// To the right edge of its flag; `headRight` when it draws none, or when the flag ends inside the heads.
        var flagRight: CGFloat
    }

    /// `grace`'s ink at magnification `mag`, drawn the way every renderer draws a grace chord: as a full chord at
    /// `staffSize × mag` (`ScoreCanvas.drawGraceChord`), never beamed. `stem` is the grace's own direction; `nil` —
    /// the spacing pass, which runs before the clef that decides it is known — takes the wider of the two, up.
    static func graceInk(
        of grace: GraceChord, stem: StemDirection?, mag: CGFloat, metrics: StaffMetrics,
    ) -> GraceInk {
        let scaled = StaffMetrics(staffSize: metrics.staffHeight * mag)
        let sp = scaled.sp
        let halfHead = StemGeometry.attachDx(sp: sp)
        let displaced = holdsSecond(Array(grace.notes)) ? sp * secondDisplacementSp : 0
        let headEdge = halfHead + displaced
        let left = max(headEdge, accidentalReach(of: Array(grace.notes), headEdge: headEdge, metrics: scaled))
        let direction = stem ?? .up
        var flagRight = headEdge
        if let glyph = FlagGlyph.codepoint(duration: grace.duration, stem: direction) {
            let stemX = direction == .up ? halfHead : -halfHead
            flagRight = max(flagRight, stemX + bravuraAdvance(glyph, metrics: scaled))
        }
        return GraceInk(left: left, headRight: headEdge, flagRight: flagRight)
    }

    /// The x of each of `chord`'s leading graces, left to right, relative to the chord's own x — so all negative.
    ///
    /// Built right to left from the chord: each grace is placed as close to what stands on its right as both rules
    /// allow — its head (and stem) `graceToMainNoteDist` / `graceToGraceNoteDist` clear of that neighbour's leftmost
    /// ink, its flag `graceFlagClearanceSp` clear of that neighbour's heads — and then becomes the neighbour of the
    /// next one out. `stems` are the graces' own directions, in the same order; `nil` (the spacing pass) assumes up.
    static func beforeGraceOffsets(
        of chord: Chord, stems: [StemDirection]? = nil, mag: CGFloat, metrics: StaffMetrics,
    ) -> [CGFloat] {
        let graces = Array(chord.graceNotesBefore.values)
        guard !graces.isEmpty else { return [] }
        let sp = metrics.sp
        let main = mainChordLeft(of: chord, metrics: metrics)
        // Positions, relative to the chord's x, of what stands right of the grace being placed: its leftmost ink and
        // the left edge of its heads.
        var neighbourInk = -main.ink
        var neighbourHeads = -main.heads
        var padding = graceToMainNoteDistSp * sp
        var offsets = [CGFloat](repeating: 0, count: graces.count)
        for index in graces.indices.reversed() {
            let ink = graceInk(of: graces[index], stem: stems?[index], mag: mag, metrics: metrics)
            let x = min(
                neighbourInk - padding - ink.headRight,
                neighbourHeads - graceFlagClearanceSp * sp - ink.flagRight,
            )
            offsets[index] = x
            neighbourInk = x - ink.left
            neighbourHeads = x - ink.headRight
            padding = graceToGraceNoteDistSp * sp
        }
        return offsets
    }

    /// How far left of `chord`'s x its leading graces reach — the leftmost one's ink, plus the padding top-up that
    /// makes the floor against the previous column MuseScore's (`graceReachPaddingTopUpSp`). `0` with no graces.
    static func beforeGraceReach(of chord: Chord, mag: CGFloat, metrics: StaffMetrics) -> CGFloat {
        guard let first = chord.graceNotesBefore.values.first,
              let x = beforeGraceOffsets(of: chord, mag: mag, metrics: metrics).first
        else { return 0 }
        let ink = graceInk(of: first, stem: nil, mag: mag, metrics: metrics)
        return -x + ink.left + graceReachPaddingTopUpSp * metrics.sp
    }

    /// From `chord`'s x to the left edge of its noteheads, and to its leftmost ink — the heads, or the accidentals in
    /// front of them. A head pushed across the stem by a second is assumed to go left, as `columnInk` assumes.
    private static func mainChordLeft(of chord: Chord, metrics: StaffMetrics) -> (heads: CGFloat, ink: CGFloat) {
        let sp = metrics.sp
        let (base, _) = DurationInterpretation.split(chord.duration)
        let displaced = holdsSecond(Array(chord.notes)) ? sp * secondDisplacementSp : 0
        let attach = StemGeometry.attachDx(sp: sp)
        // A whole note's head is wider than the black one `attachDx` halves (Bravura `noteheadWhole` 1.688 sp); its
        // accidental is still placed from `attachDx`, as every renderer places it (`AccidentalPlacement.leftEdgeX`).
        let heads = (base == .whole ? sp * 1.688 / 2 : attach) + displaced
        let accidentals = accidentalReach(of: Array(chord.notes), headEdge: attach + displaced, metrics: metrics)
        return (heads, max(heads, accidentals))
    }
}
