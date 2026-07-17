import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// End-to-end `MidiRenderer.render(score:)` assertions: the plan is
/// computed ONCE, score-globally, so a jump written only on the top
/// staff (as MuseScore does) unrolls EVERY staff identically.
struct ScoreGlobalRenderTests {
    private static let division = 480

    private static func measure(
        pitch: Int,
        startRepeat: Bool = false,
        endRepeat: Int? = nil,
        markers: [Marker] = [],
        jumps: [Jump] = [],
    ) -> Measure {
        Measure(
            voices: [Voice(elements: [.chord(Chord(
                duration: .whole,
                notes: [Note(pitch: pitch, tpc: 14)],
            ))])],
            startRepeat: startRepeat,
            endRepeatCount: endRepeat,
            markers: markers,
            jumps: jumps,
        )
    }

    private static func noteOnTicks(_ track: MidiTrack) -> [Int] {
        track.events.compactMap { timed in
            if case .noteOn = timed.event { return timed.tick }
            return nil
        }.sorted()
    }

    @Test func jumpOnTopStaffUnrollsEveryStaff() throws {
        // D.S. al Fine written ONLY on staff 0 (MuseScore convention):
        // segno m1, fine m2, jump m3 → plan [0,1,2,3, 1,2] = 6 plays.
        let segno = Marker(kind: .segno)
        let fine = Marker(kind: .fine)
        let ds = Jump(jumpTo: "segno", playUntil: "fine")
        let top = [
            Self.measure(pitch: 60),
            Self.measure(pitch: 62, markers: [segno]),
            Self.measure(pitch: 64, markers: [fine]),
            Self.measure(pitch: 65, jumps: [ds]),
        ]
        let second = [
            Self.measure(pitch: 48),
            Self.measure(pitch: 50),
            Self.measure(pitch: 52),
            Self.measure(pitch: 53),
        ]
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: top), Staff(measures: second)],
        )
        let score = Score(division: Self.division, parts: [part])
        let midi = try MidiRenderer.render(score: score)
        #expect(midi.tracks.count == 2)
        let expected = [0, 1, 2, 3, 4, 5].map { $0 * 1920 }
        #expect(Self.noteOnTicks(midi.tracks[0]) == expected)
        // Staff 1 has no jump of its own but must follow the SAME
        // unrolled timeline — this is what the per-staff plan got wrong.
        #expect(Self.noteOnTicks(midi.tracks[1]) == expected)
    }

    @Test func raggedStaffMeasureCountDoesNotCrash() throws {
        // Hand-built `Score` whose staff 1 has FEWER measures than staff
        // 0 — and fewer than the score-global plan's measureIndex range
        // (0...3, from staff 0's D.S. jump). Well-formed parsed files
        // are always aligned across staves, so this shape can't arise
        // from a real import, but a hand-built `Score` value can
        // construct it. Before the ragged-staff guard, the render loop
        // trapped indexing `staff.measures[entry.measureIndex]`; now it
        // silently skips out-of-range plan entries for that staff.
        let segno = Marker(kind: .segno)
        let fine = Marker(kind: .fine)
        let ds = Jump(jumpTo: "segno", playUntil: "fine")
        let top = [
            Self.measure(pitch: 60),
            Self.measure(pitch: 62, markers: [segno]),
            Self.measure(pitch: 64, markers: [fine]),
            Self.measure(pitch: 65, jumps: [ds]),
        ]
        // Only 2 measures — shorter than top's 4.
        let second = [
            Self.measure(pitch: 48),
            Self.measure(pitch: 50),
        ]
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: top), Staff(measures: second)],
        )
        let score = Score(division: Self.division, parts: [part])
        let midi = try MidiRenderer.render(score: score)
        #expect(midi.tracks.count == 2)
        // Staff 0 (the jump-bearing staff) unrolls the full plan
        // unaffected by staff 1's shorter measure count.
        let expectedTop = [0, 1, 2, 3, 4, 5].map { $0 * 1920 }
        #expect(Self.noteOnTicks(midi.tracks[0]) == expectedTop)
        // Staff 1 plays only the plan entries whose measureIndex is in
        // range (0, 1) — including the second visit to measure 1 from
        // the D.S. jump-back at tick 7680 — and silently skips the
        // out-of-range entries for measures 2 and 3 instead of trapping.
        let expectedSecond = [0, 1920, 7680]
        #expect(Self.noteOnTicks(midi.tracks[1]) == expectedSecond)
    }

    @Test func repeatOnlyScoresRenderIdenticallyToLegacyPlan() throws {
        // Repeats replicate across staves, so the score-global plan
        // must equal the per-staff plan for jump-free scores.
        let measures = [
            Self.measure(pitch: 60),
            Self.measure(pitch: 62, startRepeat: true),
            Self.measure(pitch: 64, endRepeat: 2),
        ]
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        let score = Score(division: Self.division, parts: [part])
        let midi = try MidiRenderer.render(score: score)
        // Plan [0,1,2, 1,2] → onsets at 0..4 measures.
        #expect(Self.noteOnTicks(midi.tracks[0]) == [0, 1920, 3840, 5760, 7680])
    }
}
