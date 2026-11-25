import SheetMusicFoundation

/// Toggle one ornament kind on a chord — MuseScore's palette click, where an ornament is an articulation: the same
/// subtype comes off, a different one is added (`Score::toggleArticulation`, `editing/cmd.cpp:2443-2470`). As with
/// `SetArticulation`, the decision is `present`'s rather than the score's, so a replay is idempotent and a host that
/// wants the toggle reads the chord first and writes the opposite of what it finds.
///
/// A write keeps an ornament of the kind that is already on the chord as it is — its intervals, accidentals, style,
/// `plays`, anchor and markup, none of which this command names — and otherwise appends `ChordOrnament(kind:)`. A
/// clear removes every entry of the kind. Other kinds are never touched. Matching is `Kind` equality, so
/// `.unknown(subtype:)` toggles exactly the string it preserved.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. It exists to give the operation a domain-meaningful
/// > name and to own the keep-what-is-there rule; callers can equally construct the primitive directly. See
/// > `docs/edit-commands.md`.
public struct SetOrnament: EditCommand {
    public let location: VoiceElementID
    public let kind: ChordOrnament.Kind
    public let present: Bool

    public init(at location: VoiceElementID, kind: ChordOrnament.Kind, present: Bool) {
        self.location = location
        self.kind = kind
        self.present = present
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    /// The ornaments the chord at `location` carries of `kind`, or `nil` when there is no chord there — what the
    /// planner reads to decide whether the intent restates the score.
    static func current(
        at location: VoiceElementID, kind: ChordOrnament.Kind, in score: Score,
    ) -> [ChordOrnament]? {
        guard case let .chord(chord)? = score[location], !chord.notes.isEmpty else { return nil }
        return chord.ornaments.filter { $0.kind == kind }
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let element = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case var .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        // The pre-image is the inverse's whole payload: a removed ornament carries more than a kind, so no
        // `SetOrnament` restores it.
        let inverse = ReplaceVoiceElement(at: location, with: element, identity: .same)
        if !present {
            chord.ornaments.removeAll { $0.kind == kind }
        } else if !chord.ornaments.contains(where: { $0.kind == kind }) {
            chord.ornaments.append(ChordOrnament(kind: kind))
        }
        score[location] = .chord(chord)
        return inverse
    }
}
