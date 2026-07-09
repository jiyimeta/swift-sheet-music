import Foundation
@testable import SheetMusicAudioApple
import Testing

struct SequenceMapTests {
    @Test func preRollBeforeStartYieldsNilScoreTick() {
        let map = SequenceMap(preRollTicks: 1920, baseTick: 0)
        #expect(map.scoreTick(fromSequencer: 0) == nil)
        #expect(map.scoreTick(fromSequencer: 1919) == nil)
    }

    @Test func firstTickAfterPreRollMapsToBaseTick() {
        let map = SequenceMap(preRollTicks: 1920, baseTick: 0)
        #expect(map.scoreTick(fromSequencer: 1920) == 0)
        #expect(map.scoreTick(fromSequencer: 2400) == 480)
    }

    @Test func sequencerTickRoundTripsFromScoreTickAtZeroBase() {
        let map = SequenceMap(preRollTicks: 1920, baseTick: 0)
        #expect(map.sequencerTick(fromScore: 0) == 1920)
        #expect(map.sequencerTick(fromScore: 480) == 2400)
    }

    @Test func midScoreStartOffsetsBothDirections() {
        let map = SequenceMap(preRollTicks: 1440, baseTick: 960)
        #expect(map.scoreTick(fromSequencer: 1440) == 960)
        #expect(map.scoreTick(fromSequencer: 1920) == 1440)
        #expect(map.sequencerTick(fromScore: 960) == 1440)
        #expect(map.sequencerTick(fromScore: 1440) == 1920)
    }

    @Test func identityMapIsPassThrough() {
        let map = SequenceMap.identity
        #expect(map.scoreTick(fromSequencer: 500) == 500)
        #expect(map.sequencerTick(fromScore: 500) == 500)
    }
}
