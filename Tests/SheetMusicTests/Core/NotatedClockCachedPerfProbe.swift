import Foundation
@testable import SheetMusicCore
import Testing

/// The "after" half of `NotatedClockPerfProbe`: what a scrub frame costs once the clock is built a single time.
/// `SM_PERF=1 swift test --filter NotatedClockCachedPerfProbe`; prints only.
@Suite(
    "Notated clock cached perf probe",
    .enabled(if: ProcessInfo.processInfo.environment["SM_PERF"] == "1"),
)
struct NotatedClockCachedPerfProbe {
    @Test("prints the cached-clock timings")
    func printTimings() {
        for withRamp in [false, true] {
            let score = NotatedClockPerfProbe.bigScore(withRamp: withRamp)
            let map = score.resolvedTempoMap()
            let clock = score.notatedClock(tempoMap: map)
            let half = clock.durationSeconds / 2
            let lines = [
                ("notatedClock(tempoMap:) given a map", NotatedClockPerfProbe.milliseconds {
                    _ = score.notatedClock(tempoMap: map)
                }),
                ("cursor(atSeconds:) on a cached clock", NotatedClockPerfProbe.milliseconds(repeats: 1000) {
                    _ = clock.cursor(atSeconds: half)
                }),
            ]
            for (name, millis) in lines {
                print("SM_PERF ramp=\(withRamp) \(name): \(String(format: "%.4f", millis)) ms")
            }
        }
    }
}
