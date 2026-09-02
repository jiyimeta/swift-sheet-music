import SheetMusicFoundation

/// Re-spells every note in a range enharmonically — the same pitches, the tpc and glyph `mode` picks under the key
/// in force — MuseScore's Respell Pitches over a selection, as one undo step. A tie chain is one sounding note, so
/// it is re-spelled whole when any member is in range, glyph on the head only. Rests and percussion staves are
/// skipped; a note already spelled that way contributes nothing.
///
/// > Note: This command is sugar over `SetNotePitch` (× note) bundled in a `CompositeEditCommand` by
/// > `RangeEditPlanner`. It exists to give the operation a domain-meaningful name and to own the tie-chain rule;
/// > callers can equally construct the equivalent Composite directly. See `docs/edit-commands.md`.
public struct RespellRange: EditCommand {
    public let range: VoiceElementRange
    public let mode: RespellMode

    public init(over range: VoiceElementRange, mode: RespellMode) {
        self.range = range
        self.mode = mode
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
        guard !score.voiceElements(in: range).isEmpty else { throw Self.refused(.targetNotFound(range.start)) }
        var visited: Set<NoteID> = []
        return try RangeEditPlanner.plan(over: range, in: score) { target, working in
            guard RangeEditPlanner.isPitched(target.staff, in: working) else { return [] }
            return RangeEditPlanner.unvisitedTieChains(of: target, in: working, visited: &visited)
                .flatMap { respell(chain: $0, in: working) }
        }?.composite
    }

    /// One `SetNotePitch` per chain member, all carrying the head's pitch and the tpc `mode` picks for it, with the
    /// glyph on the head alone — the far side of a tie carries none. `[]` when the head already reads that way.
    private func respell(chain: [NoteID], in score: Score) -> [any EditCommand] {
        guard let head = chain.first, let note = score[head] else { return [] }
        let keySig = score.activeKey(at: head)
        let tpc = PitchSpelling.tpc(forPitch: note.pitch, keySig: keySig, mode: mode)
        let glyph = PitchSpelling.displayedAccidental(forTpc: tpc, in: keySig)
        guard tpc != note.tpc || glyph != note.accidental else { return [] }
        return chain.map { member in
            SetNotePitch(at: member, pitch: note.pitch, tpc: tpc, accidental: member == head ? glyph : nil)
        }
    }
}
