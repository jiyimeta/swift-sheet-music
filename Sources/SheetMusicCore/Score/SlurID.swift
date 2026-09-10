/// The storage address of one slur, independent of its rendered segments.
public enum SlurID: Hashable, Sendable {
    /// A slur in the chord's (or rest's) spanners list at `anchor`.
    /// The ordinal counts only slur entries, including hidden ones.
    case chord(anchor: VoiceElementID, ordinal: Int)
    /// A slur stored in its own spanner slot in `Voice.elements`.
    case voice(VoiceElementID)

    /// The owning chord/rest or standalone voice slot.
    public var anchor: VoiceElementID {
        switch self {
        case let .chord(anchor, _), let .voice(anchor): return anchor
        }
    }
}
