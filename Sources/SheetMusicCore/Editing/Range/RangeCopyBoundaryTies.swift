import SheetMusicFoundation

/// Sealing the ties a copy leaves dangling across a destination BARLINE.
///
/// `RangeCopyVoiceRebuild.cut` already clears the tie of a neighbour standing inside the rebuilt measure. It
/// cannot reach the commonest case of all: repeating a whole bar makes the destination span `[0, barLength)`,
/// so there is no neighbour inside that measure at either end — the partner that now points at material the
/// copy overwrote is in the bar BEFORE or the bar AFTER. MuseScore does not treat a barline as a boundary of
/// its own here: removing a chord clears both ends of every tie it carried (`editing/addremoveelement.cpp:
/// 203-224` with `note.cpp:1348-1356`), so the surviving partner is left untied wherever it sits.
///
/// The copy's own material is out of reach twice over, and deliberately so. Only the OUTERMOST edges are
/// sealed — a copy covering several bars also ends one piece on a barline and starts the next on one, but both
/// sides of that seam are its own material, and a chord it split across the barline is a tied chain that
/// sealing would cut in half. And the whole pass reads the score as it stands BEFORE any piece lands, so even
/// a bug in the first rule could only clear a tie the destination already had, on an element the copy is about
/// to replace.
extension RangeCopyVoiceRebuild {
    /// The replacements that untie the copy's outer neighbours, at most one per edge.
    ///
    /// Read against the score as it stands BEFORE the pieces land, so the gap each edge is measured against is
    /// the one the rebuild will actually clear — `clearedGap(forSpan:_:of:in:)` widens the piece's span over a
    /// destination tuplet the copy only partly covers, and the element sitting at tick 0 of a bar can be a
    /// member of such a tuplet rather than the piece's own first element. The commands touch measures no piece
    /// rewrites, so they may be applied in any order relative to the rebuilds.
    static func barlineTieSeals(
        for pieces: [RangeCopyPlacement.Piece], staff: StaffAddress, voiceIndex: Int, in score: Score,
    ) -> [ReplaceVoiceElement] {
        guard let first = pieces.first, let last = pieces.last else { return [] }
        let durations = score.effectiveMeasureDurations(
            partIndex: staff.partIndex, staffIndex: staff.staffIndexInPart,
        )
        var commands: [ReplaceVoiceElement] = []
        if let gap = gap(of: first, staff: staff, voiceIndex: voiceIndex, durations: durations, in: score),
           gap.lowerBound == 0, first.measureIndex > 0,
           let command = untied(
               .forward, inMeasure: first.measureIndex - 1, staff: staff, voiceIndex: voiceIndex, in: score,
           )
        {
            commands.append(command)
        }
        if let gap = gap(of: last, staff: staff, voiceIndex: voiceIndex, durations: durations, in: score),
           durations.indices.contains(last.measureIndex),
           gap.upperBound == durations[last.measureIndex].ticks(division: score.division),
           let command = untied(
               .back, inMeasure: last.measureIndex + 1, staff: staff, voiceIndex: voiceIndex, in: score,
           )
        {
            commands.append(command)
        }
        return commands
    }

    /// Which side of the seam the surviving neighbour is on, and so which of its ties points into the copy.
    private enum Seam {
        /// The bar in front of the copy: its LAST timed element's `tieForward` crosses into the gap.
        case forward
        /// The bar behind the copy: its FIRST timed element's `tieBack` crosses into the gap.
        case back
    }

    /// The tick span `piece` will actually clear in its own measure, widened over any destination tuplet it
    /// covers only partly. `nil` for a measure or voice the staff does not have.
    private static func gap(
        of piece: RangeCopyPlacement.Piece, staff: StaffAddress, voiceIndex: Int, durations: [Fraction],
        in score: Score,
    ) -> Range<Int>? {
        let ref = VoiceRef(staff: staff, measureIndex: piece.measureIndex, voiceIndex: voiceIndex)
        guard let voice = score[voice: ref], durations.indices.contains(piece.measureIndex) else { return nil }
        let context = Context(
            division: score.division, measureDuration: durations[piece.measureIndex], ref: ref,
            geometry: RangeCopyGeometry(staff: staff, in: score),
        )
        let spanStart = piece.startTickInMeasure
        let spanEnd = spanStart + piece.elements.reduce(0) { $0 + context.advance(of: $1) }
        return clearedGap(forSpan: spanStart, spanEnd, of: voice, in: context)
    }

    /// The replacement that clears one side's tie on the boundary chord of `measureIndex`, or `nil` when that
    /// measure, that voice or that chord does not exist — or when the chord carries no such tie, so that a
    /// duplicate never plans a command that changes nothing.
    private static func untied(
        _ seam: Seam, inMeasure measureIndex: Int, staff: StaffAddress, voiceIndex: Int, in score: Score,
    ) -> ReplaceVoiceElement? {
        let ref = VoiceRef(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
        guard let elements = score[voice: ref]?.elements else { return nil }
        let timed = elements.indices.filter { index in
            if case .chord = elements[index] { true } else { false }
        }
        guard let index = seam == .forward ? timed.last : timed.first,
              case let .chord(chord) = elements[index]
        else { return nil }
        let tied = chord.notes.contains { note in
            seam == .forward ? note.tieForward != nil : note.tieBack != nil
        }
        guard tied else { return nil }
        let changed = seam == .forward
            ? settingTie(elements[index], forward: .clear)
            : settingTie(elements[index], back: .clear)
        return AdjacentElementSlot.replacing(changed, at: index, in: ref)
    }
}
