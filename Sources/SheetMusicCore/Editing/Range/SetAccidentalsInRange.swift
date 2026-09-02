import SheetMusicFoundation

/// Applies one accidental — or clears the glyph, with `nil` — to every note in a range: the toolbar's ♭♭ ♭ ♮ ♯ 𝄪
/// over a selection, as one undo step. Each note keeps its letter and moves its pitch with the alteration, exactly
/// as `SetAccidental` does for one note.
///
/// A tie chain is one sounding note, so when any member is in range the head takes the accidental and every other
/// member is re-pitched to match, glyph-less — the same split `SetNotePitch`'s planner applies. Rests and
/// percussion staves are skipped; a note that already reads this way contributes nothing.
///
/// > Note: This command is sugar over `SetAccidental` (× chain head) + `SetNotePitch` (× chain member) bundled in
/// > a `CompositeEditCommand` by `RangeEditPlanner`. It exists to give the operation a domain-meaningful name and
/// > to own the tie-chain rule; callers can equally construct the equivalent Composite directly. See
/// > `docs/edit-commands.md`.
public struct SetAccidentalsInRange: EditCommand {
    public let range: VoiceElementRange
    public let accidental: Accidental?

    public init(over range: VoiceElementRange, accidental: Accidental?) {
        self.range = range
        self.accidental = accidental
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

    /// `SetAccidental` on the chain's head plus `SetNotePitch` on each other member, or `[]` when the head already
    /// reads this way. The tail's new pitch is what `SetAccidental` will write on the head, computed the same way:
    /// applying one `SetAccidental` to a score copy is how this reuses that command's transposing-staff detour
    /// (`SetAccidental.respelled`, `private`) without duplicating it.
    private func respell(chain: [NoteID], in score: Score) -> [any EditCommand] {
        guard let head = chain.first, let note = score[head] else { return [] }
        var preview = score
        guard (try? SetAccidental(at: head, accidental: accidental).apply(to: &preview)) != nil,
              let written = preview[head], written != note
        else { return [] }
        var commands: [any EditCommand] = [SetAccidental(at: head, accidental: accidental)]
        for member in chain.dropFirst() {
            commands.append(SetNotePitch(at: member, pitch: written.pitch, tpc: written.tpc, accidental: nil))
        }
        return commands
    }
}
