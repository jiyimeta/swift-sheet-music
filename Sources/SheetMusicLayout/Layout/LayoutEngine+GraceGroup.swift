#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// Where a chord's grace notes sit: its leading graces before it, its trailing graces before whatever follows it.
///
/// MuseScore lays a chord's before-graces out as one group (`TLayout::layoutGraceNotesGroup`): right to left, each
/// grace as close to what stands on its right as their shapes allow, and the whole group as close to its chord as the
/// chord's own shape — its accidentals included — allows. The room the group takes is then part of the chord's SHAPE,
/// which the horizontal spacing keeps clear of the previous chord (`HorizontalSpacing::minHorizontalDistance`) — a
/// floor, not a width added to the duration's. A grace only widens the gap before its chord when that gap was too
/// narrow to hold it.
///
/// After-graces are the same kind of group, laid out by the same function, but MuseScore pre-appends them to the NEXT
/// segment that holds anything on the staff (`ChordLayout::appendGraceNotes`): they stand right before the next chord
/// or rest — left of that chord's own leading graces, which join the same group — or before the barline when nothing
/// follows in the bar, and their room is part of that segment's shape. The MuseScore 4 rendering of a quarter with an
/// after-grace and a quarter after it puts the grace 1.04 sp before the next head, nowhere near its own chord.
///
/// The distances are MuseScore's padding table (`rendering/paddingtable.cpp`) with the grace rows of
/// `HorizontalSpacing::computeNotePadding`: a grace's head keeps `graceToMainNoteDist` (0.45 sp) from a note or rest
/// and `graceToGraceNoteDist` (0.3 sp) from another grace; every other entry is scaled by the mean of the two items'
/// sizes — a head keeps 0.35 sp from an accidental and `noteBarDistance` (1.5 sp) from a barline, a flag 0.35 sp from
/// a note, accidental or rest and 1 sp from a barline.
///
/// MuseScore's shapes are two-dimensional; these are horizontal extents, like the rest of the collision floor
/// (`ColumnInk`), with one vertical test: a grace's flag hangs from the top of its stem down to its head, so it rides
/// over an accidental that lies wholly above or below that span and keeps clear of one it would cross. MuseScore 4
/// keeps an acciaccatura D's flag 0.3 sp short of the sharp of the F♯ it leads into. Noteheads, rests, barlines and
/// clefs count at every height.
///
/// This engine used to place graces a fixed 1.5 sp per grace from their chord: leading ones on top of its accidentals
/// (reported 2026-10-11), trailing ones right after it rather than before the next note (2026-10-12).
extension LayoutEngine {
    /// MuseScore's `Sid::graceToMainNoteDist`: between a grace's head and a full-size note or rest.
    static let graceToMainNoteDistSp: CGFloat = 0.45
    /// MuseScore's `Sid::graceToGraceNoteDist`: between two neighbouring graces.
    static let graceToGraceNoteDistSp: CGFloat = 0.3
    /// `paddingtable.cpp`: note → accidental, before scaling.
    static let graceAccidentalPaddingSp: CGFloat = 0.35
    /// `paddingtable.cpp`: hook → note, accidental or rest, before scaling.
    static let graceFlagPaddingSp: CGFloat = 0.35
    /// `paddingtable.cpp`: note → barline (`Sid::noteBarDistance`), before scaling.
    static let graceBarlinePaddingSp: CGFloat = 1.5
    /// `paddingtable.cpp`: hook → barline, before scaling.
    static let graceFlagBarlinePaddingSp: CGFloat = 1.0
    /// `paddingtable.cpp`: note → clef, before scaling.
    static let graceClefPaddingSp: CGFloat = 0.8
    /// `paddingtable.cpp`: hook → clef, before scaling.
    static let graceFlagClefPaddingSp: CGFloat = 0.5
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
        /// The staff steps its flag spans when it reaches past the heads — from the outermost head along the stem to
        /// its end, treble-clef steps as `holdsSecond` counts them. `nil` without such a flag.
        var flagSteps: ClosedRange<CGFloat>?
    }

    /// Something a grace group keeps clear of on its right, in the coordinates the group is placed in.
    struct GraceObstacle: Equatable {
        enum Kind: Equatable {
            /// A full-size chord's noteheads.
            case note
            /// Another grace's noteheads.
            case grace
            case accidental
            case rest
            case barline
            case clef
        }

        var kind: Kind
        /// Its left edge.
        var left: CGFloat
        /// The staff steps it covers, treble-clef steps; `nil` when it counts at every height.
        var steps: ClosedRange<CGFloat>?
        /// The size it is drawn at — 1 for a full-size note, the grace size for a grace's ink — which scales the
        /// padding against it, as `HorizontalSpacing::computePadding` scales it.
        var mag: CGFloat = 1
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
        var flagSteps: ClosedRange<CGFloat>?
        if let glyph = FlagGlyph.codepoint(duration: grace.duration, stem: direction) {
            let stemX = direction == .up ? halfHead : -halfHead
            let right = stemX + bravuraAdvance(glyph, metrics: scaled)
            let steps = grace.notes.map { trebleStep(of: $0) }
            if right > headEdge, let top = steps.max(), let bottom = steps.min() {
                flagRight = right
                // One step is half a staff space; the stem runs `defaultStemLength` past the outermost head.
                let length = 2 * scaled.defaultStemLength / metrics.sp
                flagSteps = direction == .up ? top ... top + length : bottom - length ... bottom
            }
        }
        return GraceInk(left: left, headRight: headEdge, flagRight: flagRight, flagSteps: flagSteps)
    }

    /// The x of each of `graces`, left to right, relative to the x `obstacles` are measured from.
    ///
    /// Built right to left: each grace is placed as close to what stands on its right as every padding allows — its
    /// head (and stem) clear of each obstacle, its flag clear of each obstacle its flag crosses — and then becomes the
    /// obstacle the next one out keeps clear of. `stems` are the graces' own directions, in the same order; `nil` —
    /// the spacing pass, before the clef that decides them is known — places each grace where the farther-left of
    /// its two directions would, so the room reserved holds whichever is drawn. An up stem's flag reaches further
    /// right, but a down stem's can be the one that crosses an accidental below the grace.
    static func graceGroupOffsets(
        _ graces: [GraceChord], stems: [StemDirection]?, clearing obstacles: [GraceObstacle],
        mag: CGFloat, metrics: StaffMetrics,
    ) -> [CGFloat] {
        var neighbours = obstacles
        var offsets = [CGFloat](repeating: 0, count: graces.count)
        for index in graces.indices.reversed() {
            let directions = stems.map { [$0[index]] } ?? [.up, .down]
            let inks = directions.map { graceInk(of: graces[index], stem: $0, mag: mag, metrics: metrics) }
            offsets[index] = inks.map { offset(of: $0, clearing: neighbours, mag: mag, sp: metrics.sp) }.min() ?? 0
            neighbours = Self.obstacles(
                ofGrace: graces[index], at: offsets[index], ink: inks[0], mag: mag, metrics: metrics,
            )
        }
        return offsets
    }

    /// The x a grace with `ink` stands at, as close to `obstacles` as every padding allows.
    private static func offset(
        of ink: GraceInk, clearing obstacles: [GraceObstacle], mag: CGFloat, sp: CGFloat,
    ) -> CGFloat {
        var x: CGFloat?
        for obstacle in obstacles {
            let scale = (mag + obstacle.mag) / 2
            var candidate = obstacle.left - headPadding(against: obstacle.kind, scale: scale) * sp - ink.headRight
            if let flagSteps = ink.flagSteps, obstacle.steps.map({ $0.overlaps(flagSteps) }) ?? true {
                candidate = min(
                    candidate, obstacle.left - flagPadding(against: obstacle.kind, scale: scale) * sp - ink.flagRight,
                )
            }
            x = min(x ?? candidate, candidate)
        }
        return x ?? 0
    }

    /// The x of each of `chord`'s leading graces, left to right, relative to the chord's own x — so all negative.
    static func beforeGraceOffsets(
        of chord: Chord, stems: [StemDirection]? = nil, mag: CGFloat, metrics: StaffMetrics,
    ) -> [CGFloat] {
        graceGroupOffsets(
            Array(chord.graceNotesBefore.values), stems: stems, clearing: obstacles(ofChord: chord, metrics: metrics),
            mag: mag, metrics: metrics,
        )
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

    // MARK: - Private

    /// From `chord`'s x to the left edge of its noteheads, and to its leftmost ink — the heads, or the accidentals in
    /// front of them. A head pushed across the stem by a second is assumed to go left, as `columnInk` assumes.
    private static func mainChordLeft(of chord: Chord, metrics: StaffMetrics) -> (heads: CGFloat, ink: CGFloat) {
        let sp = metrics.sp
        let (base, _) = DurationInterpretation.splitNote(chord.duration)
        let displaced = holdsSecond(Array(chord.notes)) ? sp * secondDisplacementSp : 0
        let attach = StemGeometry.attachDx(sp: sp)
        // A whole note's head is wider than the black one `attachDx` halves (Bravura `noteheadWhole` 1.688 sp); its
        // accidental is still placed from `attachDx`, as every renderer places it (`AccidentalPlacement.leftEdgeX`).
        let heads = (wideHeadHalfWidth(base, metrics: metrics) ?? attach) + displaced
        let accidentals = accidentalReach(of: Array(chord.notes), headEdge: attach + displaced, metrics: metrics)
        return (heads, max(heads, accidentals))
    }

    /// A full-size chord's heads and accidentals, relative to its x.
    static func obstacles(ofChord chord: Chord, metrics: StaffMetrics) -> [GraceObstacle] {
        let sp = metrics.sp
        let headEdge = StemGeometry.attachDx(sp: sp) + (holdsSecond(Array(chord.notes)) ? sp * secondDisplacementSp : 0)
        return [GraceObstacle(kind: .note, left: -mainChordLeft(of: chord, metrics: metrics).heads, steps: nil)]
            + accidentalObstacles(of: chord.notes, headEdge: headEdge, origin: 0, mag: 1, metrics: metrics)
    }

    /// A grace's heads and accidentals, the grace standing at `x` with ink `ink`.
    static func obstacles(
        ofGrace grace: GraceChord, at x: CGFloat, ink: GraceInk, mag: CGFloat, metrics: StaffMetrics,
    ) -> [GraceObstacle] {
        [GraceObstacle(kind: .grace, left: x - ink.headRight, steps: nil, mag: mag)]
            + accidentalObstacles(
                of: grace.notes, headEdge: ink.headRight, origin: x, mag: mag,
                metrics: StaffMetrics(staffSize: metrics.staffHeight * mag),
            )
    }

    /// One obstacle per accidental among `notes`, whose heads' left edge is `headEdge` left of `origin`; `metrics` at
    /// the size they are drawn.
    private static func accidentalObstacles(
        of notes: ChordNotes, headEdge: CGFloat, origin: CGFloat, mag: CGFloat, metrics: StaffMetrics,
    ) -> [GraceObstacle] {
        notes.compactMap { note -> GraceObstacle? in
            guard let accidental = note.accidental else { return nil }
            let reach = accidentalReach(of: [note], headEdge: headEdge, metrics: metrics)
            // How far the glyph's ink strays from its baseline, which SMuFL puts on the note's own line or space —
            // taken to both sides, so a flat's tall stem counts below it too and no provider's y direction matters.
            let bounds = FontMetrics.provider.glyphPathBoundingBox(
                font: LayoutFont(face: SMuFLFamily.bravura, pointSize: metrics.glyphFontSize),
                codepoint: UInt16(truncatingIfNeeded: AccidentalGlyph.codepoint(accidental)),
            )
            let extent = bounds.map { max(abs($0.minY), abs($0.maxY)) } ?? metrics.sp * 1.75
            // In steps of the full-size staff, half a staff space each.
            let steps = 2 * extent / (metrics.sp / mag)
            let step = trebleStep(of: note)
            return GraceObstacle(
                kind: .accidental, left: origin - reach, steps: step - steps ... step + steps, mag: mag,
            )
        }
    }

    private static func headPadding(against kind: GraceObstacle.Kind, scale: CGFloat) -> CGFloat {
        switch kind {
        case .note, .rest: graceToMainNoteDistSp
        case .grace: graceToGraceNoteDistSp
        case .accidental: graceAccidentalPaddingSp * scale
        case .barline: graceBarlinePaddingSp * scale
        case .clef: graceClefPaddingSp * scale
        }
    }

    private static func flagPadding(against kind: GraceObstacle.Kind, scale: CGFloat) -> CGFloat {
        switch kind {
        case .note, .grace, .accidental, .rest: graceFlagPaddingSp * scale
        case .barline: graceFlagBarlinePaddingSp * scale
        case .clef: graceFlagClefPaddingSp * scale
        }
    }
}
