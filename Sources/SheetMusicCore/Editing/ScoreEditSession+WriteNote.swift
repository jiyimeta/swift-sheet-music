import SheetMusicFoundation

/// `.writeNote`'s planner, out of `ScoreEditSession+Planning.swift` for SwiftLint's 400-line budget once the write
/// learned to untie the note it overwrites.
extension ScoreEditSession {
    /// `.writeNote`: re-pitch the chord already in `location`, and re-time it to `duration` in the same undo step.
    ///
    /// Three shapes, in the order they are ruled out:
    ///
    /// 1. Nothing to re-time — no length asked for, the slot is already that length, or the slot is inside a tuplet,
    ///    where the member lengths are the tuplet's to decide and the engine refuses the change outright. A composite
    ///    is all-or-nothing, so that refusal would take the pitch write down with it; write the pitch alone.
    /// 2. The length outruns the bar — spell the note as a beat-aligned tied chain. The chain is planned from a FRESH
    ///    chord carrying the new pitch, not from the one in the slot: `CrossBarInputPlanner.piece` clones what it is
    ///    handed into every link, and that is precisely what a `.setChordDuration` + `.setNotePitch` pair cannot
    ///    reproduce — it would retune the head and leave the tail tied to it at the old pitch.
    /// 3. Otherwise — re-time and re-pitch as one composite.
    ///
    /// Throws when the slot holds a rest rather than a chord. That is `.inputNote`'s case, and re-routing quietly
    /// would make a relayed intent do something its name does not say.
    ///
    /// **Writing a note over a tied note unties it first**, at both ends, whatever the new pitch — the written note is
    /// a new note, as it is in MuseScore, which replaces the chord a pitch is typed over and removes its ties with it.
    /// A bare `SetNotePitch` keeps `tieForward` / `tieBack`, and `DanglingTies` cannot catch what is left: `TiePlanner`
    /// pairs ties by rank, not by pitch, so the overwritten note stays "tied" to a neighbour at another pitch. The
    /// neighbour then never sounds (`MidiRenderer` suppresses the note-on of a `tieBack`), and the next `.setNotePitch`
    /// on either note walks the leftover chain and drags the other one with it. The untie comes first so its
    /// `SetTie`s address the score as planned — the re-time after it can shift the element that follows.
    static func writeNoteCommand(
        at location: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?, in score: Score,
    ) throws -> any EditCommand {
        guard case let .chord(current)? = score[location], !current.notes.isEmpty else {
            throw SheetMusicError.invalidEdit(EditRefusal(
                operation: "writeNote",
                reason: .wrongElementKind(at: location, expected: .chord),
            ))
        }
        let head = NoteID(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elementIndex: location.elementIndex,
            noteIndexInChord: 0,
        )
        let untie = untieCommands(for: head, in: score)
        let repitch = SetNotePitch(at: head, pitch: pitch, tpc: tpc)
        guard let duration, current.duration != duration, !isInTuplet(location, in: score) else {
            return untie.isEmpty ? repitch : CompositeEditCommand(commands: untie + [repitch], location: location)
        }
        if let plan = CrossBarInputPlanner.plan(
            .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)])),
            duration: duration, at: location, in: score,
        ) {
            return CompositeEditCommand(commands: untie + plan.commands, location: plan.head)
        }
        return CompositeEditCommand(
            commands: untie + [SetChordDuration(at: location, duration: duration), repitch],
            location: location,
        )
    }

    /// The `SetTie`s that take `note`'s ties off at both ends — empty when it carries none, which keeps the untied
    /// write the bare command it always was.
    private static func untieCommands(for note: NoteID, in score: Score) -> [any EditCommand] {
        var commands: [any EditCommand] = []
        if let previous = TiePlanner.tiedNote(before: note, in: score) {
            commands.append(SetTie(from: previous, to: note, sourceTieForward: nil, targetTieBack: nil))
        }
        if let next = TiePlanner.tiedNote(after: note, in: score) {
            commands.append(SetTie(from: note, to: next, sourceTieForward: nil, targetTieBack: nil))
        }
        return commands
    }
}
