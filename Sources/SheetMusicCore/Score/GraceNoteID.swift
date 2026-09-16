import SheetMusicFoundation

/// Path-based identity of one note inside a grace chord — what a click on a grace notehead names.
///
/// A grace chord is not a voice element (`GraceChord` explains why), so no `NoteID` can reach one: the path runs
/// through the chord that owns it. `parent` is that chord's voice slot, `side` picks `Chord.graceNotesBefore` or
/// `Chord.graceNotesAfter`, `graceIndex` indexes that list, and `noteIndexInGraceChord` indexes the grace chord's own
/// `notes`.
///
/// Both lists are stored in reading order, which is also the order MuseScore's navigation walks them:
/// `graceNotesBefore[0]` is the leftmost grace, `graceNotesAfter[0]` the one nearest its parent (see
/// `LayoutEngine+Placement` and `Chord.mscxFileOrderedGraces`).
///
/// Like `NoteID` this names a position: an edit that inserts or removes a grace, or moves the parent chord, shifts
/// it. To follow a grace note across an edit, resolve `eid(at:)` before it and `graceNotePosition(of:)` after it.
public struct GraceNoteID: Hashable, Sendable {
    /// Which of the parent chord's two grace lists the grace chord lives in.
    public enum Side: Hashable, Sendable {
        /// `Chord.graceNotesBefore` — acciaccatura, appoggiatura and the other pre-beat types.
        case before
        /// `Chord.graceNotesAfter` — the `grace…after` types.
        case after
    }

    /// The chord slot whose grace list holds this note.
    public let parent: VoiceElementID
    public let side: Side
    /// Index into the parent's grace list on `side`.
    public let graceIndex: Int
    /// Index into that grace chord's `notes`.
    public let noteIndexInGraceChord: Int

    public init(parent: VoiceElementID, side: Side, graceIndex: Int, noteIndexInGraceChord: Int) {
        self.parent = parent
        self.side = side
        self.graceIndex = graceIndex
        self.noteIndexInGraceChord = noteIndexInGraceChord
    }

    /// The parent chord's staff. A grace note is engraved on its parent's staff, so every positional question
    /// about it answers from the parent.
    public var staff: StaffAddress {
        parent.staff
    }

    public var measureIndex: Int {
        parent.measureIndex
    }

    public var voiceIndex: Int {
        parent.voiceIndex
    }

    public var elementIndex: Int {
        parent.elementIndex
    }

    /// This identity moved onto another parent slot, keeping side and indices.
    public func withParent(_ parent: VoiceElementID) -> GraceNoteID {
        GraceNoteID(parent: parent, side: side, graceIndex: graceIndex, noteIndexInGraceChord: noteIndexInGraceChord)
    }
}

extension Chord {
    /// The grace list on `side`.
    public func graceNotes(on side: GraceNoteID.Side) -> IdentifiedArray<GraceChord> {
        switch side {
        case .before: graceNotesBefore
        case .after: graceNotesAfter
        }
    }
}

extension Score {
    /// The grace chord `id` points into, or `nil` when the parent is not a chord with notes or the grace index is
    /// out of range. A rest owns no graces here, as in MuseScore, whatever its model lists happen to hold.
    public func graceChord(at id: GraceNoteID) -> GraceChord? {
        guard case let .chord(parent)? = self[id.parent], !parent.notes.isEmpty else { return nil }
        let graces = parent.graceNotes(on: id.side)
        guard graces.indices.contains(id.graceIndex) else { return nil }
        return graces[id.graceIndex]
    }

    /// The grace note `id` names, or `nil` for a stale or out-of-range identity.
    public subscript(graceNoteID: GraceNoteID) -> Note? {
        guard let grace = graceChord(at: graceNoteID),
              grace.notes.indices.contains(graceNoteID.noteIndexInGraceChord)
        else { return nil }
        return grace.notes[graceNoteID.noteIndexInGraceChord]
    }

    /// The grace note's durable identifier, or `nil` if the position is out of range or still unassigned.
    public func eid(at position: GraceNoteID) -> EID? {
        guard let grace = graceChord(at: position),
              grace.notes.indices.contains(position.noteIndexInGraceChord)
        else { return nil }
        let eid = grace.notes.eid(at: position.noteIndexInGraceChord)
        return eid.isValid ? eid : nil
    }

    /// Where the grace note carrying `eid` sits now — the counterpart `notePosition(of:)` deliberately leaves out.
    /// First match in part, staff, measure, voice, element, side (before, then after), grace and note order; `nil`
    /// for an invalid identifier or one that names no grace note.
    public func graceNotePosition(of eid: EID) -> GraceNoteID? {
        guard eid.isValid else { return nil }
        for (partIndex, part) in parts.enumerated() {
            for (staffIndex, staff) in part.staves.enumerated() {
                for (measureIndex, measure) in staff.measures.enumerated() {
                    for (voiceIndex, voice) in measure.voices.enumerated() {
                        for (elementIndex, element) in voice.elements.enumerated() {
                            guard case let .chord(chord) = element, !chord.notes.isEmpty else { continue }
                            let parent = VoiceElementID(
                                staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex),
                                measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: elementIndex,
                            )
                            if let found = Self.grace(eid, in: chord, parent: parent) { return found }
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func grace(_ eid: EID, in chord: Chord, parent: VoiceElementID) -> GraceNoteID? {
        for side in [GraceNoteID.Side.before, .after] {
            for (graceIndex, grace) in chord.graceNotes(on: side).enumerated() {
                guard let noteIndex = grace.notes.index(of: eid) else { continue }
                return GraceNoteID(
                    parent: parent, side: side, graceIndex: graceIndex, noteIndexInGraceChord: noteIndex,
                )
            }
        }
        return nil
    }
}
