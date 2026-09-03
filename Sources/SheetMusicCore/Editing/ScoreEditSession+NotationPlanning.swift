import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the parity project's note / chord intents (50…57). Its own file for the
/// reason `+MarkPlanning.swift` exists: `+Planning.swift` sits at its line budget.
///
/// Every planner here follows the standing rule: an intent that restates what the score already says plans to
/// `nil` (`.nothingToApply`), never to a self-restoring undo entry. Each reads the score through the command's own
/// `current…` accessor, so "already says" is decided by the same lookup the command's `apply` performs.
///
/// Kind and range refusals stay in the commands' `apply`, so a command built directly answers the same way — a
/// planner that returned `nil` for a missing target would turn a refusal into a silent success. That is why every
/// arm below guards on the target EXISTING before it compares, and returns the command when it does not.
///
/// `setArpeggio` is the one comparison that is deliberately narrower than the command's payload: it compares the
/// **subtype alone**, because that is all the wire carries (spec row 53). Re-sending the subtype a stretched
/// arpeggio already has must plan to nothing rather than silently resetting its `timeStretch` to the default.
/// The same argument does not apply to `setChordLine`, whose comparison IS the whole value the wire can express.
extension ScoreEditSession {
    static func notationCommand(for intent: EditIntent, in score: Score) -> (any EditCommand)? {
        switch intent {
        case let .setArticulation(location, kind, anchor, present):
            let command = SetArticulation(at: location, kind: kind, anchor: anchor, present: present)
            guard let current = SetArticulation.current(at: location, kind: kind, in: score) else { return command }
            let wanted = present ? [ChordArticulation(kind: kind, anchor: anchor)] : []
            return current == wanted ? nil : command
        case let .setGraceNotes(location, before, after):
            let command = SetGraceNotes(at: location, before: before, after: after)
            guard let current = SetGraceNotes.current(at: location, in: score) else { return command }
            return current.before == before && current.after == after ? nil : command
        case let .setTremolo(location, tremolo):
            let command = SetTremolo(at: location, tremolo: tremolo)
            guard isChord(at: location, in: score) else { return command }
            return SetTremolo.current(at: location, in: score) == tremolo ? nil : command
        case let .setArpeggio(location, subtype):
            let command = SetArpeggio(at: location, arpeggio: subtype.map { Arpeggio(subtype: $0) })
            guard isChord(at: location, in: score) else { return command }
            return SetArpeggio.current(at: location, in: score)?.subtype == subtype ? nil : command
        case let .setGlissando(location, glissando):
            let command = SetGlissando(at: location, glissando: glissando)
            guard let note = score[location] else { return command }
            return note.glissando == glissando ? nil : command
        case let .setDots(location, dots):
            let command = SetDots(at: location, dots: dots)
            guard let current = SetDots.current(at: location, in: score) else { return command }
            return current == dots ? nil : command
        case let .setChordLine(location, kind, isStraight):
            let command = SetChordLine(at: location, kind: kind, isStraight: isStraight)
            guard let current = SetChordLine.current(at: location, in: score) else { return command }
            let wanted = kind.map { [ChordLine(kind: $0, isStraight: isStraight)] } ?? []
            return current == wanted ? nil : command
        case let .setNoteParentheses(location, parentheses):
            let command = SetNoteParentheses(at: location, parentheses: parentheses)
            guard let note = score[location] else { return command }
            return note.parentheses == parentheses ? nil : command
        default:
            // Reached only through `command(for:in:depth:)`'s grouped case, which already narrows the intent;
            // the `default` exists because that narrowing is a `case` list, not a type.
            return nil
        }
    }

    /// Whether `location` names a sounding chord — the guard the two commands whose `current…` reader returns a
    /// plain `Optional` need, so "there is no tremolo here" and "there is no chord here" stay distinguishable.
    private static func isChord(at location: VoiceElementID, in score: Score) -> Bool {
        guard case let .chord(chord)? = score[location] else { return false }
        return !chord.notes.isEmpty
    }
}
