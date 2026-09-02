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

extension Score {
    /// Onset of the element at `id`: the sum of the resolved durations of the chords before it in its voice.
    /// `nil` when the path does not resolve. Non-timed elements and `.locationShift` do not advance the cursor —
    /// the same rule `items(inRangeFrom:to:)` has always applied.
    func onset(of id: VoiceElementID) -> ScoreTickPosition? {
        guard let voice = self[voice: VoiceRef(id)], voice.elements.indices.contains(id.elementIndex),
              let staff = self[id.staff]
        else { return nil }
        let measureDuration = staff.measures.effectiveMeasureDurations()[id.measureIndex]
        var tick = 0
        for element in voice.elements[..<id.elementIndex] {
            if case let .chord(chord) = element {
                tick += chord.duration.resolved(in: measureDuration).ticks(division: division)
            }
        }
        return ScoreTickPosition(measure: id.measureIndex, tick: tick)
    }

    /// One element-width past `id`: the onset plus the element's own resolved ticks (zero for a non-timed one).
    func end(of id: VoiceElementID) -> ScoreTickPosition? {
        guard let start = onset(of: id), let staff = self[id.staff], let element = self[id] else { return nil }
        let measureDuration = staff.measures.effectiveMeasureDurations()[id.measureIndex]
        var ticks = 0
        if case let .chord(chord) = element {
            ticks = chord.duration.resolved(in: measureDuration).ticks(division: division)
        }
        return ScoreTickPosition(measure: start.measure, tick: start.tick + ticks)
    }
}
