import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the parity project's note / chord intents (50…57). Its own file for the
/// reason `+MarkPlanning.swift` exists: `+Planning.swift` sits at its line budget.
///
/// **Minimal on purpose, for now.** Every arm here maps its intent straight onto the command, so the wire layer
/// (intents 50…57) has the dispatch the exhaustive switch in `+Planning.swift` demands. It does NOT yet apply the
/// standing restating rule — an intent that says what the score already says still plans to a command here, which
/// applies as a real (if no-op) undo entry rather than resolving to `.nothingToApply`. The next task replaces
/// these bodies with the `current…` comparisons the mark planners use; the shape and the file stay.
extension ScoreEditSession {
    static func notationCommand(for intent: EditIntent, in _: Score) -> (any EditCommand)? {
        switch intent {
        case let .setArticulation(location, kind, anchor, present):
            return SetArticulation(at: location, kind: kind, anchor: anchor, present: present)
        case let .setGraceNotes(location, before, after):
            return SetGraceNotes(at: location, before: before, after: after)
        case let .setTremolo(location, tremolo):
            return SetTremolo(at: location, tremolo: tremolo)
        case let .setArpeggio(location, subtype):
            // The intent carries the subtype only (spec row 53); the command carries the whole `Arpeggio`, whose
            // other fields are the wire's to leave at their defaults.
            return SetArpeggio(at: location, arpeggio: subtype.map { Arpeggio(subtype: $0) })
        case let .setGlissando(location, glissando):
            return SetGlissando(at: location, glissando: glissando)
        case let .setDots(location, dots):
            return SetDots(at: location, dots: dots)
        case let .setChordLine(location, kind, isStraight):
            return SetChordLine(at: location, kind: kind, isStraight: isStraight)
        case let .setNoteParentheses(location, parentheses):
            return SetNoteParentheses(at: location, parentheses: parentheses)
        default:
            // Reached only through `command(for:in:depth:)`'s grouped case, which already narrows the intent;
            // the `default` exists because that narrowing is a `case` list, not a type.
            return nil
        }
    }
}
