import SheetMusicFoundation

/// Writes, replaces or (with `nil`) removes the fermata over the chord or rest at `location`.
///
/// The fermata sits immediately before the element it holds — the position `Score.fermataHolds()` resolves
/// first, and the one MSCX writes (`AdjacentElementSlot`). A fermata already in the element's attachment run is
/// replaced in place (subtype and `timeStretch` change, visibility survives); none → one is inserted right
/// before the element. `timeStretch` is written as given: a host that wants the subtype's default passes
/// `Fermata.defaultTimeStretch(for:)`.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` / `ReplaceVoiceElements`. See `docs/edit-commands.md`.
public struct SetFermata: EditCommand {
    public let location: VoiceElementID
    /// The SMuFL name (`"fermataAbove"`, `"fermataLongBelow"`, …), or `nil` to remove.
    public let subtype: String?
    /// The MIDI hold ratio to write; ignored when `subtype` is `nil`.
    public let timeStretch: Double

    public init(at location: VoiceElementID, subtype: String?, timeStretch: Double) {
        self.location = location
        self.subtype = subtype
        self.timeStretch = timeStretch
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else { throw Self.refused(.targetNotFound(location)) }
        guard case .chord = element else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chordOrRest))
        }
        let ref = VoiceRef(location)
        let existing = AdjacentElementSlot.find(.before, of: location, in: score, where: Self.isFermata)
        guard let subtype else {
            guard let index = existing,
                  let removal = AdjacentElementSlot.removing(at: index, in: ref, of: score)
            else { throw Self.refused(.targetNotFound(location)) }
            return try removal.apply(to: &score)
        }
        if let index = existing, case var .fermata(fermata)? = score[location.withElementIndex(index)] {
            fermata.subtype = subtype
            fermata.timeStretch = timeStretch
            return try AdjacentElementSlot.replacing(.fermata(fermata), at: index, in: ref).apply(to: &score)
        }
        guard let insert = AdjacentElementSlot.inserting(
            .fermata(Fermata(subtype: subtype, timeStretch: timeStretch)),
            at: AdjacentElementSlot.insertionIndex(.before, of: location.elementIndex), in: ref, of: score,
        ) else { throw Self.refused(.targetNotFound(location)) }
        return try insert.apply(to: &score)
    }

    /// The fermata in the attachment run before the chord or rest at `location`, or `nil`.
    static func current(at location: VoiceElementID, in score: Score) -> Fermata? {
        guard let index = AdjacentElementSlot.find(.before, of: location, in: score, where: isFermata),
              case let .fermata(fermata)? = score[location.withElementIndex(index)]
        else { return nil }
        return fermata
    }

    private static func isFermata(_ element: VoiceElement) -> Bool {
        if case .fermata = element { true } else { false }
    }
}
