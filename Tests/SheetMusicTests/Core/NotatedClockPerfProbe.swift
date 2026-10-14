import Foundation
@testable import SheetMusicCore
import Testing

/// Opt-in timing probe, not a gate: `SM_PERF=1 swift test --filter NotatedClockPerfProbe` prints how long the tempo map
/// and the notated-time calls take on a 500-bar, 8-staff score, with and without a gradual tempo change. It asserts
/// nothing about time. It uses only API that also exists before the `NotatedClock` change, so the same file runs on the
/// parent commit for the "before" numbers; `NotatedClockCachedPerfProbe` adds the cached-clock lines ("after" only).
@Suite("Notated clock perf probe", .enabled(if: ProcessInfo.processInfo.environment["SM_PERF"] == "1"))
struct NotatedClockPerfProbe {
    private static let bars = 500
    private static let staves = 8

    static func bigScore(withRamp: Bool) -> Score {
        let eighths = (0 ..< 8).map { index -> VoiceElement in
            .chord(Chord(duration: .eighth, notes: ChordNotes([Note(pitch: 60 + index, tpc: 14)])))
        }
        let bar = Measure(voices: [Voice(elements: eighths)])
        let rampBar = Measure(voices: [Voice(elements: [.spanner(TempoMapFixtures.ritardando(measures: 4))] + eighths)])
        let allStaves = (0 ..< staves).map { staffIndex -> Staff in
            var measures = Array(repeating: bar, count: bars)
            if withRamp, staffIndex == 0 { measures[100] = rampBar }
            return Staff(measures: measures)
        }
        let part = Part(id: "P1", instrument: Instrument(id: "x"), staves: IdentifiedArray(allStaves))
        let lane = (0 ..< bars / 50).map { index in
            TempoMapFixtures.tempo(index * 50, 0, Tempo(beatsPerSecond: 2 + Double(index % 3) * 0.25))
        }
        let systemMeasures = (0 ..< bars).map { index in
            SystemMeasure(elements: lane.filter { $0.measure == index }.map { entry in
                PositionedSystemElement(
                    position: MeasurePosition(numerator: entry.quarter, denominator: 4), element: entry.element,
                )
            })
        }
        return Score(division: 480, parts: [part], systemMeasures: IdentifiedArray(systemMeasures))
    }

    /// Mean milliseconds of `body` over `repeats` runs.
    static func milliseconds(repeats: Int = 20, _ body: () -> Void) -> Double {
        let elapsed = ContinuousClock().measure {
            for _ in 0 ..< repeats {
                body()
            }
        }
        let parts = elapsed.components
        return (Double(parts.seconds) + Double(parts.attoseconds) / 1e18) * 1000 / Double(repeats)
    }

    @Test("prints tempo-map and notated-time timings")
    func printTimings() {
        for withRamp in [false, true] {
            let score = Self.bigScore(withRamp: withRamp)
            let half = score.notatedDurationSeconds / 2
            let lines = [
                ("resolvedTempoMap()", Self.milliseconds { _ = score.resolvedTempoMap() }),
                ("cursor(atSeconds:)", Self.milliseconds { _ = score.cursor(atSeconds: half) }),
                ("notatedDurationSeconds", Self.milliseconds { _ = score.notatedDurationSeconds }),
            ]
            for (name, millis) in lines {
                print("SM_PERF ramp=\(withRamp) \(name): \(String(format: "%.3f", millis)) ms")
            }
        }
    }
}
