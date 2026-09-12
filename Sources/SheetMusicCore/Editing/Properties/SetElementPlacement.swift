import SheetMusicFoundation

/// Writes one carrier's authored placement override; nil restores its styled side.
/// Lyric, staff/system text, rehearsal marks, and harmony resolve the side through
/// the element override, score style, and role default, then retain it through autoplace.
/// Note and chord generic placement is persisted but visually inert: it changes neither
/// pitch nor stem direction.
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
        case let .text(text): TextElementProperties.anchor(of: text)
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
            guard TextElementProperties.update(text, in: &score, { $0.placement = placement }) else {
                throw Self.refused(.targetNotFound(affectedLocation))
            }
        case let .note(id):
            let slot = VoiceElementID(id)
            guard case var .chord(chord)? = score[slot], chord.notes.indices.contains(id.noteIndexInChord)
            else { throw Self.refused(.noteNotFound(id)) }
            chord.notes.updateNote(at: id.noteIndexInChord) { $0.elementProperties.placement = placement }
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
            return TextElementProperties.current(text, in: score)
        }
    }
}
