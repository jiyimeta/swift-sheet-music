import SheetMusicFoundation

/// Shows or hides the beam of a beam group — MuseScore's `V` on a beam — by writing `Chord.beamVisible`, the
/// model's `<Beam><visible>0</visible></Beam>`.
///
/// The flag lives on the group's LEADING chord and is read from nowhere else (`Chord.beamVisible` doc; the layout's
/// Phase 5 in `LayoutEngine+Placement`). This command writes exactly where it is pointed — its inverse must land on
/// the same slot — so the re-targeting from any member to the leader is the planner's
/// (`ScoreEditSession.visibilityCommand`), which every `EditIntent.setBeamVisible` goes through; a caller building
/// the command directly passes `leader(of:in:)`'s answer. Grouping is `BeamGrouping`, the same rule the layout
/// beams with.
///
/// `.notBeamed` gates the WRITE (`visible == false`) only: hiding a beam on a chord that belongs to no group is
/// refused, since the flag would be invisible there and the encoder would write a `<Beam>` in front of an unbeamable
/// note. Showing/clearing (`visible == true`) is NEVER refused — with a group it targets the leader as usual; with
/// no group it writes `true` straight onto the chord `location` names. This asymmetry exists so a flag orphaned by
/// a group dissolving out from under it (a later `setDots` / `setDurationInRange` / `deleteRange` lengthening or
/// removing a member) stays clearable: before the encoder persisted `beamVisible == false` on non-leader chords too,
/// an orphaned `false` evaporated on save; now it would otherwise become permanent and unreachable.
///
/// The inverse differs by the same split. With a group present, `apply` returns a self-inverse
/// (`SetBeamVisible(visible: old)`): its own precondition — a beam group at `location` — is guaranteed to hold when
/// `ScoreEditor.undo()` reaches it, by the same LIFO argument `SetArticulation` / `SetChordLine` rely on. Clearing
/// an ORPHANED flag (no group) is the one case that argument does not cover: the precondition depends on sibling
/// elements, not on `location` itself, so a command that dissolved the group can sit BELOW this one on the undo
/// stack without ever being undone first — undoing this entry alone would re-throw `.notBeamed` and, since
/// `ScoreEditor.undo()` pops before applying, silently drop the entry and desync the stack from the score. So that
/// branch returns `ReplaceVoiceElement(at: location, with: <the pre-image chord>)` instead: it has no beam-group
/// precondition, restores the chord (and the flag) unconditionally, and — like `SetArticulation` / `SetChordLine` —
/// hands undo → redo → undo back their usual guarantees.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. It exists to give the operation a domain-meaningful
/// > name and to own the group check; callers can equally construct the primitive directly. See
/// > `docs/edit-commands.md`.
public struct SetBeamVisible: EditCommand {
    public let location: VoiceElementID
    public let visible: Bool

    public init(at location: VoiceElementID, visible: Bool) {
        self.location = location
        self.visible = visible
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else { throw Self.refused(.targetNotFound(location)) }
        guard case var .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        let hasGroup = Self.leader(of: location, in: score) != nil
        if !visible, !hasGroup {
            throw Self.refused(.notBeamed(at: location))
        }
        let old = chord.beamVisible
        chord.beamVisible = visible
        score[location] = .chord(chord)
        guard hasGroup else {
            // Clearing an orphaned flag: the self-inverse's `.notBeamed` precondition depends on sibling
            // elements, not on `location`, so it can go unmet at undo time even under LIFO ordering (see the
            // doc comment above). The pre-image has no such precondition.
            return ReplaceVoiceElement(at: location, with: element)
        }
        return SetBeamVisible(at: location, visible: old)
    }

    /// The leading chord of the beam group `location` belongs to, or `nil` when it belongs to none.
    static func leader(of location: VoiceElementID, in score: Score) -> VoiceElementID? {
        BeamGrouping.leader(of: location, in: score)
    }

    /// The beam flag of the group `location` belongs to — read off its leader — or `nil` when the element is not
    /// a beamed chord.
    static func current(at location: VoiceElementID, in score: Score) -> Bool? {
        guard let lead = leader(of: location, in: score), case let .chord(chord)? = score[lead] else { return nil }
        return chord.beamVisible
    }
}
