import SheetMusicFoundation

/// Toggle one articulation kind on a chord — MuseScore's palette click, which adds the mark when the chord does
/// not carry it and takes it away when it does (`Score::toggleArticulation`, `editing/cmd.cpp:2443-2470`). The
/// decision is `present`'s rather than the score's, so a host that knows what it wants (a toolbar showing the
/// mark as ON) writes that state directly and a replay is idempotent; `ScoreEditSession` supplies the toggle by
/// reading the chord first and planning the opposite of what it finds.
///
/// A write REPLACES every entry of the same kind, so re-writing with a different anchor moves the mark instead of
/// doubling it; a clear removes every entry of that kind. Other kinds are never touched. Matching is `Kind`
/// equality, so `.unknown(subtype:)` toggles exactly the string it preserved.
///
/// The mark is appended. MuseScore sorts its own array by layout proximity (`Chord::add`, `dom/chord.cpp:700-716`)
/// and re-sorts on load, and this package's layout reads each mark from its own kind rather than from the array
/// order, so appending is both stable and cheap.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. It exists to give the operation a domain-meaningful
/// > name and to own the replace-by-kind rule; callers can equally construct the primitive directly. See
/// > `docs/edit-commands.md`.
public struct SetArticulation: EditCommand {
    public let location: VoiceElementID
    public let kind: ChordArticulation.Kind
    public let anchor: ChordArticulation.Anchor?
    public let present: Bool

    public init(
        at location: VoiceElementID, kind: ChordArticulation.Kind, anchor: ChordArticulation.Anchor?,
        present: Bool,
    ) {
        self.location = location
        self.kind = kind
        self.anchor = anchor
        self.present = present
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    /// The articulations the chord at `location` carries of `kind`, or `nil` when there is no chord there —
    /// what the planner reads to decide whether the intent restates the score.
    static func current(
        at location: VoiceElementID, kind: ChordArticulation.Kind, in score: Score,
    ) -> [ChordArticulation]? {
        guard case let .chord(chord)? = score[location], !chord.notes.isEmpty else { return nil }
        return chord.articulations.filter { $0.kind == kind }
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case var .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        // The pre-image is the inverse's whole payload: a chord that carried the same kind twice, or carried it
        // with an anchor this command does not name, has no single `SetArticulation` that restores it.
        let inverse = ReplaceVoiceElement(at: location, with: element)
        chord.articulations.removeAll { $0.kind == kind }
        if present {
            chord.articulations.append(ChordArticulation(kind: kind, anchor: anchor))
        }
        score[location] = .chord(chord)
        return inverse
    }
}
