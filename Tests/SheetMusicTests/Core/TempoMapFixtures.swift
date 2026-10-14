@testable import SheetMusicCore

/// Scores for the tempo-map suites: one 4/4 staff at division 480 — quarter rests, or a middle C per beat when a MIDI
/// suite needs onsets to time — and a system lane given as `(measure, quarter, element)` entries.
enum TempoMapFixtures {
    struct LaneEntry {
        let measure: Int
        let quarter: Int
        let element: SystemElement
    }

    static func tempo(_ measure: Int, _ quarter: Int, _ tempo: Tempo) -> LaneEntry {
        LaneEntry(measure: measure, quarter: quarter, element: .tempo(tempo))
    }

    static func score(measures: Int, lane: [LaneEntry] = [], notes: Bool = false) -> Score {
        let beat: VoiceElement = notes
            ? .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)])))
            : .rest(duration: .quarter)
        let bars = (0 ..< measures).map { index -> Measure in
            let meter: [VoiceElement] = index == 0 ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))] : []
            return Measure(voices: [Voice(elements: meter + Array(repeating: beat, count: 4))])
        }
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: bars)])
        let systemMeasures = (0 ..< measures).map { index in
            SystemMeasure(elements: lane.filter { $0.measure == index }.map { entry in
                PositionedSystemElement(
                    position: MeasurePosition(numerator: entry.quarter, denominator: 4), element: entry.element,
                )
            })
        }
        return Score(division: 480, parts: [part], systemMeasures: IdentifiedArray(systemMeasures))
    }
}
