import SheetMusicFoundation

/// Patches authored font and frame overrides on one existing text, preserving all other metadata.
/// Each field distinguishes unchanged, clear (nil/style inheritance), and set (including empty or zero).
///
/// | Field | Harmony | Lyric / StaffText / RehearsalMark |
/// | --- | --- | --- |
/// | face | Drawn (subject to font fallback) | Not yet drawn |
/// | size | Drawn | Not yet drawn |
/// | style | Bold/italic drawn; underline/strike not yet drawn | Not yet drawn |
/// | frameType | Not yet drawn | Not yet drawn |
/// | framePadding | Not yet drawn | Not yet drawn |
///
/// All five fields are written and preserved through MSCX even where they are not yet drawn.
/// Hosts must not interpret a lack of visible change as a failed edit. This command changes no layout wiring.
/// StaffText includes staff and system text, independently addressed at the same beat.
///
/// > Note: Harmony is sugar over ReplaceVoiceElement; the other arms write their owner's field directly.
/// Lookup rules match SetTextVisible. The inverse restores only the fields this patch addresses.
public struct SetTextFont: EditCommand {
    public let text: ScoreTextID
    public let patch: Patch

    public init(_ text: ScoreTextID, patch: Patch) {
        self.text = text
        self.patch = patch
    }

    public var affectedLocation: VoiceElementID {
        SetTextVisible(text, visible: true).affectedLocation
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let previous = Self.current(text, in: score) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        try writeText(text, to: &score)
        return SetTextFont(text, patch: patch.restoring(previous))
    }

    /// Nil is an absent carrier, not a carrier whose five overrides are all nil.
    public static func current(_ text: ScoreTextID, in score: Score) -> TextProperties? {
        switch text {
        case let .lyric(anchor, verse):
            return SetLyric.current(at: anchor, verse: verse, in: score)?.properties
        case let .staffText(anchor, style):
            return SetStaffText.laneMark(at: anchor, isSystemText: style == .systemText, in: score)?.properties
        case let .harmony(anchor):
            return SetChordSymbol.current(at: anchor, in: score)?.properties
        case let .rehearsalMark(index):
            return RehearsalMarkLane.mark(in: score, measureIndex: index)?.properties
        }
    }

    private func writeText(_ text: ScoreTextID, to score: inout Score) throws {
        switch text {
        case let .lyric(anchor, verse):
            guard case var .chord(chord)? = score[anchor], chord.lyrics.indices.contains(verse)
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            chord.lyrics[verse].properties = patch.applying(to: chord.lyrics[verse].properties)
            score[anchor] = .chord(chord)
        case let .staffText(anchor, style):
            guard let slot = SetStaffText.laneSlot(
                at: anchor, isSystemText: style == .systemText, in: score,
            ), case var .staffText(mark) = score.systemMeasures[slot.measureIndex].elements[slot.elementIndex].element
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            mark.properties = patch.applying(to: mark.properties)
            score.systemMeasures.updateValue(at: slot.measureIndex) {
                $0.elements.updateValue(at: slot.elementIndex) { $0.element = .staffText(mark) }
            }
        case let .harmony(anchor):
            guard let slot = SetChordSymbol.harmonySlot(at: anchor, in: score),
                  case var .harmony(harmony)? = score[slot]
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            harmony.properties = patch.applying(to: harmony.properties)
            score[slot] = .harmony(harmony)
        case let .rehearsalMark(index):
            guard score.systemMeasures.indices.contains(index),
                  let slot = RehearsalMarkLane.markIndex(in: score.systemMeasures[index]),
                  case var .rehearsalMark(mark) = score.systemMeasures[index].elements[slot].element
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            mark.properties = patch.applying(to: mark.properties)
            score.systemMeasures.updateValue(at: index) {
                $0.elements.updateValue(at: slot) { $0.element = .rehearsalMark(mark) }
            }
        }
    }
}
