import Foundation
@testable import SheetMusicCore

/// Small four-bar scores whose repeat plans the unroll and export tests share (whole-note 4/4 bars, division 480,
/// default tempo 120: two seconds a bar).
enum RepeatPlanFixtures {
    private static func measure(markers: [Marker] = [], jumps: [Jump] = []) -> Measure {
        Measure(
            voices: [Voice(elements: [.chord(Chord(
                duration: .whole,
                notes: [Note(pitch: 60, tpc: 14)],
            ))])],
            markers: markers,
            jumps: jumps,
        )
    }

    private static func score(_ measures: [Measure]) -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        return Score(division: 480, parts: [part])
    }

    /// D.S. al Fine: segno bar 2, fine bar 3, jump bar 4 — plan `[0, 1, 2, 3, 1, 2]`, so it plays 12 s and ends on
    /// a bar that is not the notated last.
    static func dalSegnoAlFine() -> Score {
        score([
            measure(),
            measure(markers: [Marker(kind: .segno)]),
            measure(markers: [Marker(kind: .fine)]),
            measure(jumps: [Jump(jumpTo: "segno", playUntil: "fine")]),
        ])
    }

    /// Three plain bars: no repeat plan.
    static func plainThreeBars() -> Score {
        score([measure(), measure(), measure()])
    }
}
