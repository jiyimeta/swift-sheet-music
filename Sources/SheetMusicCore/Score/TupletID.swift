import SheetMusicFoundation

/// Path-based identity for a tuplet inside a `Score`. A tuplet is
/// keyed by its first member's element index — the entry in the
/// owning voice's `tuplets` array whose `startIndex` matches.
///
/// Use the `Score[tupletID]` subscript to resolve the underlying
/// `Tuplet` value (or `nil` when the path no longer points at a
/// live tuplet, typically after an edit invalidated it).
public struct TupletID: Hashable, Sendable {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int
    /// Element index of the first member in the owning voice's
    /// `elements` array — the same value as the `Tuplet.startIndex`
    /// it points at.
    public let startElementIndex: Int

    public init(
        staff: StaffAddress,
        measureIndex: Int,
        voiceIndex: Int,
        startElementIndex: Int,
    ) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.startElementIndex = startElementIndex
    }
}

extension Score {
    /// Resolve a `TupletID` to its `Tuplet` entry, or `nil` when
    /// the path no longer lands on a live tuplet.
    public subscript(tupletID: TupletID) -> Tuplet? {
        guard let staff = self[tupletID.staff] else { return nil }
        guard staff.measures.indices.contains(tupletID.measureIndex)
        else { return nil }
        let voices = staff.measures[tupletID.measureIndex].voices
        guard voices.indices.contains(tupletID.voiceIndex)
        else { return nil }
        return voices[tupletID.voiceIndex].tuplets.first {
            $0.startIndex == tupletID.startElementIndex
        }
    }
}
