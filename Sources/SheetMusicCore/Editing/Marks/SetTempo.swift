import SheetMusicFoundation

/// Writes, replaces or (with `nil`) removes the tempo marking at the beat of the chord or rest at `anchor` —
/// MuseScore's tempo palette drop, and the "nil clears" convention of spec 2026-09-02 §3.1.
///
/// A tempo is a SYSTEM element (`Score.systemMeasures`), addressed here by the timed element it sits on
/// (§2.3, `SystemLaneSlot.position`). The write mutates a tempo already at that beat in place — bps, beat and
/// dots change, its offsets, font overrides and visibility do not — and collapses any further tempo at the same
/// beat, so that the read, the write and the removal agree on which tempo "the one here" is. A fresh tempo is
/// written with `originalStaff` nil. The removal drops every tempo at the beat, and is refused when there is none.
///
/// ## The inverse
///
/// The write may have PADDED an empty lane out to the score's measure count on its way in, so the inverse carries
/// the whole pre-image lane, restored verbatim by `init(restoringLane:anchor:)` — the `SetRehearsalMark` idiom.
public struct SetTempo: EditCommand {
    /// What a tempo marking says: `beatsPerSecond` (the model's and `<tempo>`'s unit, quarter-normalized) and
    /// the beat it is printed in. Everything a host edits, and nothing about how the mark is drawn.
    public struct Marking: Hashable, Sendable {
        public var beatsPerSecond: Double
        public var beatNote: NoteDuration
        public var beatDots: Int

        public init(beatsPerSecond: Double, beatNote: NoteDuration = .quarter, beatDots: Int = 0) {
            self.beatsPerSecond = beatsPerSecond
            self.beatNote = beatNote
            self.beatDots = beatDots
        }
    }

    public let anchor: VoiceElementID
    /// The marking to write, or `nil` to remove the tempo at the anchor's beat. Ignored on the restore path.
    public let marking: Marking?
    let restoredLane: IdentifiedArray<SystemMeasure>?

    public init(anchor: VoiceElementID, marking: Marking?) {
        self.anchor = anchor
        self.marking = marking
        restoredLane = nil
    }

    init(restoringLane lane: IdentifiedArray<SystemMeasure>, anchor: VoiceElementID) {
        self.anchor = anchor
        marking = nil
        restoredLane = lane
    }

    public var affectedLocation: VoiceElementID {
        anchor
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        // The restore branch is decided BEFORE the anchor is resolved — `SetRehearsalMark.apply`'s shape. The
        // pre-image lane is a whole-score value that needs no beat, and an inverse that refused because a later
        // edit had moved the anchor's element would leave an undo stuck.
        let previous = score.systemMeasures
        if let restoredLane {
            score.systemMeasures = restoredLane
            return SetTempo(restoringLane: previous, anchor: anchor)
        }
        guard let position = SystemLaneSlot.position(of: anchor, in: score) else {
            throw Self.refused(.targetNotFound(anchor))
        }
        if let marking {
            RehearsalMarkLane.pad(&score, ids: &ids)
            score.systemMeasures.updateValue(at: anchor.measureIndex) {
                Self.write(marking, at: position, into: &$0, ids: &ids)
            }
        } else {
            // Decided against the untouched score, before anything is written — `RemoveRehearsalMark`'s order.
            guard Self.current(at: anchor, in: score) != nil else { throw Self.refused(.targetNotFound(anchor)) }
            score.systemMeasures.updateValue(at: anchor.measureIndex) { measure in
                measure.elements.removeAll {
                    $0.position == position && Self.isTempo($0)
                }
            }
        }
        return SetTempo(restoringLane: previous, anchor: anchor)
    }

    /// The marking at the anchor's beat, or `nil` when there is none (or the anchor does not resolve).
    ///
    /// Public because a host editing a marking has to show what it currently says — folino's tempo popover puts a
    /// BPM field on the selected marking and writes the edited number back through `SetTempo`, preserving the beat
    /// note this read hands it.
    public static func current(at anchor: VoiceElementID, in score: Score) -> Marking? {
        guard let tempo = tempo(at: anchor, in: score) else { return nil }
        return Marking(beatsPerSecond: tempo.beatsPerSecond, beatNote: tempo.beatNote, beatDots: tempo.beatDots)
    }

    /// The whole tempo at the anchor's beat — the one `current` reads the marking from, and the one the
    /// color and font writes (`SetElementColor.Target.tempo`, `SetTempoFont`) address.
    static func tempo(at anchor: VoiceElementID, in score: Score) -> Tempo? {
        guard let slot = slot(at: anchor, in: score),
              case let .tempo(tempo) = score.systemMeasures[slot.measureIndex].elements[slot.elementIndex].element
        else { return nil }
        return tempo
    }

    /// Where that tempo sits in the lane: its bar, and its index within that bar's elements. `nil` when the beat
    /// carries no tempo or the anchor does not resolve.
    static func slot(at anchor: VoiceElementID, in score: Score) -> (measureIndex: Int, elementIndex: Int)? {
        guard let position = SystemLaneSlot.position(of: anchor, in: score),
              let measure = score[system: MeasureRef(measureIndex: anchor.measureIndex)],
              let index = SystemLaneSlot.firstIndex(in: measure, at: position, where: isTempo)
        else { return nil }
        return (anchor.measureIndex, index)
    }

    static func isTempo(_ positioned: PositionedSystemElement) -> Bool {
        if case .tempo = positioned.element { true } else { false }
    }

    private static func write(
        _ marking: Marking, at position: MeasurePosition, into measure: inout SystemMeasure, ids: inout EIDAllocator,
    ) {
        if let index = SystemLaneSlot.firstIndex(in: measure, at: position, where: isTempo),
           case var .tempo(existing) = measure.elements[index].element
        {
            existing.beatsPerSecond = marking.beatsPerSecond
            existing.beatNote = marking.beatNote
            existing.beatDots = marking.beatDots
            measure.elements.updateValue(at: index) { $0.element = .tempo(existing) }
            for duplicate in measure.elements.indices.reversed() where duplicate > index {
                let element = measure.elements[duplicate]
                if element.position == position, isTempo(element) {
                    measure.elements.removeSubrange(duplicate ..< duplicate + 1)
                }
            }
            return
        }
        measure.elements.insert(
            PositionedSystemElement(
                position: position,
                element: .tempo(Tempo(
                    beatsPerSecond: marking.beatsPerSecond, beatNote: marking.beatNote, beatDots: marking.beatDots,
                )),
            ),
            at: SystemLaneSlot.insertionIndex(in: measure, for: position),
            id: ids.next(),
        )
    }
}
