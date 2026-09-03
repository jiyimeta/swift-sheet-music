import SheetMusicFoundation

/// Shows or hides the beam of a beam group — MuseScore's `V` on a beam — by writing `Chord.beamVisible`, the
/// model's `<Beam><visible>0</visible></Beam>`.
///
/// The flag lives on the group's LEADING chord and is read from nowhere else (`Chord.beamVisible` doc; the layout's
/// Phase 5 in `LayoutEngine+Placement`). This command writes exactly where it is pointed — its inverse must land on
/// the same slot — so the re-targeting from any member to the leader is the planner's
/// (`ScoreEditSession.visibilityCommand`), which every `EditIntent.setBeamVisible` goes through; a caller building
/// the command directly passes `leader(of:in:)`'s answer. A chord that is a member of no group is refused as
/// `.notBeamed`, since the flag would be invisible there and the encoder would write a `<Beam>` in front of an
/// unbeamable note. Grouping is `BeamGrouping`, the same rule the layout beams with.
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
        guard Self.leader(of: location, in: score) != nil else { throw Self.refused(.notBeamed(at: location)) }
        let old = chord.beamVisible
        chord.beamVisible = visible
        score[location] = .chord(chord)
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
