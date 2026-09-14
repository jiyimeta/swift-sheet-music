import SheetMusicFoundation

/// Moves the WHOLE score by a number of semitones — MuseScore's Tools ▸ Transpose, as one undo step.
///
/// The difference from `TransposeRange` is not the size of the target but what the operation MEANS. A range
/// transpose is a pitch edit on the notes a host had selected; this is a change of key, so the key signatures move
/// with the notes (`transposeKeySignatures`) and what the piece claims to be in stays true of what it plays. Every
/// bar that declares a key is moved, not just the first — a modulation keeps its distance from the new home key.
/// Bar 1 is moved whether or not it writes a signature down, because C major is spelled by an ABSENT signature as
/// often as by an empty one, and a transposition that skipped it would move every note while leaving the score
/// claiming to be in C.
///
/// The keys are written FIRST and the notes are planned against the result, so `respellInKey` spells each note in
/// the key it is now in rather than the one the music just left: a C-major piece moved up two semitones reads in D
/// with F♯ and C♯ in the signature, not in C with an accidental on every one of them.
///
/// Notes move by the same arithmetic `TransposeRange` uses (`TranspositionPlanner`): tie chains move whole with
/// the accidental on the head alone, grace notes move with the chord that carries them, and percussion staves are
/// skipped — a drum has no pitch to move, and no key to be in.
///
/// ## What it refuses, and why not silently
///
/// Refused as `.invalidTransposition` past two octaves, the bound `TransposeRange` states. Refused as
/// `.transpositionOutOfRange` when ANY note in the score could not move and stay inside MIDI 0…127 — and this is
/// where the two commands deliberately differ. `TransposeRange` leaves such a note where it is, which is visible:
/// the user is looking at the handful of bars they selected. A whole-score move that left three notes behind would
/// change the music in a place nobody is looking, so it is refused entire and the host can say so.
///
/// ## What it does not move
///
/// Chord symbols. `SetChordSymbol` writes `Harmony.name` as the whole displayed text and nils `rootTpc` /
/// `bassTpc`, so a written symbol carries no transposable root (`docs/edit-commands.md` §C, "Chord-symbol
/// transposition"). A lead sheet transposed by this command keeps its old symbols and needs them retyped.
///
/// > Note: This command is sugar over `SetKeySignature` (× declaring bar) and `SetNotePitch` /
/// > `ReplaceVoiceElement` (× element) bundled in a `CompositeEditCommand`. It exists to give the operation a
/// > domain-meaningful name and to own the key arithmetic and the ordering between the two halves; callers can
/// > equally construct the equivalent Composite directly. See `docs/edit-commands.md`.
public struct TransposeScore: EditCommand {
    public let semitones: Int
    /// Whether every key signature moves with the notes. `false` keeps the score's key and spells the move in
    /// accidentals — MuseScore's "Transpose key signatures" unchecked.
    public let transposeKeySignatures: Bool
    /// Whether each moved note is re-spelled to the simplest reading in the key it lands in, rather than kept in
    /// the chromatic spelling repeated semitone steps produce.
    public let respellInKey: Bool

    public init(semitones: Int, transposeKeySignatures: Bool, respellInKey: Bool = true) {
        self.semitones = semitones
        self.transposeKeySignatures = transposeKeySignatures
        self.respellInKey = respellInKey
    }

    /// The head of the score. A command's affected location is a pure function of its inputs and this one takes no
    /// location at all, so it can only name the one slot every score has — the same answer `SetKeySignature` gives
    /// for the same reason. A host that wants its caret or its selection to survive a transposition restores them
    /// itself, and must do so by COLUMN rather than by address: writing a key signature into a bar that declared
    /// none inserts an element, which moves every element index after it in that bar.
    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let composite = try plan(in: score, ids: ids) else {
            return CompositeEditCommand(commands: [], location: affectedLocation)
        }
        return try composite.apply(to: &score, ids: &ids)
    }

    /// The composite this command would apply to `score`, or `nil` when it would change nothing — what the
    /// session's planner reads as "restating is nil". Validation happens here so a direct `apply` and a planned one
    /// refuse identically.
    func plan(in score: Score, ids: EIDAllocator) throws -> CompositeEditCommand? {
        guard (-24 ... 24).contains(semitones) else {
            throw Self.refused(.invalidTransposition(semitones: semitones))
        }
        guard semitones != 0 else { return nil }
        try ensureEveryNoteCanMove(Self.pitchedChords(in: score), in: score)

        // The keys are applied to a preview before the notes are planned, so every note's `activeKey` — the key
        // `respellInKey` spells it in, and the key the chromatic step rule reads its predicate from — is the one it
        // will actually be read under, not the one being replaced.
        var scratch = ids
        var preview = score
        var commands: [any EditCommand] = []
        for command in keyCommands(in: score) {
            _ = try command.apply(to: &preview, ids: &scratch)
            commands.append(command)
        }

        // Resolved against the PREVIEW, not the score this started from. Writing a key signature into a bar that
        // declared none INSERTS an element, so every element index after it in that bar has moved by one; a target
        // list taken before the write would address the wrong slots, and the planner's onset re-resolution would
        // quietly fold two of them onto the same chord (a grace-note ornament transposed twice, which is exactly
        // how this was caught).
        var visited: Set<NoteID> = []
        let targets = Self.pitchedChords(in: preview)
        let notes = try RangeEditPlanner.plan(targets: targets, in: preview, ids: scratch) { target, working in
            TranspositionPlanner.steps(
                at: target, in: working, semitones: semitones, respellInKey: respellInKey, visited: &visited,
            )
        }
        commands += notes?.commands ?? []
        guard !commands.isEmpty else { return nil }
        return CompositeEditCommand(commands: commands, location: affectedLocation)
    }

    /// One `SetKeySignature` per bar whose key moves — every bar that declares one, plus bar 0 whether it declares
    /// one or not. Empty when `transposeKeySignatures` is off, when the score has no pitched staff to declare a key
    /// on, and when the move leaves every key where it was (any whole number of octaves).
    private func keyCommands(in score: Score) -> [any EditCommand] {
        guard transposeKeySignatures, let reference = KeySignatureStaves.reference(in: score) else { return [] }
        var commands: [any EditCommand] = []
        for measureIndex in 0 ..< MeasureStructure.measureCount(of: score) {
            let declared = KeySignatureStaves.explicitKey(in: score, staff: reference, measureIndex: measureIndex)
            guard measureIndex == 0 || declared != nil else { continue }
            let current = declared?.concertKey ?? score.activeKey(staff: reference, measureIndex: measureIndex)
            let moved = TranspositionPlanner.key(current, transposedBy: semitones)
            guard moved != current else { continue }
            commands.append(SetKeySignature(measureIndex: measureIndex, concertKey: moved))
        }
        return commands
    }

    /// Refuses the whole move when any chord holds a note the shift would push outside MIDI 0…127. Decided against
    /// the untouched score, before anything is planned, so the first offender is named and nothing has been written
    /// when it fires.
    private func ensureEveryNoteCanMove(_ targets: [VoiceElementID], in score: Score) throws {
        for target in targets where !TranspositionPlanner.canMove(target, in: score, semitones: semitones) {
            throw Self.refused(.transpositionOutOfRange(at: target, semitones: semitones))
        }
    }

    /// Every chord and rest of every pitched staff, in document order — the whole-score reading of the target list
    /// `Score.voiceElements(in:)` resolves for a range. Percussion staves are left out here rather than skipped
    /// inside the step, so the pitch-range check above sees exactly the elements the plan will.
    private static func pitchedChords(in score: Score) -> [VoiceElementID] {
        var targets: [VoiceElementID] = []
        for (address, staff) in score.allStaves where RangeEditPlanner.isPitched(address, in: score) {
            for (measureIndex, measure) in staff.measures.enumerated() {
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    for (elementIndex, element) in voice.elements.enumerated() {
                        guard case .chord = element else { continue }
                        targets.append(VoiceElementID(
                            staff: address, measureIndex: measureIndex,
                            voiceIndex: voiceIndex, elementIndex: elementIndex,
                        ))
                    }
                }
            }
        }
        return targets
    }
}
