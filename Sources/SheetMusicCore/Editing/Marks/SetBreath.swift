import SheetMusicFoundation

/// Writes, replaces or (with `nil`) removes the breath mark or caesura after the chord at `location`.
///
/// A breath is an independent voice element sitting immediately AFTER the chord it follows — MuseScore's
/// `Breath` segment at the chord's end tick, and the MSCX order (`AdjacentElementSlot`). A breath already in
/// the chord's after-run is replaced in place (kind and pause change, visibility survives); none → one is
/// inserted right after the chord, ahead of a trailing barline. `pause` is written as given: a host that wants
/// the style's default passes `Breath.defaultPause(for:)`.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` / `ReplaceVoiceElements`. See `docs/edit-commands.md`.
public struct SetBreath: EditCommand {
    public let location: VoiceElementID
    /// The breath's family and style, or `nil` to remove.
    public let kind: Breath.Kind?
    /// Seconds of silence to write; ignored when `kind` is `nil`.
    public let pause: Double

    public init(after location: VoiceElementID, kind: Breath.Kind?, pause: Double) {
        self.location = location
        self.kind = kind
        self.pause = pause
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else { throw Self.refused(.targetNotFound(location)) }
        guard case let .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        let ref = VoiceRef(location)
        let existing = AdjacentElementSlot.find(.after, of: location, in: score, where: Self.isBreath)
        guard let kind else {
            guard let index = existing,
                  let removal = AdjacentElementSlot.removing(at: index, in: ref, of: score)
            else { throw Self.refused(.targetNotFound(location)) }
            return try removal.apply(to: &score)
        }
        if let index = existing, case var .breath(breath)? = score[location.withElementIndex(index)] {
            breath.kind = kind
            breath.pause = pause
            return try AdjacentElementSlot.replacing(.breath(breath), at: index, in: ref).apply(to: &score)
        }
        guard let insert = AdjacentElementSlot.inserting(
            .breath(Breath(kind: kind, pause: pause)),
            at: AdjacentElementSlot.insertionIndex(.after, of: location.elementIndex), in: ref, of: score,
        ) else { throw Self.refused(.targetNotFound(location)) }
        return try insert.apply(to: &score)
    }

    /// The breath in the attachment run after the chord at `location`, or `nil`.
    static func current(after location: VoiceElementID, in score: Score) -> Breath? {
        guard let index = AdjacentElementSlot.find(.after, of: location, in: score, where: isBreath),
              case let .breath(breath)? = score[location.withElementIndex(index)]
        else { return nil }
        return breath
    }

    private static func isBreath(_ element: VoiceElement) -> Bool {
        if case .breath = element { true } else { false }
    }
}
