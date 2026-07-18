import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// `ScoreNavigation` merges navigation facts across staves so ONE
/// playback plan can be shared by every staff: MuseScore replicates
/// repeat barlines/voltas on all staves but writes Jump/Marker only
/// on the top staff.
struct ScoreNavigationTests {
    private static let division = 480

    private static func measure(
        startRepeat: Bool = false,
        endRepeat: Int? = nil,
        markers: [Marker] = [],
        jumps: [Jump] = [],
        sectionBreak: Bool = false,
        volta: [Int]? = nil,
        voltaMeasures: Int = 1,
    ) -> Measure {
        var elements: [VoiceElement] = []
        if let volta {
            elements.append(.spanner(Spanner(
                kind: .volta, rawType: "Volta",
                nextMeasuresOffset: voltaMeasures, voltaEndings: volta,
            )))
        }
        elements.append(.chord(Chord(
            duration: .whole,
            notes: [Note(pitch: 60, tpc: 14)],
        )))
        return Measure(
            voices: [Voice(elements: elements)],
            startRepeat: startRepeat,
            endRepeatCount: endRepeat,
            markers: markers,
            jumps: jumps,
            sectionBreak: sectionBreak,
        )
    }

    private static func score(staves: [[Measure]]) -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: staves.map { Staff(measures: $0) },
        )
        return Score(division: division, parts: [part])
    }

    @Test func mergesTopStaffJumpsWithReplicatedRepeats() {
        let jump = Jump(jumpTo: "segno", playUntil: "end")
        let segno = Marker(kind: .segno, label: "segno")
        let top: [Measure] = [
            Self.measure(markers: [segno]),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2, jumps: [jump]),
        ]
        // Staff 1 carries the repeats (replicated) but NOT the
        // jump/marker — exactly how MuseScore writes multi-staff files.
        let second: [Measure] = [
            Self.measure(),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2),
        ]
        let nav = ScoreNavigation(score: Self.score(staves: [top, second]))
        #expect(nav.measures.count == 3)
        #expect(nav.measures[0].markers == [segno])
        #expect(nav.measures[1].startRepeat == true)
        #expect(nav.measures[2].endRepeatCount == 2)
        #expect(nav.measures[2].jumps == [jump])
    }

    @Test func identicalFactsOnEveryStaffDeduplicate() {
        // Two staves both carrying the same D.S. (MuseScore #27647:
        // don't take the jump twice).
        let jump = Jump(jumpTo: "segno", playUntil: "end")
        let staff: [Measure] = [Self.measure(), Self.measure(jumps: [jump])]
        let nav = ScoreNavigation(score: Self.score(staves: [staff, staff]))
        #expect(nav.measures[1].jumps == [jump])
    }

    @Test func voltaSpansUseInclusiveEndAndDeduplicate() {
        let staff: [Measure] = [
            Self.measure(startRepeat: true),
            Self.measure(volta: [1], voltaMeasures: 2),
            Self.measure(endRepeat: 2),
            Self.measure(volta: [2]),
        ]
        let nav = ScoreNavigation(score: Self.score(staves: [staff, staff]))
        #expect(nav.voltas == [
            ScoreNavigation.VoltaSpan(startMeasure: 1, endMeasure: 2, endings: [1]),
            ScoreNavigation.VoltaSpan(startMeasure: 3, endMeasure: 3, endings: [2]),
        ])
        #expect(nav.voltas[0].hasEnding(1))
        #expect(!nav.voltas[0].hasEnding(2))
        #expect(nav.voltas[0].firstEnding == 1)
        #expect(nav.voltas[0].lastEnding == 1)
    }

    @Test func tickSpansComeFromCanonicalStaff() {
        // Whole note in 4/4 at division 480 → 1920 ticks per measure.
        let nav = ScoreNavigation(score: Self.score(staves: [[
            Self.measure(), Self.measure(),
        ]]))
        #expect(nav.measures.map(\.tickSpan) == [1920, 1920])
    }

    @Test func singleStaffViewStripsJumpsMarkersAndSectionBreaks() {
        let staff: [Measure] = [
            Self.measure(markers: [Marker(kind: .segno)], sectionBreak: true),
            Self.measure(startRepeat: true),
            Self.measure(endRepeat: 2, jumps: [Jump(jumpTo: "segno", playUntil: "end")]),
        ]
        let nav = ScoreNavigation(staffMeasures: staff, division: Self.division)
        #expect(nav.measures[0].markers.isEmpty)
        #expect(nav.measures[0].sectionBreak == false)
        #expect(nav.measures[2].jumps.isEmpty)
        // Repeats and voltas survive — the legacy per-staff plan shape.
        #expect(nav.measures[1].startRepeat == true)
        #expect(nav.measures[2].endRepeatCount == 2)
    }
}
