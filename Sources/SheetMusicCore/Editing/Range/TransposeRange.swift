import SheetMusicFoundation

/// Moves every note in a range by a number of semitones — MuseScore's ↑ / ↓ and Transpose dialog over a range
/// selection, as one undo step.
///
/// Each note is spelled by the chromatic rule `Note.shifted(bySemitones:in:)` applies one semitone at a time under
/// the key in force at its chain's head; with `respellInKey` the result is re-spelled to the simplest reading in
/// that key (`PitchSpelling.tpc(forPitch:keySig:mode:)`) instead. A tie chain is one sounding note written across
/// several slots, so the whole chain moves when ANY member is in range, and the accidental is written on the head
/// alone — the far side of a tie carries none. A chord's grace notes move with it (`TranspositionPlanner`'s
/// whole-element replace; they are the one pitched thing a `NoteID` cannot address). A note the shift cannot keep
/// inside MIDI 0…127 stays as it is, chain and all. Percussion staves are skipped: a drum has no pitch to move.
///
/// Refused as `.invalidTransposition` past two octaves and as `.targetNotFound` when the range resolves to nothing.
///
/// > Note: This command is sugar over `SetNotePitch` (× note) bundled in a `CompositeEditCommand` by
/// > `RangeEditPlanner`. It exists to give the operation a domain-meaningful name and to own the tie-chain and
/// > spelling rules; callers can equally construct the equivalent Composite directly. See `docs/edit-commands.md`.
public struct TransposeRange: EditCommand {
    public let range: VoiceElementRange
    public let semitones: Int
    public let respellInKey: Bool

    public init(over range: VoiceElementRange, semitones: Int, respellInKey: Bool) {
        self.range = range
        self.semitones = semitones
        self.respellInKey = respellInKey
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let composite = try plan(in: score, ids: ids) else {
            return CompositeEditCommand(commands: [], location: range.start)
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
        guard !score.voiceElements(in: range).isEmpty else { throw Self.refused(.targetNotFound(range.start)) }
        guard semitones != 0 else { return nil }
        var visited: Set<NoteID> = []
        return try RangeEditPlanner.plan(over: range, in: score, ids: ids) { target, working in
            guard RangeEditPlanner.isPitched(target.staff, in: working) else { return [] }
            return TranspositionPlanner.steps(
                at: target, in: working, semitones: semitones, respellInKey: respellInKey, visited: &visited,
            )
        }?.composite
    }
}
