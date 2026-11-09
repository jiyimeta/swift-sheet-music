@testable import SheetMusicAudioCore
import Testing

/// Where a seek lands with an A–B loop set (`LoopRange.seekTick(_:whilePlaying:)`), the rule the Apple and the Windows
/// engine both seek by: snapped into the loop while playing, where it was sent while stopped or paused.
struct LoopRangeSeekTests {
    /// The first two quarters of a bar at division 480.
    private let loop = LoopRange(startTick: 0, endTick: 960)

    @Test func theRangeIsHalfOpen() {
        #expect(loop.contains(0))
        #expect(loop.contains(959))
        #expect(!loop.contains(960))
        #expect(!loop.contains(-1))
    }

    @Test func aSeekWhilePlayingLandsInTheLoop() {
        #expect(loop.seekTick(1440, whilePlaying: true) == 0)
        #expect(loop.seekTick(960, whilePlaying: true) == 0, "the end is outside")
        #expect(loop.seekTick(480, whilePlaying: true) == 480, "inside, it stays")
    }

    /// The user report of 2026-11-02: a tap past the section to set a new B sent the cursor back to A.
    @Test func aSeekWhileStoppedOrPausedStaysWhereItWasSent() {
        #expect(loop.seekTick(1440, whilePlaying: false) == 1440)
        #expect(loop.seekTick(960, whilePlaying: false) == 960)
        #expect(loop.seekTick(480, whilePlaying: false) == 480)
    }
}
