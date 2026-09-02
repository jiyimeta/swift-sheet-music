import SheetMusicFoundation

/// Moves every note in a range by a number of semitones — MuseScore's ↑ / ↓ and Transpose dialog over a range
/// selection, as one undo step.
///
/// Each note is spelled by the chromatic rule `Note.shifted(bySemitones:in:)` applies one semitone at a time under
/// the key in force at its chain's head; with `respellInKey` the result is re-spelled to the simplest reading in
/// that key (`PitchSpelling.tpc(forPitch:keySig:mode:)`) instead. A tie chain is one sounding note written across
/// several slots, so the whole chain moves when ANY member is in range, and the accidental is written on the head
/// alone — the far side of a tie carries none. A note the shift cannot keep inside MIDI 0…127 stays as it is, chain
/// and all. Percussion staves are skipped: a drum has no pitch to move.
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
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let composite = try plan(in: score) else {
            return CompositeEditCommand(commands: [], location: range.start)
        }
        return try composite.apply(to: &score)
    }

    /// The composite this command would apply to `score`, or `nil` when it would change nothing — what the
    /// session's planner reads as "restating is nil". Validation happens here so a direct `apply` and a planned one
    /// refuse identically.
    func plan(in score: Score) throws -> CompositeEditCommand? {
        guard (-24 ... 24).contains(semitones) else {
            throw Self.refused(.invalidTransposition(semitones: semitones))
        }
        guard !score.voiceElements(in: range).isEmpty else { throw Self.refused(.targetNotFound(range.start)) }
        guard semitones != 0 else { return nil }
        var visited: Set<NoteID> = []
        return try RangeEditPlanner.plan(over: range, in: score) { target, working in
            guard RangeEditPlanner.isPitched(target.staff, in: working) else { return [] }
            return RangeEditPlanner.unvisitedTieChains(of: target, in: working, visited: &visited)
                .flatMap { retune(chain: $0, in: working) }
        }?.composite
    }

    /// `SetNotePitch` for every member of one chain, all carrying the head's shifted pitch and tpc; `[]` when the
    /// shift would leave MIDI range.
    private func retune(chain: [NoteID], in score: Score) -> [any EditCommand] {
        guard let head = chain.first, let note = score[head] else { return [] }
        let keySig = score.activeKey(at: head)
        guard var shifted = note.shifted(bySemitones: semitones, in: keySig) else { return [] }
        if respellInKey {
            shifted.tpc = PitchSpelling.tpc(forPitch: shifted.pitch, keySig: keySig, mode: .simplest)
            shifted.accidental = PitchSpelling.displayedAccidental(forTpc: shifted.tpc, in: keySig)
        }
        return chain.map { member in
            SetNotePitch(
                at: member, pitch: shifted.pitch, tpc: shifted.tpc,
                accidental: member == head ? shifted.accidental : nil,
            )
        }
    }
}
