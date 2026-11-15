import SheetMusicFoundation

extension ScoreItemID {
    // This identity with every staff it names passed through `transform`, and everything else — bar, voice, slot,
    // note, verse, kind — left alone: what a host needs to keep a selection on the same music once the parts have
    // been renumbered (`MovePart`, `RemovePart`, `AddPart`). `nil` when `transform` answers `nil` for a staff the
    // identity names, which is a staff that is gone.
    //
    // A rehearsal mark and a barline pass through: each is addressed by its bar and names no staff of its own
    // (`ScoreItemID.staff` derives the top staff for them). A tie maps both ends, and a part name its part.
    //
    // A score-wide lane mark — a tempo, a system text, a system swing — maps like any other, so its anchor still
    // names the same chord, which is a chord at the same beat; the mark itself may have stayed where it was (a top
    // staff's system object stays on top through `MovePart`). `SystemLaneSlot.anchor(at:measureIndex:in:)` is the
    // anchor layout reports for it, for a host that wants the very identity a tap would give.
    //
    // Not optimized on Windows, for `mappingVoiceElements(_:)`'s reason: the same shape of switch is what the
    // assertion-enabled Windows toolchain's `DebugInfoVerifier` rejected there.
    #if os(Windows)
        @_optimize(none)
    #endif
    public func mappingStaves(_ transform: (StaffAddress) -> StaffAddress?) -> ScoreItemID? {
        func slot(_ id: VoiceElementID) -> VoiceElementID? {
            transform(id.staff).map {
                VoiceElementID(
                    staff: $0, measureIndex: id.measureIndex, voiceIndex: id.voiceIndex, elementIndex: id.elementIndex,
                )
            }
        }
        func note(_ id: NoteID) -> NoteID? {
            transform(id.staff).map {
                NoteID(
                    staff: $0, measureIndex: id.measureIndex, voiceIndex: id.voiceIndex,
                    elementIndex: id.elementIndex, noteIndexInChord: id.noteIndexInChord,
                )
            }
        }
        switch self {
        case let .note(id):
            return note(id).map(Self.note)
        case let .rest(id):
            return transform(id.staff).map {
                .rest(RestID(
                    staff: $0, measureIndex: id.measureIndex, voiceIndex: id.voiceIndex, elementIndex: id.elementIndex,
                ))
            }
        case let .tuplet(id):
            return transform(id.staff).map {
                .tuplet(TupletID(
                    staff: $0, measureIndex: id.measureIndex, voiceIndex: id.voiceIndex,
                    startElementIndex: id.startElementIndex,
                ))
            }
        case let .graceNote(id):
            return slot(id.parent).map { .graceNote(id.withParent($0)) }
        case let .clef(anchor):
            switch anchor {
            case let .explicit(id): return slot(id).map { .clef(.explicit($0)) }
            case let .staffDefault(staff): return transform(staff).map { .clef(.staffDefault($0)) }
            case let .restatement(staff, measureIndex):
                return transform(staff).map { .clef(.restatement(staff: $0, measureIndex: measureIndex)) }
            }
        case let .text(text):
            switch text {
            case let .lyric(anchor, verse): return slot(anchor).map { .text(.lyric(anchor: $0, verse: verse)) }
            case let .staffText(anchor, style):
                return slot(anchor).map { .text(.staffText(anchor: $0, style: style)) }
            case let .harmony(anchor): return slot(anchor).map { .text(.harmony(anchor: $0)) }
            case .rehearsalMark: return self
            }
        case let .element(element):
            return element.mappingStaves(transform, slot: slot, note: note).map(Self.element)
        }
    }
}

extension ScoreElementID {
    fileprivate func mappingStaves(
        _ transform: (StaffAddress) -> StaffAddress?,
        slot: (VoiceElementID) -> VoiceElementID?,
        note: (NoteID) -> NoteID?,
    ) -> ScoreElementID? {
        switch self {
        case let .dynamic(anchor): slot(anchor).map { .dynamic(anchor: $0) }
        case let .fermata(anchor): slot(anchor).map { .fermata(anchor: $0) }
        case let .breath(anchor): slot(anchor).map { .breath(anchor: $0) }
        case let .tempo(anchor): slot(anchor).map { .tempo(anchor: $0) }
        case let .swing(anchor): slot(anchor).map { .swing(anchor: $0) }
        case let .arpeggio(anchor): slot(anchor).map { .arpeggio(anchor: $0) }
        case let .chordLine(anchor): slot(anchor).map { .chordLine(anchor: $0) }
        case let .tremolo(anchor): slot(anchor).map { .tremolo(anchor: $0) }
        case let .spanner(anchor, kind): slot(anchor).map { .spanner(anchor: $0, kind: kind) }
        case let .articulation(anchor, kind): slot(anchor).map { .articulation(anchor: $0, kind: kind) }
        case let .slur(.chord(anchor, ordinal)): slot(anchor).map { .slur(.chord(anchor: $0, ordinal: ordinal)) }
        case let .slur(.voice(anchor)): slot(anchor).map { .slur(.voice($0)) }
        case let .glissando(start): note(start).map { .glissando(start: $0) }
        case let .tie(start, end):
            note(start).flatMap { start in note(end).map { .tie(start: start, end: $0) } }
        case let .jump(staff, measureIndex, index):
            transform(staff).map { .jump(staff: $0, measureIndex: measureIndex, index: index) }
        case let .marker(staff, measureIndex, index):
            transform(staff).map { .marker(staff: $0, measureIndex: measureIndex, index: index) }
        case let .keySignature(measureIndex, staff):
            transform(staff).map { .keySignature(measureIndex: measureIndex, staff: $0) }
        case let .timeSignature(measureIndex, staff):
            transform(staff).map { .timeSignature(measureIndex: measureIndex, staff: $0) }
        case let .partName(partIndex, form):
            transform(StaffAddress(partIndex: partIndex, staffIndexInPart: 0)).map {
                .partName(partIndex: $0.partIndex, form: form)
            }
        case .barLine: self
        }
    }
}
