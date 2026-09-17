import SheetMusicFoundation

/// The walk a plain ← / → makes in MuseScore: chords and rests of one voice, stopping on every grace note.
///
/// C++: `Navigation::nextChordRest` / `prevChordRest` (`engraving/editing/navigation.cpp`) with `skipGrace = false`.
/// Within a voice the order is
///
///     … chord → its graceNotesAfter[0 …] → next chord's graceNotesBefore[0 …] → next chord → …
///
/// and the reverse walks it backwards. MuseScore's shifted arrows (range extension) pass `skipGrace = true`; that
/// walk is `nextTimedElement(after:in:)` / `previousTimedElement(before:in:)`, so it is not repeated here.
///
/// Items are named the way the rest of the selection vocabulary names them. A chord with notes is
/// `.note` at `noteIndexInChord` 0 and a grace chord `.graceNote` at `noteIndexInGraceChord` 0 — note 0 is the
/// representative every host-facing re-derivation already lands on when it picks a chord rather than a note
/// (`LayoutDocument.editingCaretRect`'s tuplet anchor, Folino's `SelectionRederivation`). MuseScore selects the
/// chord's `upNote()` instead; which note a step lands on is a selection convention, not part of the walk.
/// A rest is `.rest`, and owns no graces (MuseScore attaches graces to chords only). A grace chord with no notes
/// has nothing to name and is stepped over.
extension ElementNavigator {
    /// The next chord, rest or grace note after `item` in its voice, crossing barlines the way
    /// `nextTimedElement(after:in:)` does. `nil` at the end of the staff, for an identity that no longer resolves
    /// (a stale grace index, say — MuseScore's "unable to find self"), and for items that are not a note, a rest or
    /// a grace note.
    public static func nextChordRest(after item: ScoreItemID, in score: Score) -> ScoreItemID? {
        let current: VoiceElementID
        switch item {
        case let .note(id):
            current = VoiceElementID(id)
            guard case let .chord(chord)? = score[current], !chord.notes.isEmpty else { return nil }
            if let grace = firstGrace(of: chord, on: .after, parent: current) { return grace }
        case let .rest(id):
            current = VoiceElementID(id)
        case let .graceNote(id):
            guard let chord = parentChord(of: id, in: score) else { return nil }
            let graces = chord.graceNotes(on: id.side)
            if let next = grace(of: chord, on: id.side, parent: id.parent, in: (id.graceIndex + 1) ..< graces.count) {
                return next
            }
            // The last before-grace leads into its own chord; the last after-grace falls through to the next slot.
            guard id.side == .after else { return representative(at: id.parent, in: score) }
            current = id.parent
        default:
            return nil
        }
        guard let next = nextTimedElement(after: current, in: score) else { return nil }
        if case let .chord(chord)? = score[next], !chord.notes.isEmpty,
           let grace = firstGrace(of: chord, on: .before, parent: next)
        {
            return grace
        }
        return representative(at: next, in: score)
    }

    /// The mirror of `nextChordRest(after:in:)`: the previous chord, rest or grace note before `item`, crossing
    /// barlines backwards. `nil` at the start of the staff, for a stale identity, and for other item kinds.
    public static func previousChordRest(before item: ScoreItemID, in score: Score) -> ScoreItemID? {
        let current: VoiceElementID
        switch item {
        case let .note(id):
            current = VoiceElementID(id)
            guard case let .chord(chord)? = score[current], !chord.notes.isEmpty else { return nil }
            if let grace = lastGrace(of: chord, on: .before, parent: current) { return grace }
        case let .rest(id):
            current = VoiceElementID(id)
        case let .graceNote(id):
            guard let chord = parentChord(of: id, in: score) else { return nil }
            if let previous = grace(of: chord, on: id.side, parent: id.parent, in: (0 ..< id.graceIndex).reversed()) {
                return previous
            }
            // The first after-grace leads back into its own chord; the first before-grace falls through.
            guard id.side == .before else { return representative(at: id.parent, in: score) }
            current = id.parent
        default:
            return nil
        }
        guard let previous = previousTimedElement(before: current, in: score) else { return nil }
        if case let .chord(chord)? = score[previous], !chord.notes.isEmpty,
           let grace = lastGrace(of: chord, on: .after, parent: previous)
        {
            return grace
        }
        return representative(at: previous, in: score)
    }

    // MARK: - Helpers

    /// The chord owning `id`, when `id` still names a grace chord in it — the grace index is in range.
    private static func parentChord(of id: GraceNoteID, in score: Score) -> Chord? {
        guard score.graceChord(at: id) != nil, case let .chord(chord)? = score[id.parent] else { return nil }
        return chord
    }

    /// `.note` at note 0 for a chord with notes, `.rest` for an empty chord, `nil` for anything else.
    private static func representative(at location: VoiceElementID, in score: Score) -> ScoreItemID? {
        guard case let .chord(chord)? = score[location] else { return nil }
        if chord.notes.isEmpty { return .rest(RestID(location)) }
        return .note(NoteID(location, noteIndexInChord: 0))
    }

    private static func firstGrace(
        of chord: Chord, on side: GraceNoteID.Side, parent: VoiceElementID,
    ) -> ScoreItemID? {
        grace(of: chord, on: side, parent: parent, in: chord.graceNotes(on: side).indices)
    }

    private static func lastGrace(
        of chord: Chord, on side: GraceNoteID.Side, parent: VoiceElementID,
    ) -> ScoreItemID? {
        grace(of: chord, on: side, parent: parent, in: chord.graceNotes(on: side).indices.reversed())
    }

    /// The first grace chord with notes among `indices`, in the order given, as its note-0 item.
    private static func grace(
        of chord: Chord, on side: GraceNoteID.Side, parent: VoiceElementID, in indices: some Sequence<Int>,
    ) -> ScoreItemID? {
        let graces = chord.graceNotes(on: side)
        for index in indices where graces.indices.contains(index) && !graces[index].notes.isEmpty {
            return .graceNote(GraceNoteID(parent: parent, side: side, graceIndex: index, noteIndexInGraceChord: 0))
        }
        return nil
    }
}

extension RestID {
    fileprivate init(_ location: VoiceElementID) {
        self.init(
            staff: location.staff, measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex, elementIndex: location.elementIndex,
        )
    }
}

extension NoteID {
    fileprivate init(_ location: VoiceElementID, noteIndexInChord: Int) {
        self.init(
            staff: location.staff, measureIndex: location.measureIndex, voiceIndex: location.voiceIndex,
            elementIndex: location.elementIndex, noteIndexInChord: noteIndexInChord,
        )
    }
}
