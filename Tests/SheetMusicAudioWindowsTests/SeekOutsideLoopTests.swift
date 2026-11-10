@_spi(PlaybackProbe) @testable import SheetMusicAudioWindows
import SheetMusicCore
import Testing

/// Where a seek lands while an A–B loop is set, as on the Apple engine (`PlaybackEngineSeekOutsideLoopTests`). Stopped
/// or paused, the cursor goes where it was sent — the user is parking it, typically to set a new B past the section —
/// and the loop takes over when playback starts. Playing, a seek outside the loop snaps to its start. Offline, with no
/// SoundFont, over `CountInTransportTests`' four bars of quarters with bar 2 looping.
struct SeekOutsideLoopTests {
    private static func setUp() throws -> (WindowsPlaybackEngine, Score) {
        let score = CountInTransportTests.score()
        let engine = try CountInTransportTests.engine(score)
        engine.setLoop(from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 2, tickInMeasure: 0))
        return (engine, score)
    }

    /// The notated tick of the frame `cursor` names.
    private static func tick(of cursor: ScoreCursor, _ engine: WindowsPlaybackEngine) throws -> Int {
        try #require(engine.loadedDerivation?.timeline.frame(forCursor: cursor)).tick
    }

    /// The seconds a scrubber reads agree with the cursor: neither folds a parked position back into the loop (the
    /// Apple engine's `currentTimeSeconds` still does).
    private static func expectSecondsAt(_ cursor: ScoreCursor, _ engine: WindowsPlaybackEngine) throws {
        let derivation = try #require(engine.loadedDerivation)
        let frame = try #require(derivation.timeline.frame(forCursor: cursor))
        let snapped = engine.currentTimeSeconds
        let continuous = engine.currentTimeSecondsContinuous
        #expect(abs(snapped - frame.timeSeconds) < 1e-9, "\(snapped) vs \(frame.timeSeconds)")
        #expect(abs(continuous - frame.timeSeconds) < 1e-9, "\(continuous) vs \(frame.timeSeconds)")
    }

    @Test func aStoppedSeekPastTheLoopStaysWhereItWasSent() throws {
        let (engine, _) = try Self.setUp()
        defer { engine.teardown() }

        engine.seek(to: .beat(measureIndex: 3, tickInMeasure: 0))

        let cursor = try #require(engine.currentCursor)
        #expect(cursor.measureIndex == 3, "\(cursor)")
        try Self.expectSecondsAt(cursor, engine)
    }

    @Test func aPausedSeekPastTheLoopStaysWhereItWasSent() throws {
        let (engine, score) = try Self.setUp()
        defer { engine.teardown() }
        engine.play(from: .beat(measureIndex: 1, tickInMeasure: 0), in: score)
        CountInTransportTests.pull(engine, seconds: 0.1)
        engine.pause()

        engine.seek(to: .beat(measureIndex: 3, tickInMeasure: 480))

        #expect(engine.state == .paused)
        let cursor = try #require(engine.currentCursor)
        #expect(cursor.measureIndex == 3, "\(cursor)")
        try Self.expectSecondsAt(cursor, engine)
    }

    @Test func playingFromACursorParkedPastTheLoopStartsAtTheLoopsStart() throws {
        let (engine, score) = try Self.setUp()
        defer { engine.teardown() }
        engine.seek(to: .beat(measureIndex: 3, tickInMeasure: 0))

        engine.play(in: score)
        CountInTransportTests.pull(engine, seconds: 0.1)

        let cursor = try #require(engine.currentCursor)
        #expect(cursor.measureIndex == 1, "\(cursor)")
    }

    @Test func aSeekPastTheLoopWhilePlayingSnapsToTheLoopsStart() throws {
        let (engine, score) = try Self.setUp()
        defer { engine.teardown() }
        engine.play(from: .beat(measureIndex: 1, tickInMeasure: 0), in: score)
        CountInTransportTests.pull(engine, seconds: 0.1)

        engine.seek(to: .beat(measureIndex: 3, tickInMeasure: 0))
        CountInTransportTests.pull(engine, seconds: 0.1)

        #expect(engine.state == .playing)
        let cursor = try #require(engine.currentCursor)
        #expect(cursor.measureIndex == 1, "\(cursor)")
    }

    /// A seek past B during a count-in is a playing seek: it snaps to A, ends the count, and the score starts there.
    @Test func aSeekPastTheLoopDuringACountInStartsTheScoreAtTheLoopsStart() throws {
        let (engine, score) = try Self.setUp()
        defer { engine.teardown() }
        engine.play(from: .beat(measureIndex: 1, tickInMeasure: 0), in: score, countIn: true)
        CountInTransportTests.pull(engine, seconds: 0.5)
        #expect(try #require(engine.probeTransport).countingIn)

        engine.seek(to: .beat(measureIndex: 3, tickInMeasure: 0))
        CountInTransportTests.pull(engine, seconds: 0.1)

        let transport = try #require(engine.probeTransport)
        #expect(!transport.countingIn)
        #expect(transport.scoreRunning)
        let cursor = try #require(engine.currentCursor)
        #expect(cursor.measureIndex == 1, "\(cursor)")
    }

    /// The render reports a position just past B for the moment before it carries out the wrap. Put there directly
    /// (one beat past the loop's end, 3840 + 480): while playing, the cursor and the time read it folded into the
    /// loop, one beat past A.
    private static func playJustPastTheLoopsEnd(_ engine: WindowsPlaybackEngine, _ score: Score) {
        engine.play(from: .beat(measureIndex: 1, tickInMeasure: 0), in: score)
        CountInTransportTests.pull(engine, seconds: 0.1)
        engine.core.shared.withLock { $0.pendingScoreTick = 3840 + 480 }
    }

    @Test func aPlayingPositionPastTheLoopsEndReadsFoldedIntoTheLoop() throws {
        let (engine, score) = try Self.setUp()
        defer { engine.teardown() }
        Self.playJustPastTheLoopsEnd(engine, score)

        let cursor = try #require(engine.currentCursor)
        let tick = try Self.tick(of: cursor, engine)
        #expect(tick == 1920 + 480, "\(cursor)")
        try Self.expectSecondsAt(cursor, engine)
    }

    /// A pause in that moment parks at the folded tick, and play resumes from it, not from A.
    @Test func aPauseJustPastTheLoopsEndParksAndResumesWhereTheWrapPutsIt() throws {
        let (engine, score) = try Self.setUp()
        defer { engine.teardown() }
        Self.playJustPastTheLoopsEnd(engine, score)

        engine.pause()

        let paused = try #require(engine.currentCursor)
        let pausedTick = try Self.tick(of: paused, engine)
        #expect(pausedTick == 1920 + 480, "\(paused)")
        try Self.expectSecondsAt(paused, engine)
        let parked = engine.core.shared.withLock { $0.reportedScoreTick }
        #expect(parked == 1920 + 480)

        engine.play(in: score)

        let restart = engine.core.shared.withLock { $0.reportedScoreTick }
        #expect(restart == 1920 + 480)
        CountInTransportTests.pull(engine, seconds: 0.1)
        let resumed = try #require(engine.currentCursor)
        let resumedTick = try Self.tick(of: resumed, engine)
        #expect((1920 + 480 ..< 3840).contains(resumedTick), "\(resumed)")
    }
}
