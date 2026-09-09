/// A selectable engraved element, addressed exactly as its editing command addresses it.
public enum ScoreElementID: Hashable, Sendable {
    /// Transitional positional address of a dynamic's `Voice.elements` slot.
    /// P2b supplies its durable EID through `Score.eid(at:)`.
    case dynamic(anchor: VoiceElementID)
    /// Transitional positional address of a fermata's `Voice.elements` slot.
    /// P2b supplies its durable EID through `Score.eid(at:)`.
    case fermata(anchor: VoiceElementID)
    /// Transitional positional address of a breath's `Voice.elements` slot.
    /// P2b supplies its durable EID through `Score.eid(at:)`.
    case breath(anchor: VoiceElementID)
    /// Transitional positional anchor for `SetTempo`, whose mark lives in `SystemMeasure.elements`.
    /// P2b's successor for durable element naming is `Score.eid(at:)`.
    case tempo(anchor: VoiceElementID)
    /// Transitional positional address of a spanner's `Voice.elements` slot, qualified by kind.
    /// P2b supplies its durable EID through `Score.eid(at:)`.
    case spanner(anchor: VoiceElementID, kind: Spanner.Kind)
    /// Transitional positional bar address for a key signature stored in `Voice.elements`.
    /// Only the bar's leading signature run is addressable: that is all `SetKeySignature` reaches.
    /// P2b's successor for the underlying slot's durable name is `Score.eid(at:)`.
    case keySignature(measureIndex: Int)
    /// Transitional positional bar address for a time signature stored in `Voice.elements`.
    /// Names the bar's meter for `SetTimeSignature`, not an individual declaration's voice slot.
    /// The command reads declarations anywhere in a bar and replaces existing meters in re-barred runs;
    /// it is not restricted to editing a leading signature prefix.
    /// `SetTimeSignature` re-bars the whole span governed by the meter: editing this glyph has wider
    /// consequences than its appearance suggests. P2b's durable-name successor is `Score.eid(at:)`.
    case timeSignature(measureIndex: Int)
    /// Transitional positional bar address, with a role distinguishing explicit and synthesized barlines.
    /// An explicit barline occupies a `Voice.elements` slot; synthesized roles have no slot to name.
    /// P2b's successor for a slot's durable name is `Score.eid(at:)`.
    case barLine(measureIndex: Int, role: BarLineRole)
    /// Permanent positional address through the owning chord and the articulation's kind.
    /// This property keeps its owner-based address rather than acquiring its own EID.
    /// Duplicate articulations of the same kind are indistinguishable, as they are to `SetArticulation`.
    case articulation(anchor: VoiceElementID, kind: ChordArticulation.Kind)

    /// The element or owner anchor, or `nil` for an identity addressed by bar.
    public var anchor: VoiceElementID? {
        switch self {
        case let .dynamic(anchor), let .fermata(anchor), let .breath(anchor), let .tempo(anchor),
             let .spanner(anchor, _), let .articulation(anchor, _): return anchor
        case .keySignature, .timeSignature, .barLine: return nil
        }
    }

    /// The bar address, or `nil` when the identity is addressed through an anchor.
    public var measureIndexIfAddressedByBar: Int? {
        switch self {
        case let .keySignature(index), let .timeSignature(index), let .barLine(index, _): return index
        case .dynamic, .fermata, .breath, .tempo, .spanner, .articulation: return nil
        }
    }
}
