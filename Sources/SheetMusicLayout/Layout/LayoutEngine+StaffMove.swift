#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// A chord or rest written on one staff and drawn on a sibling staff of its part (`Chord.staffMove`), as that staff's
/// placement needs it. MuseScore positions such a chord against the TARGET staff's clef (`Note::updateRelLine`,
/// `dom/note.cpp:2913-2922`) and draws it, with its stem, flag, dots, accidentals and articulations, on that staff
/// (`ChordRest::vStaffIdx`, `dom/chordrest.h:231`; `EngravingItem::pagePos`, `dom/engravingitem.cpp:742-779`).
struct MovedChordPlacement: Hashable {
    /// The effective move (`Part.effectiveStaffMove`): +1 the staff below, −1 the staff above.
    let staffMove: Int
    /// The clef in force on the target staff at the chord's tick.
    let clef: NotatedClef
}

/// One slot of a staff's measure: a voice and an element index in it.
struct VoiceSlot: Hashable {
    let voiceIndex: Int
    let elementIndex: Int
}

extension LayoutEngine {
    /// The chords and rests of staff `staffIndexInPart`'s measure drawn on a sibling staff, keyed by their slot, each
    /// with the target staff's clef at the chord's tick. Empty — the usual case — when nothing in the measure moves.
    ///
    /// `targetClefAtStart` answers the clef in force on a sibling staff at the start of the measure (by its index in
    /// the part); `targetMeasure` that staff's measure, whose clef changes up to the chord's tick apply, as they do
    /// for the staff's own notes.
    static func movedChords(
        in measure: Measure,
        staffIndexInPart: Int,
        of part: Part,
        measureDuration: Fraction,
        division: Int,
        targetClefAtStart: (Int) -> NotatedClef?,
        targetMeasure: (Int) -> Measure?,
    ) -> [VoiceSlot: MovedChordPlacement] {
        guard part.staves.count > 1 else { return [:] }
        var moved: [VoiceSlot: MovedChordPlacement] = [:]
        for (voiceIndex, voice) in measure.voices.enumerated() {
            var tick = 0
            for (elementIndex, element) in voice.elements.enumerated() {
                switch element {
                case let .chord(chord):
                    let move = part.effectiveStaffMove(chord.staffMove, fromStaff: staffIndexInPart)
                    if move != 0, let start = targetClefAtStart(staffIndexInPart + move) {
                        let clef = clefInForce(
                            atTick: tick, startingWith: start,
                            in: targetMeasure(staffIndexInPart + move),
                            measureDuration: measureDuration, division: division,
                        )
                        moved[VoiceSlot(voiceIndex: voiceIndex, elementIndex: elementIndex)] =
                            MovedChordPlacement(staffMove: move, clef: clef)
                    }
                    tick += chord.duration.resolved(in: measureDuration).ticks(division: division)
                case let .locationShift(delta):
                    tick += delta.ticks(division: division)
                default:
                    break
                }
            }
        }
        return moved
    }

    /// The clef in force at `tick` of `measure`: `start`, changed by every clef the measure's first voice declares at
    /// or before that tick — the voice placement takes a staff's clef changes from.
    static func clefInForce(
        atTick tick: Int, startingWith start: NotatedClef, in measure: Measure?,
        measureDuration: Fraction, division: Int,
    ) -> NotatedClef {
        guard let voice = measure?.voices.first else { return start }
        var clef = start
        var cursor = 0
        for element in voice.elements {
            guard cursor <= tick else { break }
            switch element {
            case let .clef(declared):
                clef = NotatedClef(rawType: declared.concertClefType)
            case let .chord(chord):
                cursor += chord.duration.resolved(in: measureDuration).ticks(division: division)
            case let .locationShift(delta):
                cursor += delta.ticks(division: division)
            default:
                break
            }
        }
        return clef
    }

    /// The direction MuseScore gives a moved chord's stem when nothing above it in `ChordLayout::computeUp`'s order —
    /// an explicit direction, a beam, a two-note tremolo, several voices on its own staff, a grace — decides: up when
    /// it moved down, down when it moved up (`rendering/score/chordlayout.cpp:1564-1600`), so the stem points back
    /// toward the staff the chord belongs to.
    static func movedStemDirection(_ moved: MovedChordPlacement?) -> StemDirection? {
        guard let moved else { return nil }
        return moved.staffMove > 0 ? .up : .down
    }

    /// The slot an element of a staff's placement belongs to, when it belongs to one chord or rest of that staff and is
    /// drawn with it: the chord itself, its rest glyph, and the marks that are the chord's children in MuseScore
    /// (articulations, tremolo bars, arpeggio, chord line). Lyrics, graces, beams, ties and the segment's marks
    /// (fermata, breath) answer nil: a lyric and a segment mark stay on the staff they are written on, a grace has a
    /// move of its own, and beams and ties are placed by passes that know their members.
    static func ownerSlot(of element: LayoutElement) -> VoiceSlot? {
        func slot(_ id: VoiceElementID?) -> VoiceSlot? {
            id.map { VoiceSlot(voiceIndex: $0.voiceIndex, elementIndex: $0.elementIndex) }
        }
        switch element {
        case let .chord(notes, _, _, _, _, _, _, _, _, _, _):
            return notes.first.map { VoiceSlot(voiceIndex: $0.noteID.voiceIndex, elementIndex: $0.noteID.elementIndex) }
        case let .rest(_, _, _, restID, _):
            return VoiceSlot(voiceIndex: restID.voiceIndex, elementIndex: restID.elementIndex)
        case let .articulation(_, _, _, anchor):
            return slot(anchor)
        case let .tremoloBars(_, _, owner):
            return slot(owner)
        case let .arpeggioWiggle(_, _, _, anchor):
            return slot(anchor)
        case let .chordLine(_, _, _, anchor):
            return slot(anchor)
        default:
            return nil
        }
    }

    /// Hands each staff's elements drawn on a sibling staff (`relocations`: by flat staff index, element index → move)
    /// to that staff's buffer. Placement put them in the target's own frame, so they are appended as they are; the
    /// target's ledger lines, vertical extent and translation then follow from its buffer. An element whose target has
    /// no buffer in this measure stays where it was. Indices are read against the buffers as placement left them.
    static func relocateMovedElements(
        _ relocations: [Int: [Int: Int]],
        in buffers: inout [Int: [LayoutElement]],
        addressOf: (Int) -> StaffAddress,
        flatIndex: (StaffAddress) -> Int?,
    ) {
        guard !relocations.isEmpty else { return }
        let original = buffers
        var arriving: [Int: [LayoutElement]] = [:]
        for source in relocations.keys.sorted() {
            guard let moves = relocations[source], let elements = original[source] else { continue }
            let home = addressOf(source)
            var kept: [LayoutElement] = []
            for (index, element) in elements.enumerated() {
                if let move = moves[index],
                   let target = flatIndex(StaffAddress(
                       partIndex: home.partIndex, staffIndexInPart: home.staffIndexInPart + move,
                   )),
                   original[target] != nil
                {
                    arriving[target, default: []].append(element)
                } else {
                    kept.append(element)
                }
            }
            buffers[source] = kept
        }
        for target in arriving.keys.sorted() {
            buffers[target, default: []].append(contentsOf: arriving[target] ?? [])
        }
    }

    /// For each element of `elements` drawn on a sibling staff, its index and that staff's move — the chords and rests
    /// in `moved` and the marks drawn with them (`ownerSlot`), plus `beamIndices`, the beams of groups whose every
    /// member moved alike.
    static func relocations(
        of elements: [LayoutElement], moved: [VoiceSlot: MovedChordPlacement], beamIndices: [Int: Int] = [:],
    ) -> [Int: Int] {
        guard !moved.isEmpty else { return [:] }
        var result = beamIndices
        for (index, element) in elements.enumerated() {
            if let slot = ownerSlot(of: element), let placement = moved[slot] {
                result[index] = placement.staffMove
            }
        }
        return result
    }
}
