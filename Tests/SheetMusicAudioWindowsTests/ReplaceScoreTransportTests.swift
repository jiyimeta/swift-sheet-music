@testable import SheetMusicAudioCore
@_spi(PlaybackProbe) @testable import SheetMusicAudioWindows
import SheetMusicCore
import Testing

/// An edit's score swap keeps the transport, as the Apple engine's does (`replaceScore(with:)`): playing goes on from
/// the same measure, paused stays paused there, and the loop is still the loop. Offline, with no SoundFont.
struct ReplaceScoreTransportTests {
    static func score(pitch: Int = 60) -> Score {
        CountInTransportTests.score(pitch: pitch)
    }

    static func engine(_ score: Score) throws -> WindowsPlaybackEngine {
        try CountInTransportTests.engine(score)
    }

    @Test func playingGoesOnFromTheSameMeasure() throws {
        let original = Self.score()
        let engine = try Self.engine(original)
        defer { engine.teardown() }
        engine.play(from: .beat(measureIndex: 2, tickInMeasure: 0), in: original)
        CountInTransportTests.pull(engine, seconds: 0.5)

        let edited = Self.score(pitch: 62)
        let outcome = try engine.replaceScore(with: PreparedPlayback.make(score: edited))
        #expect(outcome == .swappedInPlace)
        #expect(engine.state == .playing)
        CountInTransportTests.pull(engine, seconds: 0.2)
        let cursor = try #require(engine.currentCursor)
        // Half a second into bar 3 at 120 bpm is its second beat; the swap must not send it back to bar 1.
        #expect(cursor.measureIndex == 2, "\(cursor)")
    }

    @Test func pausedStaysPausedWhereItWas() throws {
        let original = Self.score()
        let engine = try Self.engine(original)
        defer { engine.teardown() }
        engine.play(from: .beat(measureIndex: 1, tickInMeasure: 960), in: original)
        CountInTransportTests.pull(engine, seconds: 0.1)
        engine.pause()
        let before = try #require(engine.currentCursor)

        try engine.replaceScore(with: PreparedPlayback.make(score: Self.score(pitch: 64)))
        #expect(engine.state == .paused)
        let after = try #require(engine.currentCursor)
        #expect(after == before)
    }

    /// An edit that removes the measures the cursor stood in: the cursor clamps into the last measure, still playing
    /// (`PlaybackTimeline.tick(at:)`), and a loop whose ends now meet is dropped.
    @Test func aShorterScoreClampsTheCursorAndDropsAnEmptyLoop() throws {
        let original = Self.score()
        let engine = try Self.engine(original)
        defer { engine.teardown() }
        engine.setLoop(from: .beat(measureIndex: 2, tickInMeasure: 0), to: .beat(measureIndex: 3, tickInMeasure: 0))
        engine.play(from: .beat(measureIndex: 2, tickInMeasure: 480), in: original)
        CountInTransportTests.pull(engine, seconds: 0.1)

        let shorter = CountInTransportTests.score(measures: 2)
        try engine.replaceScore(with: PreparedPlayback.make(score: shorter))
        #expect(engine.state == .playing)
        #expect(engine.loopRange == nil)
        let cursor = try #require(engine.currentCursor)
        #expect(cursor.measureIndex == 1, "\(cursor)")
    }

    /// As on the Apple engine (`restore` plays on without `countIn`): a swap while the count is still sounding plays
    /// on from the count's start without counting again.
    @Test func aSwapDuringACountInPlaysOnFromItsStart() throws {
        let original = Self.score()
        let engine = try Self.engine(original)
        defer { engine.teardown() }
        engine.play(from: .beat(measureIndex: 2, tickInMeasure: 0), in: original, countIn: true)
        CountInTransportTests.pull(engine, seconds: 0.5)
        #expect(try #require(engine.probeTransport).countingIn)

        try engine.replaceScore(with: PreparedPlayback.make(score: Self.score(pitch: 62)))
        let transport = try #require(engine.probeTransport)
        #expect(engine.state == .playing)
        #expect(!transport.countingIn)
        #expect(transport.scoreRunning)
        #expect(try #require(engine.currentCursor).measureIndex == 2)
    }

    /// A different score handed to `play` swaps without seating the old position first: the count runs once, from
    /// the asked start.
    @Test func playWithAnotherScoreCountsInOnce() throws {
        let original = Self.score()
        let engine = try Self.engine(original)
        defer { engine.teardown() }
        engine.play(from: .beat(measureIndex: 1, tickInMeasure: 0), in: original)
        CountInTransportTests.pull(engine, seconds: 0.2)

        engine.play(from: .beat(measureIndex: 3, tickInMeasure: 0), in: Self.score(pitch: 64), countIn: true)
        let transport = try #require(engine.probeTransport)
        #expect(transport.countingIn)
        #expect(!transport.scoreRunning)
        #expect(transport.reportedScoreTick == 3 * 1920)
    }

    @Test func theLoopIsStillTheLoop() throws {
        let original = Self.score()
        let engine = try Self.engine(original)
        defer { engine.teardown() }
        engine.setLoop(from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 3, tickInMeasure: 0))
        let loop = try #require(engine.loopRange)

        try engine.replaceScore(with: PreparedPlayback.make(score: Self.score(pitch: 65)))
        #expect(engine.loopRange == loop)
    }
}
