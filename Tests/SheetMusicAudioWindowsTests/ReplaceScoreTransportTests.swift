@testable import SheetMusicAudioCore
@testable import SheetMusicAudioWindows
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
        #expect(after.measureIndex == before.measureIndex)
        #expect(after.tickInMeasure == before.tickInMeasure)
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
