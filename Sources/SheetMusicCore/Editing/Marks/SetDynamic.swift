import SheetMusicFoundation

/// Writes, replaces or (with `nil`) removes the dynamic marking on the chord at `location` — MuseScore's
/// dynamics palette, "nil clears".
///
/// The dynamic sits in the voice stream immediately before its chord, the placement MSCX uses
/// (`AdjacentElementSlot`). A dynamic already in the chord's attachment run is replaced in place — subtype and
/// velocity change, its font overrides and visibility survive; none → one is inserted right before the chord.
/// The velocity is MuseScore's default for the subtype (`Dynamic.defaultVelocity(for:)`), what the decoder
/// fills in when a file omits `<velocity>`.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` (replace) or `ReplaceVoiceElements` (insert /
/// > remove). It exists to give the operation a domain-meaningful name and to own the adjacency rule; callers
/// > can equally construct the equivalent primitive directly. See `docs/edit-commands.md`.
public struct SetDynamic: EditCommand {
    public let location: VoiceElementID
    /// The MSCX subtype token (`"pp"`, `"mf"`, `"sfz"`, …), or `nil` to remove.
    public let subtype: String?

    public init(at location: VoiceElementID, subtype: String?) {
        self.location = location
        self.subtype = subtype
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
        let existing = AdjacentElementSlot.find(.before, of: location, in: score, where: Self.isDynamic)
        guard let subtype else {
            guard let index = existing,
                  let removal = AdjacentElementSlot.removing(at: index, in: ref, of: score)
            else { throw Self.refused(.targetNotFound(location)) }
            return try removal.apply(to: &score)
        }
        if let index = existing, case var .dynamic(dynamic)? = score[location.withElementIndex(index)] {
            dynamic.subtype = subtype
            dynamic.velocity = Dynamic.defaultVelocity(for: subtype)
            return try AdjacentElementSlot.replacing(.dynamic(dynamic), at: index, in: ref).apply(to: &score)
        }
        guard let insert = AdjacentElementSlot.inserting(
            .dynamic(Dynamic(subtype: subtype, velocity: Dynamic.defaultVelocity(for: subtype))),
            at: AdjacentElementSlot.insertionIndex(.before, of: location.elementIndex), in: ref, of: score,
        ) else { throw Self.refused(.targetNotFound(location)) }
        return try insert.apply(to: &score)
    }

    /// The dynamic in the attachment run before the chord at `location`, or `nil`.
    static func current(at location: VoiceElementID, in score: Score) -> Dynamic? {
        guard let index = AdjacentElementSlot.find(.before, of: location, in: score, where: isDynamic),
              case let .dynamic(dynamic)? = score[location.withElementIndex(index)]
        else { return nil }
        return dynamic
    }

    private static func isDynamic(_ element: VoiceElement) -> Bool {
        if case .dynamic = element { true } else { false }
    }
}
