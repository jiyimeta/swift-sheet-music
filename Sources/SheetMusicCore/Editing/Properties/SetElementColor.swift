import SheetMusicFoundation

/// Writes one text's or individual note's author color; nil restores inherited ink.
/// Chord.elementProperties.color is deliberately not written: nothing carries it to the page.
/// Note.elementProperties.color reaches the notehead and, by the same value, its stem, flag and dots
/// (LayoutEngine+Placement and the chord renderers). A chord target must not be added merely to
/// complete the set of model carriers.
/// The shared stem and flag use the first explicitly colored note, as the existing renderers decide.
///
/// Text uses ScoreTextID's existing lyric, lane, and harmony attachment rules. A note uses NoteID,
/// including noteIndexInChord, so coloring one note never recolors its chord or a neighboring note.
/// A tempo marking is addressed as a click selects it (`ScoreElementID.tempo(anchor:)`) and as `SetTempo`
/// writes it, by the chord or rest at its beat; its color reaches the metronome glyph and the number alike.
///
/// > Note: The note and harmony writes are sugar over ReplaceVoiceElement. The other
/// > text arms and the tempo arm write their owner's field directly; lookup rules match SetTextVisible and
/// > SetTempo respectively.
public struct SetElementColor: EditCommand {
    /// The identity of the thing written, not a selection translated into another vocabulary.
    public enum Target: Sendable, Equatable {
        case text(ScoreTextID)
        case note(NoteID)
        /// The tempo marking at the beat of this chord or rest — `ScoreElementID.tempo`'s address.
        case tempo(anchor: VoiceElementID)
    }

    public let target: Target
    public let color: ScoreColor?

    public init(_ target: Target, color: ScoreColor?) {
        self.target = target
        self.color = color
    }

    public var affectedLocation: VoiceElementID {
        switch target {
        case let .note(id): VoiceElementID(id)
        case let .tempo(anchor): anchor
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
            chord.notes.updateNote(at: id.noteIndexInChord) { $0.elementProperties.color = color }
            score[slot] = .chord(chord)
        case let .tempo(anchor):
            guard let slot = SetTempo.slot(at: anchor, in: score),
                  case var .tempo(tempo) = score.systemMeasures[slot.measureIndex].elements[slot.elementIndex]
                      .element
            else { throw Self.refused(.targetNotFound(anchor)) }
            tempo.elementProperties.color = color
            score.systemMeasures.updateValue(at: slot.measureIndex) {
                $0.elements.updateValue(at: slot.elementIndex) { $0.element = .tempo(tempo) }
            }
        }
        return SetElementColor(target, color: old.color)
    }

    /// Nil means the target is absent; a present carrier with an inherited property still returns properties.
    /// The planner must distinguish these so clearing a missing target is refused instead of skipped.
    public static func currentProperties(for target: Target, in score: Score) -> ElementProperties? {
        switch target {
        case let .note(id): return score[id]?.elementProperties
        case let .tempo(anchor): return SetTempo.tempo(at: anchor, in: score)?.elementProperties
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
            chord.lyrics[verse].elementProperties.color = color
            score[anchor] = .chord(chord)
        case let .staffText(anchor, style):
            guard let slot = SetStaffText.laneSlot(
                at: anchor, isSystemText: style == .systemText, in: score,
            ), case var .staffText(mark) = score.systemMeasures[slot.measureIndex].elements[slot.elementIndex].element
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            mark.elementProperties.color = color
            score.systemMeasures.updateValue(at: slot.measureIndex) {
                $0.elements.updateValue(at: slot.elementIndex) { $0.element = .staffText(mark) }
            }
        case let .harmony(anchor):
            guard let slot = SetChordSymbol.harmonySlot(at: anchor, in: score),
                  case var .harmony(harmony)? = score[slot]
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            harmony.elementProperties.color = color
            score[slot] = .harmony(harmony)
        case let .rehearsalMark(index):
            guard score.systemMeasures.indices.contains(index),
                  let slot = RehearsalMarkLane.markIndex(in: score.systemMeasures[index]),
                  case var .rehearsalMark(mark) = score.systemMeasures[index].elements[slot].element
            else { throw Self.refused(.targetNotFound(affectedLocation)) }
            mark.elementProperties.color = color
            score.systemMeasures.updateValue(at: index) {
                $0.elements.updateValue(at: slot) { $0.element = .rehearsalMark(mark) }
            }
        }
    }
}
