@_spi(PlaybackProbe) @testable import SheetMusicAudioWindows
import SheetMusicCore
import Testing

/// The metronome's one sequence through a count-in play (`MetronomeSequenceBuilder.countInSequenceWithWholeBody`):
/// pulled offline in the engine's own chunks, with no SoundFont, so what is checked is where the transport stands, not
/// what it sounds like. 120 bpm at 480 ticks a quarter: 960 ticks a second, 21.8 ticks a 64-frame chunk at 44.1 kHz.
struct CountInTransportTests {
    static let sampleRate = 44100.0
    /// Two chunks: a jump is carried out by the block after the one it was decided in.
    static let slack = 44

    /// Four bars of 4/4 quarters, so every beat is a frame a count can count into. `pitch` makes an edited copy
    /// (`ReplaceScoreTransportTests`) with the same layout.
    static func score(pitch: Int = 60, measures count: Int = 4) -> Score {
        let measures = (0 ..< count).map { _ in
            Measure(voices: [Voice(elements: (0 ..< 4).map { _ in
                .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)]))
            })])
        }
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        return Score(division: 480, parts: [part])
    }

    static func engine(_ score: Score) throws -> WindowsPlaybackEngine {
        let engine = WindowsPlaybackEngine(
            soundfontResolver: Fixtures.silentResolver, output: .offline(sampleRate: sampleRate),
        )
        try engine.prepare(score: score)
        return engine
    }

    /// Pulls `seconds` of audio through the engine's render, in 4096-frame callbacks, stopping early once `until`
    /// holds.
    static func pull(_ engine: WindowsPlaybackEngine, seconds: Double, until: () -> Bool = { false }) {
        let frames = 4096
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { buffer.deallocate() }
        var left = Int(seconds * sampleRate)
        while left > 0, !until() {
            _ = engine.core.renderOffline(into: buffer, frames: frames)
            left -= frames
        }
    }

    static func wholeBodyOffset(_ engine: WindowsPlaybackEngine) -> Int? {
        engine.core.shared.withLock { $0.session?.metronomeWholeBodyOffsetTicks }
    }

    /// Counted into the middle of an A–B loop: the wrap lands before the count's start, whose beats the first pass
    /// does not hold. The metronome must land on the loop start's beat in the whole body behind it.
    @Test func aWrapAfterACountInLandsTheClickOnTheLoopStartsBeat() throws {
        let score = Self.score()
        let engine = try Self.engine(score)
        defer { engine.teardown() }
        engine.setLoop(from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 3, tickInMeasure: 0))
        engine.play(from: .beat(measureIndex: 2, tickInMeasure: 960), in: score, countIn: true)
        let firstPass = try #require(engine.probeTransport?.metronomeOffsetTicks)
        #expect(try #require(engine.probeTransport).countingIn)
        // 2 s of count, 1 s to the loop's end.
        Self.pull(engine, seconds: 5) { engine.probeTransport?.lastWrapLandingTick != nil }

        let transport = try #require(engine.probeTransport)
        let wholeBody = try #require(Self.wholeBodyOffset(engine))
        #expect(engine.diagnostics.loopWraps == 1)
        #expect(wholeBody > 0)
        #expect(firstPass != wholeBody)
        #expect(transport.metronomeOffsetTicks == wholeBody)
        let landing = try #require(transport.lastWrapLandingTick)
        #expect(abs(landing - 1920) <= Self.slack, "score landed at \(landing)")
        // The click on the loop start's beat: the metronome stands at that beat of the whole body, level with the
        // score, within the block the wrap was carried out in.
        let metronomeScoreTick = transport.metronomeTick - wholeBody
        #expect(
            abs(metronomeScoreTick - transport.scorePlayerTick) <= Self.slack,
            "metronome at score tick \(metronomeScoreTick), score at \(transport.scorePlayerTick)",
        )
    }

    /// A seek during the count ends it and the score starts at the seek; the metronome lands on the same beat of the
    /// whole body — here one before the count's start, which the first pass does not hold.
    @Test func aSeekDuringACountInLandsOnTheRightBodyBeat() throws {
        let score = Self.score()
        let engine = try Self.engine(score)
        defer { engine.teardown() }
        engine.play(from: .beat(measureIndex: 2, tickInMeasure: 0), in: score, countIn: true)
        Self.pull(engine, seconds: 0.5)
        #expect(try #require(engine.probeTransport).countingIn)

        engine.seek(to: .beat(measureIndex: 0, tickInMeasure: 480))
        Self.pull(engine, seconds: 0.1)
        let transport = try #require(engine.probeTransport)
        let wholeBody = try #require(Self.wholeBodyOffset(engine))
        #expect(!transport.countingIn)
        #expect(transport.metronomeOffsetTicks == wholeBody)
        // 0.1 s on from tick 480 is 96 ticks.
        #expect(abs(transport.scorePlayerTick - 576) <= Self.slack * 3, "score at \(transport.scorePlayerTick)")
        #expect(
            abs((transport.metronomeTick - wholeBody) - transport.scorePlayerTick) <= Self.slack,
            "metronome at score tick \(transport.metronomeTick - wholeBody)",
        )
    }

    /// The handover itself, unchanged by the move to one sequence: the score starts at the count's start when the
    /// first pass reaches the pre-roll's end.
    @Test func theCountHandsOverToTheScoreAtItsStart() throws {
        let score = Self.score()
        let engine = try Self.engine(score)
        defer { engine.teardown() }
        engine.play(from: .beat(measureIndex: 1, tickInMeasure: 0), in: score, countIn: true)
        Self.pull(engine, seconds: 3) { engine.probeTransport?.countingIn == false }
        let transport = try #require(engine.probeTransport)
        #expect(!transport.countingIn)
        #expect(transport.scoreRunning)
        let late = try #require(engine.diagnostics.lastCountInHandoverLateTicks)
        #expect(late >= 0 && late <= Self.slack, "handover \(late) ticks late")
        #expect(abs(transport.reportedScoreTick - 1920) <= Self.slack * 3)
    }
}
