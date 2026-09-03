import SheetMusicFoundation

/// Write (or clear) a chord's arpeggio — the wiggly line that spreads its notes in time.
///
/// `nil` clears. A write needs a chord of at least two notes (`.chordTooSmall`): an arpeggio distributes the notes
/// it is given, and one note is nothing to distribute — MuseScore's palette refuses the same case. A CLEAR skips
/// that check, so a chord that lost a note while carrying an arpeggio stays editable.
///
/// The subtype is not range-checked here. `Arpeggio.subtype` is a plain `Int` because it round-trips whatever
/// MuseScore wrote, including a value from a later version's table; the `0…5` bound (`TConv`'s `ARPEGGIO_TYPES`,
/// `types/typesconv.cpp`) is enforced on the WIRE, where a relayed payload is untrusted input, not in a command a
/// caller built from a value it already holds.
///
/// The inverse this returns can itself be refused — `.chordTooSmall`, if a later edit dropped the chord to one
/// note before undo runs. `ScoreEditor.undo()` pops its stack LIFO, so whatever removed the note was applied
/// after this command and is undone first, restoring the note count before this inverse ever resolves; nothing
/// in this command re-checks that at undo time.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. See `docs/edit-commands.md`.
public struct SetArpeggio: EditCommand {
    public let location: VoiceElementID
    public let arpeggio: Arpeggio?

    public init(at location: VoiceElementID, arpeggio: Arpeggio?) {
        self.location = location
        self.arpeggio = arpeggio
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    /// The chord's arpeggio, or `nil` both when there is none and when `location` names no chord — the same
    /// two-in-one answer `SetTremolo.current` gives, for the same planner reason.
    static func current(at location: VoiceElementID, in score: Score) -> Arpeggio? {
        guard case let .chord(chord)? = score[location], !chord.notes.isEmpty else { return nil }
        return chord.arpeggio
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case var .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        if arpeggio != nil, chord.notes.count < 2 {
            throw Self.refused(.chordTooSmall(at: location, noteCount: chord.notes.count))
        }
        let inverse = SetArpeggio(at: location, arpeggio: chord.arpeggio)
        chord.arpeggio = arpeggio
        score[location] = .chord(chord)
        return inverse
    }
}
