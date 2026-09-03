import SheetMusicFoundation

/// Write (or clear) the jazz / brass inflection line on a chord — a fall, doit, plop or scoop, curved or straight.
///
/// ONE line per chord in v1. `Chord.chordLines` is an array and a real score can hold a scoop into the note plus a
/// fall out of it (`ChordLine.swift`), but the palette gesture this command models drops a single line, and the
/// wire payload carries a single `kind` + `isStraight` pair (spec row 56). So a write over a chord that carried two
/// lines REPLACES both, and `kind: nil` clears the chord's lines outright.
///
/// That is why the inverse is the pre-image — a `ReplaceVoiceElement`, not another `SetChordLine`: a chord holding
/// two lines has no single `SetChordLine` that restores it. Same reasoning as `SetArticulation`'s.
///
/// `ChordLine`'s other fields keep their `init` defaults: `isWavy`, `plays`, `lengthX` / `lengthY`, `path` and
/// `noteIndex` are what a palette drop produces. `isWavy` in particular is NOT reachable through this command in
/// v1 — a caller wanting the rough-slide variant builds the `ChordLine` and writes it with `ReplaceVoiceElement`.
/// The gap is deliberate rather than forgotten.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. See `docs/edit-commands.md`.
public struct SetChordLine: EditCommand {
    public let location: VoiceElementID
    public let kind: ChordLine.Kind?
    public let isStraight: Bool

    public init(at location: VoiceElementID, kind: ChordLine.Kind?, isStraight: Bool) {
        self.location = location
        self.kind = kind
        self.isStraight = isStraight
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    /// The chord's lines, or `nil` when `location` names no chord — what the planner compares against so a
    /// restating write plans to nothing.
    static func current(at location: VoiceElementID, in score: Score) -> [ChordLine]? {
        guard case let .chord(chord)? = score[location], !chord.notes.isEmpty else { return nil }
        return chord.chordLines
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case var .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        // The pre-image is the inverse's whole payload: a chord that carried two lines, or one carrying fields this
        // command does not name, has no single `SetChordLine` that restores it.
        let inverse = ReplaceVoiceElement(at: location, with: element)
        chord.chordLines = kind.map { [ChordLine(kind: $0, isStraight: isStraight)] } ?? []
        score[location] = .chord(chord)
        return inverse
    }
}

/// Write the round parentheses drawn around one notehead — MuseScore's editorial / cautionary / "ghost" note.
///
/// `.none` is the clear. The value is not an `Optional`: `NoteParentheses` already has a "no parentheses" case, so
/// an `Optional` would give the same state two spellings and the wire two encodings of it.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`, the same shape `SetNoteHead` has. See
/// > `docs/edit-commands.md`.
public struct SetNoteParentheses: EditCommand {
    public let location: NoteID
    public let parentheses: NoteParentheses

    public init(at location: NoteID, parentheses: NoteParentheses) {
        self.location = location
        self.parentheses = parentheses
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(location)
    }

    /// The note's parentheses, or `nil` when `location` names no note — what a planner reads to decide whether an
    /// intent restates the score.
    static func current(at location: NoteID, in score: Score) -> NoteParentheses? {
        score[location]?.parentheses
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let oldNote = score[location] else {
            throw Self.refused(.noteNotFound(location))
        }
        let elementID = VoiceElementID(location)
        guard case var .chord(chord) = score[elementID] else {
            throw Self.refused(.wrongElementKind(at: elementID, expected: .chord))
        }
        chord.notes[location.noteIndexInChord].parentheses = parentheses
        score[elementID] = .chord(chord)
        return SetNoteParentheses(at: location, parentheses: oldNote.parentheses)
    }
}
