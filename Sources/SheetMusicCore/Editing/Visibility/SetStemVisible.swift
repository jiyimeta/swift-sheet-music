import SheetMusicFoundation

/// Shows or hides one chord's stem (and with it the flag) — MuseScore's `V` on a stem — by writing
/// `Chord.stemVisible`, the model's `<Stem><visible>0</visible></Stem>`. The noteheads keep their own flags; a rest
/// has no stem and is refused.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. It exists to give the operation a domain-meaningful
/// > name and to centralise the small bit of validation it performs; callers can equally construct the primitive
/// > directly. See `docs/edit-commands.md`.
public struct SetStemVisible: EditCommand {
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
        let old = chord.stemVisible
        chord.stemVisible = visible
        score[location] = .chord(chord)
        return SetStemVisible(at: location, visible: old)
    }

    /// The stem flag of the chord at `location`; `nil` for a rest, an untimed element or a missing slot.
    static func current(at location: VoiceElementID, in score: Score) -> Bool? {
        guard case let .chord(chord)? = score[location], !chord.notes.isEmpty else { return nil }
        return chord.stemVisible
    }
}
