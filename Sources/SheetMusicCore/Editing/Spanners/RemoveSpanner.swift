import SheetMusicFoundation

/// Takes a spanner of `kind` off the element at `location`.
///
/// Two shapes, because there are two storage forms. For every LINE kind (and for a volta), `location` names the
/// `.spanner` `VoiceElement` itself and the element is removed, which moves the later indices of that voice back
/// by one — `AdjacentElementSlot.removing` remaps the bar's tuplets and its inverse restores the indices exactly.
/// For `.slur`, `location` names the CHORD, and EVERY slur entry of `Chord.spanners` is dropped: a chord can carry
/// an inner and an outer slur, and this command takes both, per spec row 72's "the slur entries of the chord at
/// the ID". A caller that means only one of them writes the `ReplaceVoiceElement` directly.
///
/// Refused as `.noSpannerAtLocation` when the element carries nothing of that kind (a chord with no slur, a
/// `.spanner` of a different kind) and as `.wrongElementKind` when it is neither shape — distinct answers,
/// because "there is nothing to remove here" and "this is not the sort of thing that carries one" are different
/// facts for a host to show.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` / `ReplaceVoiceElements`. See
/// > `docs/edit-commands.md`.
public struct RemoveSpanner: EditCommand {
    public let location: VoiceElementID
    public let kind: Spanner.Kind

    public init(at location: VoiceElementID, kind: Spanner.Kind) {
        self.location = location
        self.kind = kind
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        try SpannerPlacement.remove(kind, at: location, in: score).apply(to: &score)
    }
}
