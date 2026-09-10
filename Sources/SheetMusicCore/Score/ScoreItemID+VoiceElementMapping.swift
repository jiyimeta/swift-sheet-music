import SheetMusicFoundation

extension ScoreItemID {
    /// Maps owned voice slots while preserving note, verse, articulation, and slur identities.
    /// Bar addresses and staff-owned navigation lists do not own a voice slot.
    func mappingVoiceElements(_ transform: (VoiceElementID) -> VoiceElementID?) -> ScoreItemID? {
        func note(_ id: NoteID) -> NoteID? {
            guard let location = transform(VoiceElementID(id)) else { return nil }
            return NoteID(
                staff: location.staff, measureIndex: location.measureIndex, voiceIndex: location.voiceIndex,
                elementIndex: location.elementIndex, noteIndexInChord: id.noteIndexInChord,
            )
        }
        switch self {
        case let .note(id): return note(id).map(Self.note)
        case let .rest(id):
            guard let location = transform(VoiceElementID(id)) else { return nil }
            return .rest(RestID(
                staff: location.staff, measureIndex: location.measureIndex,
                voiceIndex: location.voiceIndex, elementIndex: location.elementIndex,
            ))
        case let .tuplet(id):
            guard let location = transform(VoiceElementID(
                staff: id.staff, measureIndex: id.measureIndex,
                voiceIndex: id.voiceIndex, elementIndex: id.startElementIndex,
            )) else { return nil }
            return .tuplet(TupletID(
                staff: location.staff, measureIndex: location.measureIndex,
                voiceIndex: location.voiceIndex, startElementIndex: location.elementIndex,
            ))
        case let .clef(.explicit(anchor)):
            return transform(anchor).map { .clef(.explicit($0)) }
        case .clef(.staffDefault), .text(.rehearsalMark): return self
        case let .text(.lyric(anchor, verse)):
            return transform(anchor).map { .text(.lyric(anchor: $0, verse: verse)) }
        case let .text(.staffText(anchor, style)):
            return transform(anchor).map { .text(.staffText(anchor: $0, style: style)) }
        case let .text(.harmony(anchor)):
            return transform(anchor).map { .text(.harmony(anchor: $0)) }
        case let .element(element):
            switch element {
            case let .dynamic(anchor): return transform(anchor).map { .element(.dynamic(anchor: $0)) }
            case let .fermata(anchor): return transform(anchor).map { .element(.fermata(anchor: $0)) }
            case let .breath(anchor): return transform(anchor).map { .element(.breath(anchor: $0)) }
            case let .tempo(anchor): return transform(anchor).map { .element(.tempo(anchor: $0)) }
            case let .spanner(anchor, kind):
                return transform(anchor).map { .element(.spanner(anchor: $0, kind: kind)) }
            case let .articulation(anchor, kind):
                return transform(anchor).map { .element(.articulation(anchor: $0, kind: kind)) }
            case let .tie(start, end):
                guard let start = note(start), let end = note(end) else { return nil }
                return .element(.tie(start: start, end: end))
            case let .slur(.chord(anchor, ordinal)):
                return transform(anchor).map { .element(.slur(.chord(anchor: $0, ordinal: ordinal))) }
            case let .slur(.voice(anchor)):
                return transform(anchor).map { .element(.slur(.voice($0))) }
            case .keySignature, .timeSignature, .barLine, .jump, .marker: return self
            }
        }
    }
}
