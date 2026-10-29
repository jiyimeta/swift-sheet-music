@testable import SheetMusicAudioCore
import SheetMusicCore
import Testing

struct UnrolledTimeMapParkTests {
    /// `|: A :| B`, one whole note a measure at 120 BPM: A plays at 0 and 2 s, B at 4 s; B is notated at 2 s.
    private static func repeatThenB() -> PlaybackScoreDerivation {
        func measure(repeated: Bool) -> Measure {
            Measure(
                voices: [Voice(elements: [.chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))])],
                startRepeat: repeated, endRepeatCount: repeated ? 2 : nil,
            )
        }
        let part = Part(
            id: "P0", instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: [measure(repeated: true), measure(repeated: false)])],
        )
        let tempo = SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2))),
        ])
        let measures = IdentifiedArray([tempo, SystemMeasure()])
        return PreparedPlayback.derive(
            score: Score(division: 480, parts: [part], systemMeasures: measures, metaTags: [:]),
        )
    }

    /// Half a tick at 120 BPM, division 480.
    private static let halfTick = 0.5 * 0.5 / 480

    @Test
    func `the downbeat after a repeat parks half a tick before it, not at the end of the repeat's first pass`() {
        let derivation = Self.repeatThenB()
        let park = derivation.unrolledTimeMap.park(atTick: 1920, timeline: derivation.timeline)
        #expect(abs(park.onset - 4) < 1e-12)
        #expect(abs(park.parked - (4 - Self.halfTick)) < 1e-12)
    }

    @Test
    func `inside a measure-play and at the top the park is half a tick before the onset`() {
        let derivation = Self.repeatThenB()
        let map = derivation.unrolledTimeMap
        let insideB = map.park(atTick: 2400, timeline: derivation.timeline)
        #expect(abs(insideB.onset - 4.5) < 1e-12)
        #expect(abs(insideB.parked - (4.5 - Self.halfTick)) < 1e-12)
        let insideA = map.park(atTick: 480, timeline: derivation.timeline)
        #expect(abs(insideA.parked - (0.5 - Self.halfTick)) < 1e-12)
        // Nothing comes before the first onset, so the top parks on it.
        let top = map.park(atTick: 0, timeline: derivation.timeline)
        #expect(top.parked == 0)
        #expect(top.onset == 0)
    }
}
