@testable import SheetMusicAudioCore
import SheetMusicCore
import Testing

struct UnrolledTimeMapBoundaryTests {
    enum Layout: CaseIterable {
        /// `X |: A :| B`: X at the first tempo, A at the second, B at 120.
        case leadInThenRepeat
        /// `|: A1 A2 :| B`: A1 at the first tempo, A2 at the second, B at 120.
        case twoMeasureRepeat
    }

    /// A whole note a 4/4 measure, each measure at its tempo; B's downbeat is notated tick 3840 in both layouts.
    static func derivation(_ layout: Layout, firstBPM: Int, secondBPM: Int) -> PlaybackScoreDerivation {
        func measure(startRepeat: Bool = false, endRepeat: Int? = nil) -> Measure {
            Measure(
                voices: [Voice(elements: [.chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))])],
                startRepeat: startRepeat, endRepeatCount: endRepeat,
            )
        }
        let measures = switch layout {
        case .leadInThenRepeat: [measure(), measure(startRepeat: true, endRepeat: 2), measure()]
        case .twoMeasureRepeat: [measure(startRepeat: true), measure(endRepeat: 2), measure()]
        }
        let part = Part(
            id: "P0", instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        let systemMeasures = [firstBPM, secondBPM, 120].map { bpm in
            SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: Double(bpm) / 60))),
            ])
        }
        return PreparedPlayback.derive(
            score: Score(division: 480, parts: [part], systemMeasures: IdentifiedArray(systemMeasures), metaTags: [:]),
        )
    }

    /// How far B's downbeat projects from the start of B's own measure-play (0 when it lands there).
    static func bOffset(_ layout: Layout, firstBPM: Int, secondBPM: Int) -> Double {
        let derivation = derivation(layout, firstBPM: firstBPM, secondBPM: secondBPM)
        let map = derivation.unrolledTimeMap
        let onset = map.unrolledSeconds(fromNotated: derivation.timeline.seconds(atTick: 3840))
        return onset - (map.spanStartSeconds.last ?? .nan)
    }

    /// The first pair a full 40–240 BPM grid misplaced while a span's notated end was derived from the unrolled axis:
    /// rounding left A's end one ULP past B's notated start, so B's downbeat matched A's first pass and projected a
    /// whole pass early (4.29 s in `X |: A :| B`, 7.98 s in `|: A1 A2 :| B`) — and a seek there replayed the repeat.
    @Test
    func `the downbeat after a measure at 65 BPM and one at 56 lands on B, not a pass early`() {
        for layout in Layout.allCases {
            #expect(abs(Self.bOffset(layout, firstBPM: 65, secondBPM: 56)) < 1e-9, "\(layout)")
            let derivation = Self.derivation(layout, firstBPM: 65, secondBPM: 56)
            let park = derivation.unrolledTimeMap.park(atTick: 3840, timeline: derivation.timeline)
            #expect(park.onset == derivation.unrolledTimeMap.spanStartSeconds.last, "\(layout): what a seek reads")
        }
    }

    /// Around that pair every integer tempo, and over the whole 40–240 BPM range every twentieth.
    @Test
    func `the downbeat after a repeat lands on B across a grid of tempo pairs`() {
        let window = (55 ... 75).flatMap { first in (45 ... 65).map { (first, $0) } }
        let coarse = stride(from: 40, through: 240, by: 20).flatMap { first in
            stride(from: 40, through: 240, by: 20).map { (first, $0) }
        }
        for layout in Layout.allCases {
            let misplaced = (window + coarse).filter {
                abs(Self.bOffset(layout, firstBPM: $0.0, secondBPM: $0.1)) > 1e-9
            }
            #expect(misplaced.isEmpty, "\(layout): \(misplaced.count) pairs, first \(misplaced.prefix(5))")
        }
    }
}
