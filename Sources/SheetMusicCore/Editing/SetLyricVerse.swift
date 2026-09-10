import SheetMusicFoundation

/// Moves one whole syllable to another verse on the same chord; only ScoreTextID.lyric is accepted.
/// A nonempty destination is refused as occupiedLyricVerse, never swapped with or displaced.
/// Empty padding is available; a missing or empty source is refused as targetNotFound.
///
/// The syllable moves with its syllabic, ticks and metadata intact. Neighbors are deliberately untouched:
/// LyricInputPlanner repairs them from the terminator the user typed, and a verse move has no terminator.
/// A hyphen or melisma the syllable participated in can therefore be left pointing at a row it no longer occupies.
/// Repairing that relationship requires a host's explicit policy, not an inferred terminator.
///
/// SetLyric owns the array re-index, lower-row padding and trailing-empty trimming. The inverse restores the
/// previous array exactly, including padding and metadata; it is not a reverse move into a possibly occupied row.
/// A same-row move on an existing nonempty syllable is a no-op. Non-lyric addresses are refused as targetNotFound.
///
/// > Note: Delegates to SetLyric, sugar over ReplaceVoiceElement. No neighboring chord is written.
public struct SetLyricVerse: EditCommand {
    public let text: ScoreTextID
    public let toVerse: Int

    public init(_ text: ScoreTextID, toVerse: Int) {
        self.text = text
        self.toVerse = toVerse
    }

    public var affectedLocation: VoiceElementID {
        SetTextVisible(text, visible: true).affectedLocation
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard case let .lyric(anchor, verse) = text else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        return try SetLyric(moving: verse, to: toVerse, at: anchor).apply(to: &score, ids: &ids)
    }
}
