import Foundation
import SheetMusicAudioCore
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// `UnrolledTimeMap.unrolledLength(of:)` is where a repeat plan's playback ends, which for a D.C. / D.S. al Fine
/// ending is before the notated end; `measurePlays` is the walk a video's keyframes follow.
struct UnrolledTimeMapLengthTests {
    @Test func anAlFineScorePlaysToItsLastMeasurePlay() {
        let score = RepeatPlanFixtures.dalSegnoAlFine()
        let timeline = PlaybackTimeline(score: score)
        let map = UnrolledTimeMap(unroll: MidiRenderer.playbackUnroll(score: score), timeline: timeline)
        #expect(abs(map.unrolledLength(of: timeline) - 12.0) < 1e-9) // 6 plays x 2 s; the notated end maps to 14 s
        #expect(map.measurePlays.map(\.span.notatedStart) == [0, 1920, 3840, 5760, 1920, 3840])
        #expect(abs(map.measurePlays[4].unrolledStartSeconds - 8.0) < 1e-9)
        #expect(abs(map.measurePlays[4].notatedStartSeconds - 2.0) < 1e-9)
        #expect(abs(map.measurePlays[4].durationSeconds - 2.0) < 1e-9)
    }

    @Test func withoutARepeatPlanTheLengthIsTheNotatedOne() {
        let score = RepeatPlanFixtures.plainThreeBars()
        let timeline = PlaybackTimeline(score: score)
        #expect(
            UnrolledTimeMap.identity.unrolledLength(of: timeline)
                == timeline.seconds(atTick: Double(timeline.totalTicks)),
        )
        #expect(UnrolledTimeMap.identity.measurePlays.isEmpty)
    }
}
