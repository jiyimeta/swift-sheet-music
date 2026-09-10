import SheetMusicFoundation

/// Writes one carrier's authored placement override; nil restores its styled side.
/// The field is written and preserved through MSCX, but this library does not yet draw the override.
/// That rendering gap also affects placement authored elsewhere, before any editing command runs.
/// Hosts must not interpret a lack of visible change as a failed edit. Placement and skyline layout
/// need a separate engraving design; this command changes neither.
///
/// Text, individual notes, and whole chords have distinct addresses. A chord target includes a rest
/// (a chord with no notes) and writes only the chord's own property, never its notes' properties.
///
/// > Note: The note and chord and harmony writes are sugar over ReplaceVoiceElement. The other
/// > text arms write their owner's field directly; lookup rules match SetTextVisible.
public struct SetElementPlacement: EditCommand {
    /// The identity of the thing written, not a selection translated into another vocabulary.
    public enum Target: Sendable, Equatable {
        case text(ScoreTextID)
        case note(NoteID)
        case chord(VoiceElementID)
    }

    public let target: Target
    public let placement: Placement?

    public init(_ target: Target, placement: Placement?) {
        self.target = target
        self.placement = placement
    }

    public var affectedLocation: VoiceElementID {
        switch target {
        case let .note(id): VoiceElementID(id)
        case let .chord(id): id
        case let .text(text):
            switch text {
            case let .lyric(anchor, _), let .staffText(anchor, _), let .harmony(anchor): anchor
            case let .rehearsalMark(index):
                VoiceElementID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: index, voiceIndex: 0, elementIndex: 0,
                )
            }
        }
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        if case let .note(id) = target, score[id] == nil { throw Self.refused(.noteNotFound(id)) }
        if case let .chord(id) = target {
            guard let element = score[id] else { throw Self.refused(.targetNotFound(id)) }
            guard case .chord = element else {
                throw Self.refused(.wrongElementKind(at: id, expected: .chordOrRest))
            }
        }
        guard let old = Self.currentProperties(for: target, in: score) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        switch target {
        case let .text(text):
            try writeText(text, to: &score)
        case let .note(id):
            let slot = VoiceElementID(id)
            guard case var .chord(chord)? = score[slot], chord.notes.indices.contains(id.noteIndexInChord)
            else { throw Self.refused(.noteNotFound(id)) }
            chord.notes[id.noteIndexInChord].elementProperties.placement = placement
            score[slot] = .chord(chord)
        case let .chord(id):
            guard case var .chord(chord)? = score[id] else {
                throw Self.refused(.wrongElementKind(at: id, expected: .chordOrRest))
            }
            chord.elementProperties.placement = placement
            score[id] = .chord(chord)
        }
        return SetElementPlacement(target, placement: old.placement)
    }

    /// Nil means the target is absent; a present carrier with an inherited property still returns properties.
    /// The planner must distinguish these so clearing a missing target is refused instead of skipped.
    public static func currentProperties(for target: Target, in score: Score) -> ElementProperties? {
        switch target {
        case let .note(id): return score[id]?.elementProperties
        case let .chord(id):
            guard case let .chord(chord)? = score[id] else { return nil }
            return chord.elementProperties
        case let .text(text):
            switch text {
            case let .lyric(anchor, verse):
                return SetLyric.current(at: anchor, verse: verse, in: score)?.elementProperties
            case let .staffText(anchor, style):
                return SetStaffText.laneMark(at: anchor, isSystemText: style == .systemText, in: score)?
                    .elementProperties
            case let .harmony(anchor):
                return SetChordSymbol.current(at: anchor, in: score)?.elementProperties
            case let .rehearsalMark(index):
                return RehearsalMarkLane.mark(in: score, measureIndex: index)?.elementProperties
            }
        }
    }

    private func writeText(_ text: ScoreTextID, to score: inout Score) throws {
        switch text {
        case let .lyric(anchor, verse):
            guard case var .chord(chord)? = score[anchor], chord.lyrics.indices.contains(verse)
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            chord.lyrics[verse].elementProperties.placement = placement
            score[anchor] = .chord(chord)
        case let .staffText(anchor, style):
            guard let slot = SetStaffText.laneSlot(
                at: anchor, isSystemText: style == .systemText, in: score,
            ), case var .staffText(mark) = score.systemMeasures[slot.measureIndex].elements[slot.elementIndex].element
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            mark.elementProperties.placement = placement
            score.systemMeasures.updateValue(at: slot.measureIndex) {
                $0.elements[slot.elementIndex].element = .staffText(mark)
            }
        case let .harmony(anchor):
            guard let slot = SetChordSymbol.harmonySlot(at: anchor, in: score),
                  case var .harmony(harmony)? = score[slot]
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            harmony.elementProperties.placement = placement
            score[slot] = .harmony(harmony)
        case let .rehearsalMark(index):
            guard score.systemMeasures.indices.contains(index),
                  let slot = RehearsalMarkLane.markIndex(in: score.systemMeasures[index]),
                  case var .rehearsalMark(mark) = score.systemMeasures[index].elements[slot].element
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            mark.elementProperties.placement = placement
            score.systemMeasures.updateValue(at: index) { $0.elements[slot].element = .rehearsalMark(mark) }
        }
    }
}
