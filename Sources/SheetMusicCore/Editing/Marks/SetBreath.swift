import SheetMusicFoundation

/// Writes, replaces or (with `nil`) removes the breath mark or caesura after the chord or rest at `location`.
///
/// A breath is an independent voice element sitting immediately AFTER the chord it follows — MuseScore's
/// `Breath` segment at the chord's end tick, and the MSCX order (`AdjacentElementSlot`). A rest takes one the same way:
/// MuseScore's `Rest::acceptDrop` hands a breath to `ChordRest::acceptDrop`, whose `drop` writes it at the rest's end
/// tick, and a breath that followed a chord stays put when the chord is cleared to a rest. A breath already in
/// the chord's after-run is replaced in place (kind and pause change, visibility survives); none → one is
/// inserted right after the chord, ahead of a trailing barline. `pause` is written as given: a host that wants
/// the style's default passes `Breath.defaultPause(for:)`.
///
/// For the chord or rest ending its bar, a breath at the head of the NEXT bar follows it too
/// (`Voice.barHeadBreathIndices` — a file can carry one there), after any in the element's own after-run: it is the
/// one replaced or removed when the after-run has none. A new breath is still written into the element's own bar.
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
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let element = score[location] else { throw Self.refused(.targetNotFound(location)) }
        guard case .chord = element else { throw Self.refused(.wrongElementKind(at: location, expected: .chord)) }
        let ref = VoiceRef(location)
        let existing = Self.existingSlot(after: location, in: score)
        guard let kind else {
            guard let slot = existing,
                  let removal = AdjacentElementSlot.removing(at: slot.elementIndex, in: VoiceRef(slot), of: score)
            else { throw Self.refused(.targetNotFound(location)) }
            return try removal.apply(to: &score, ids: &ids)
        }
        if let slot = existing, case var .breath(breath)? = score[slot] {
            breath.kind = kind
            breath.pause = pause
            return try AdjacentElementSlot.replacing(.breath(breath), at: slot.elementIndex, in: VoiceRef(slot))
                .apply(to: &score, ids: &ids)
        }
        guard let insert = AdjacentElementSlot.inserting(
            .breath(Breath(kind: kind, pause: pause)),
            at: AdjacentElementSlot.insertionIndex(.after, of: location.elementIndex), in: ref, of: score,
        ) else { throw Self.refused(.targetNotFound(location)) }
        return try insert.apply(to: &score, ids: &ids)
    }

    /// The breath that follows the chord or rest at `location` — the one this command replaces or removes — or `nil`.
    public static func current(after location: VoiceElementID, in score: Score) -> Breath? {
        guard let slot = existingSlot(after: location, in: score), case let .breath(breath)? = score[slot] else {
            return nil
        }
        return breath
    }

    /// Where the breath following the chord or rest at `location` stands: the first breath in its after-run, else —
    /// for the element ending its bar (`Voice.barEndBreathOwnerIndex`) — the first breath at the head of the same
    /// voice in the next bar. `nil` when neither holds one.
    static func existingSlot(after location: VoiceElementID, in score: Score) -> VoiceElementID? {
        if let index = AdjacentElementSlot.find(.after, of: location, in: score, where: isBreath) {
            return location.withElementIndex(index)
        }
        guard score[voice: VoiceRef(location)]?.barEndBreathOwnerIndex == location.elementIndex else { return nil }
        let next = VoiceElementID(
            staff: location.staff, measureIndex: location.measureIndex + 1, voiceIndex: location.voiceIndex,
            elementIndex: 0,
        )
        guard let index = score[voice: VoiceRef(next)]?.barHeadBreathIndices.first else { return nil }
        return next.withElementIndex(index)
    }

    private static func isBreath(_ element: VoiceElement) -> Bool {
        if case .breath = element { true } else { false }
    }
}
