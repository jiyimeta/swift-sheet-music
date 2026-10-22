import SheetMusicFoundation

/// Writes, replaces or (with `nil`) removes the tempo marking at the beat of the chord or rest at `anchor` —
/// MuseScore's tempo palette drop, and the "nil clears" convention of spec 2026-09-02 §3.1.
///
/// A tempo is a SYSTEM element (`Score.systemMeasures`), addressed here by the timed element it sits on
/// (§2.3, `SystemLaneSlot.position`). The write mutates a tempo already at that beat in place — bps, beat and
/// dots change, its offsets, font overrides and visibility do not — and collapses any further tempo at the same
/// beat, so that the read, the write and the removal agree on which tempo "the one here" is. A fresh tempo is
/// written with `originalStaff` nil. The removal drops every tempo at the beat, and is refused when there is none.
/// The write also sets `<play>` when the marking says, and the text as `Marking.text` says; a new number under
/// `.keep` edits the words as `Tempo.applyNumberEdit()` describes.
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
        public var text: TextEdit
        public var playsBack: Bool?
        /// Whether the number and beat were edited: `true` writes them (and edits the words), `false` leaves them
        /// alone, `nil` infers it by comparing with what `SetTempo.current` reports where the write is applied. The
        /// inference differs between replicas when an earlier tempo changed before a replay, so a host stamps the
        /// sender's intent with `SetTempo.stamped(_:at:in:)`; `nil` is what an older sender's intent carries.
        public var numberEdit: Bool?
        /// MuseScore `<type>` to write, or `nil` to leave it (a `.derive` text still makes it `.normal`, and a number
        /// edit under `.keep` still does as `Tempo.applyNumberEdit()` says). Set, it wins over both: a host pasting a
        /// copied "a tempo" writes the marking it copied, not an ordinary one that happens to say "a tempo".
        public var textType: TempoTextType?
        /// MuseScore `<followText>` to write, or `nil` to leave it — set, it wins over a `.derive` text as `textType`
        /// does.
        public var followText: Bool?

        /// What a write does to the marking's text.
        public enum TextEdit: Hashable, Sendable {
            /// Leave the words; a new number or beat then edits them as MuseScore's would read them
            /// (`Tempo.applyNumberEdit`).
            case keep
            /// Make the text derived: the marking prints its beat and number (`Tempo.metronomeMarking`).
            case derive
            /// Replace the text with this plain text.
            case set(String)
        }

        public init(
            beatsPerSecond: Double, beatNote: NoteDuration = .quarter, beatDots: Int = 0,
            text: TextEdit = .keep, playsBack: Bool? = nil, numberEdit: Bool? = nil,
            textType: TempoTextType? = nil, followText: Bool? = nil,
        ) {
            self.numberEdit = numberEdit
            self.textType = textType
            self.followText = followText
            self.beatsPerSecond = beatsPerSecond
            self.beatNote = beatNote
            self.beatDots = beatDots
            self.text = text
            self.playsBack = playsBack
        }

        /// The number in the marking's own beat — what it prints (`Tempo.beatsPerMinute`). Setting it keeps the beat.
        public var beatsPerMinute: Double {
            get { beatsPerSecond * 60 / Tempo.lengthInQuarters(of: beatNote, dots: beatDots) }
            set { beatsPerSecond = newValue * Tempo.lengthInQuarters(of: beatNote, dots: beatDots) / 60 }
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
            // What the host was shown, read before the lane is padded or written: a marking is compared with this, not
            // with the stored tempo, to tell a number edit from one that only toggles `playsBack`.
            let reported = Self.current(at: anchor, in: score)
            RehearsalMarkLane.pad(&score, ids: &ids)
            score.systemMeasures.updateValue(at: anchor.measureIndex) {
                Self.write(marking, reported: reported, at: position, into: &$0, ids: &ids)
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

    /// The marking at the anchor's beat as it plays, or `nil` when the beat carries none (or the anchor does not
    /// resolve): an "a tempo" or "tempo primo" that follows its text reads the tempo it reinstates — the tempo map's
    /// point there, in that tempo's beat — and every other marking its own number and beat. `text` is `.keep`;
    /// `playsBack` is `nil` while the marking plays and `false` when it does not, so a host that copies this, edits the
    /// number and writes it back changes nothing else, and one that changes nothing writes an equal marking — the
    /// planner's no-op test (`ScoreEditSession+MarkPlanning.swift`).
    ///
    /// Public because a host editing a marking has to show what it currently says — folino's tempo popover puts a
    /// BPM field on the selected marking and writes the edited number back through `SetTempo`, preserving the beat
    /// note this read hands it.
    public static func current(at anchor: VoiceElementID, in score: Score) -> Marking? {
        guard let tempo = tempo(at: anchor, in: score) else { return nil }
        let playsBack: Bool? = tempo.playsBack ? nil : false
        if tempo.followText, tempo.textType != .normal, var point = inForce(at: anchor, in: score) {
            point.playsBack = playsBack
            return point
        }
        return Marking(
            beatsPerSecond: tempo.beatsPerSecond, beatNote: tempo.beatNote, beatDots: tempo.beatDots,
            playsBack: playsBack,
        )
    }

    /// `marking` with `numberEdit` set from what the host changed relative to what `current` reports at the anchor —
    /// call it on the sender, before the intent is made, so every replica applies the edit the sender meant.
    public static func stamped(_ marking: Marking, at anchor: VoiceElementID, in score: Score) -> Marking {
        var stamped = marking
        stamped.numberEdit = current(at: anchor, in: score).map {
            $0.beatsPerSecond != marking.beatsPerSecond || $0.beatNote != marking.beatNote
                || $0.beatDots != marking.beatDots
        } ?? true
        return stamped
    }

    /// The marking that writes `tempo` as it stands — its stored number and beat (not the tempo an "a tempo"
    /// reinstates), its words, `<type>`, `<followText>` and `<play>` — so a paste writes the marking that was copied.
    /// The text's markup, offsets, font, color and visibility are not part of a marking and are not carried.
    public static func marking(copying tempo: Tempo) -> Marking {
        Marking(
            beatsPerSecond: tempo.beatsPerSecond, beatNote: tempo.beatNote, beatDots: tempo.beatDots,
            text: tempo.text.map(Marking.TextEdit.set) ?? .derive, playsBack: tempo.playsBack, numberEdit: true,
            textType: tempo.textType, followText: tempo.followText,
        )
    }

    /// What plays at the anchor's beat, as a marking a host can show and write — the tempo map's point in force there
    /// (`Score.resolvedTempoMap()`), its number and beat; `nil` before the first point or when the anchor does not
    /// resolve. A caret on a beat with no marking shows this.
    public static func inForce(at anchor: VoiceElementID, in score: Score) -> Marking? {
        guard let position = SystemLaneSlot.position(of: anchor, in: score),
              let point = score.resolvedTempoMap().point(
                  inForceAtMeasure: anchor.measureIndex, tickInMeasure: position.ticks(division: score.division),
              )
        else { return nil }
        return Marking(beatsPerSecond: point.beatsPerSecond, beatNote: point.beatNote, beatDots: point.beatDots)
    }

    /// The whole tempo at the anchor's beat — the one `current` reads the marking from, and the one the
    /// color and font writes (`SetElementColor.Target.tempo`, `SetTempoFont`) address.
    ///
    /// Public because `current` reads a marking AS IT PLAYS, which is not what a copy needs: an "a tempo" reads as
    /// the tempo it reinstates, and the words, `<type>` and `<followText>` are not in it. folino's ⌘C reads this and
    /// pastes it through `marking(copying:)`.
    public static func tempo(at anchor: VoiceElementID, in score: Score) -> Tempo? {
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
        _ marking: Marking, reported: Marking?, at position: MeasurePosition, into measure: inout SystemMeasure,
        ids: inout EIDAllocator,
    ) {
        if let index = SystemLaneSlot.firstIndex(in: measure, at: position, where: isTempo),
           case var .tempo(existing) = measure.elements[index].element
        {
            existing.apply(marking, reported: reported)
            measure.elements.updateValue(at: index) { $0.element = .tempo(existing) }
            for duplicate in measure.elements.indices.reversed() where duplicate > index {
                let element = measure.elements[duplicate]
                if element.position == position, isTempo(element) {
                    measure.elements.removeSubrange(duplicate ..< duplicate + 1)
                }
            }
            return
        }
        var fresh = Tempo(
            beatsPerSecond: marking.beatsPerSecond, beatNote: marking.beatNote, beatDots: marking.beatDots,
        )
        fresh.apply(marking)
        measure.elements.insert(
            PositionedSystemElement(position: position, element: .tempo(fresh)),
            at: SystemLaneSlot.insertionIndex(in: measure, for: position),
            id: ids.next(),
        )
    }
}
