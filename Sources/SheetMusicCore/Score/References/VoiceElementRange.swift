import SheetMusicFoundation

/// A rectangular region of the score, bounded by two timed elements: the staves between `start.staff` and
/// `end.staff` (either order), every voice, and the onsets from the earlier element's onset up to — excluding — the
/// later element's end. Resolved by `Score.voiceElements(in:)`, with exactly the semantics of
/// `Score.items(inRangeFrom:to:)`, which is what a ⇧-click range selection already means.
///
/// Member of the closed reference family; both bounds are themselves family members, so SP0's identity lands on
/// them and this type needs nothing of its own.
public struct VoiceElementRange: Hashable, Sendable {
    public var start: VoiceElementID
    public var end: VoiceElementID

    public init(start: VoiceElementID, end: VoiceElementID) {
        self.start = start
        self.end = end
    }
}
