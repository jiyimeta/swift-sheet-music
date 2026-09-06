import SheetMusicFoundation

/// Lexicographic (measure, tick-in-measure) onset used to order elements across a score. Internal: the public
/// surface is `Score.items(inRangeFrom:to:)` and `Score.voiceElements(in:)`, which both rank onsets with it.
struct ScoreTickPosition: Comparable, Hashable {
    let measure: Int
    let tick: Int

    static func < (lhs: ScoreTickPosition, rhs: ScoreTickPosition) -> Bool {
        if lhs.measure != rhs.measure { return lhs.measure < rhs.measure }
        return lhs.tick < rhs.tick
    }
}

extension VoiceElement {
    /// How far this element moves a voice's running tick: a chord or rest by its resolved duration, a
    /// `.locationShift` by the jog's delta, everything else not at all.
    ///
    /// The `.locationShift` case is what makes every walker in the package agree. MuseScore's reader keeps ONE
    /// tick per voice and `<location>` moves it (`ReadContext::setLocation`), so the MSCX encoder's write cursor
    /// (`advanceWriteCursor`), `Score+FermataHolds`, `LayoutEngine+Spanners` and the MIDI renderer all fold the
    /// delta in. A walker that summed durations alone would describe a beat the file is not positioned at, and a
    /// lane mark anchored through `SystemLaneSlot.position` would land there.
    func cursorAdvance(division: Int, in measureDuration: Fraction) -> Int {
        switch self {
        case let .chord(chord):
            chord.duration.resolved(in: measureDuration).ticks(division: division)
        case let .locationShift(delta):
            delta.ticks(division: division)
        default:
            0
        }
    }
}

extension Score {
    /// Running tick from the start of `id`'s staff to the element's onset, or `nil` when the path does not resolve.
    func absoluteTick(of id: VoiceElementID) -> Int? {
        guard let position = onset(of: id), let staff = self[id.staff] else { return nil }
        let durations = staff.measures.effectiveMeasureDurations()
        guard durations.indices.contains(id.measureIndex) else { return nil }
        let precedingTicks = durations[..<id.measureIndex].reduce(0) {
            $0 + $1.ticks(division: division)
        }
        return precedingTicks + position.tick
    }

    /// Onset of the element at `id`: the running tick of its voice at that slot — the resolved durations of the
    /// chords before it plus any `.locationShift` jogs among them. `nil` when the path does not resolve.
    func onset(of id: VoiceElementID) -> ScoreTickPosition? {
        guard let voice = self[voice: VoiceRef(id)], voice.elements.indices.contains(id.elementIndex),
              let staff = self[id.staff]
        else { return nil }
        let measureDuration = staff.measures.effectiveMeasureDurations()[id.measureIndex]
        var tick = 0
        for element in voice.elements[..<id.elementIndex] {
            tick += element.cursorAdvance(division: division, in: measureDuration)
        }
        return ScoreTickPosition(measure: id.measureIndex, tick: tick)
    }

    /// One element-width past `id`: the onset plus what the element itself advances the cursor by — its resolved
    /// duration for a chord or rest, the jog for a `.locationShift`, nothing for a non-timed one. Equivalently,
    /// the onset of whatever follows `id` in the voice.
    func end(of id: VoiceElementID) -> ScoreTickPosition? {
        guard let start = onset(of: id), let staff = self[id.staff], let element = self[id] else { return nil }
        let measureDuration = staff.measures.effectiveMeasureDurations()[id.measureIndex]
        let ticks = element.cursorAdvance(division: division, in: measureDuration)
        return ScoreTickPosition(measure: start.measure, tick: start.tick + ticks)
    }
}
