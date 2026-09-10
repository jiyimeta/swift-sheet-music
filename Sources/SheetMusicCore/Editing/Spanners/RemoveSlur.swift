import SheetMusicFoundation

/// Removes one slur from its chord/rest list or its standalone voice slot.
/// Chord ordinals count only slurs, including hidden entries, in storage order. Undo restores the same raw
/// list index. Standalone removal uses `AdjacentElementSlot` to remap tuplets and restore the full voice on undo.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` / `ReplaceVoiceElements`. It centralizes
/// > storage-form validation and gives the operation a domain-meaningful name. See `docs/edit-commands.md`.
public struct RemoveSlur: EditCommand {
    public let id: SlurID

    public init(_ id: SlurID) {
        self.id = id
    }

    public var affectedLocation: VoiceElementID {
        id.anchor
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        let anchor = id.anchor
        guard let element = score[anchor] else {
            throw Self.refused(.targetNotFound(anchor))
        }
        switch id {
        case let .chord(_, ordinal):
            guard case var .chord(chord) = element else {
                throw Self.refused(.wrongElementKind(at: anchor, expected: .chordOrRest))
            }
            let indices = chord.spanners.indices.filter { chord.spanners[$0].kind == .slur }
            guard indices.indices.contains(ordinal) else {
                throw Self.refused(.noSpannerAtLocation(anchor))
            }
            chord.spanners.remove(at: indices[ordinal])
            return try ReplaceVoiceElement(at: anchor, with: .chord(chord)).apply(to: &score, ids: &ids)
        case .voice:
            guard case let .spanner(spanner) = element else {
                throw Self.refused(.wrongElementKind(at: anchor, expected: .spanner))
            }
            guard spanner.kind == .slur else {
                throw Self.refused(.noSpannerAtLocation(anchor))
            }
            guard let command = AdjacentElementSlot.removing(
                at: anchor.elementIndex, in: VoiceRef(anchor), of: score,
            ) else {
                throw Self.refused(.targetNotFound(anchor))
            }
            return try command.apply(to: &score, ids: &ids)
        }
    }
}
