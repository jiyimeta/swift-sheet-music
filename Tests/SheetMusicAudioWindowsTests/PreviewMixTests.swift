import SheetMusicAudioCore
@_spi(PlaybackProbe) @testable import SheetMusicAudioWindows
import SheetMusicCore
import Testing

/// A part muted, or shut out by another's solo, still sounds a tapped or held note at its slider
/// (`MixerChannel.previewGain`), and is muted again before the transport's first block — the Apple engine's
/// `PlaybackEnginePreviewMixTests`. Read off the CC 7 the score synth keeps (`probeController`), which every reset of
/// its sequencer sends back.
struct PreviewMixTests {
    static let first = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 0)
    static let second = MixerChannel.Kind.instrument(partIndex: 1, ordinal: 0)
    /// 0.5 on the slider: 63.5, rounded.
    static let halfCC7 = 64

    /// Two parts of four bars of quarters.
    static func score() -> Score {
        func part(_ id: String, program: Int) -> Part {
            let measures = (0 ..< 4).map { _ in
                Measure(voices: [Voice(elements: (0 ..< 4).map { _ in
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
                })])
            }
            return Part(
                id: id,
                instrument: Instrument(id: "i-\(id)", channels: [InstrumentChannel(program: program)]),
                staves: [Staff(measures: measures)],
            )
        }
        return Score(division: 480, parts: [part("P0", program: 0), part("P1", program: 40)])
    }

    static let firstNote = NoteID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
    )

    /// The engine with the first part's slider at 0.5, the score, and that part's CC 7 as the synth keeps it.
    static func setUp() throws -> (WindowsPlaybackEngine, Score, () -> Int?) {
        let score = Self.score()
        let engine = try CountInTransportTests.engine(score)
        engine.setVolume(forChannel: first, to: 0.5)
        let channel = try #require(engine.probeStrips.first { $0.kind == first }?.channel)
        return (engine, score, { engine.probeController(7, onChannel: channel) })
    }

    @Test func aMutedPartsTapSoundsAtItsSlider() throws {
        let (engine, score, volume) = try Self.setUp()
        defer { engine.teardown() }
        engine.setMuted(forChannel: Self.first, to: true)
        #expect(volume() == 0)

        engine.playPreview(noteID: Self.firstNote, in: score)

        #expect(volume() == Self.halfCC7)
    }

    @Test func aPartShutOutByAnothersSoloSoundsItsTap() throws {
        let (engine, score, volume) = try Self.setUp()
        defer { engine.teardown() }
        engine.setSoloed(forChannel: Self.second, to: true)
        #expect(volume() == 0)

        engine.playPreview(noteID: Self.firstNote, in: score)

        #expect(volume() == Self.halfCC7)
    }

    @Test func aHeldKeyOnAMutedPartSoundsAtItsSlider() throws {
        let (engine, _, volume) = try Self.setUp()
        defer { engine.teardown() }
        engine.setMuted(forChannel: Self.first, to: true)

        engine.previewNoteOn(pitch: 60, onStaff: 0, atTick: 0)

        #expect(volume() == Self.halfCC7)
    }

    /// Checked before a block renders: the render thread's own reassert comes a block after the start.
    @Test(arguments: [false, true])
    func playMutesThePartAgainBeforeTheFirstBlock(countIn: Bool) throws {
        let (engine, score, volume) = try Self.setUp()
        defer { engine.teardown() }
        engine.setMuted(forChannel: Self.first, to: true)
        engine.playPreview(noteID: Self.firstNote, in: score)

        engine.play(in: score, countIn: countIn)

        #expect(engine.state == .playing)
        #expect(volume() == 0)
    }

    @Test func resumingFromAPauseMutesThePartAgainBeforeTheFirstBlock() throws {
        let (engine, score, volume) = try Self.setUp()
        defer { engine.teardown() }
        engine.setMuted(forChannel: Self.first, to: true)
        engine.play(in: score)
        CountInTransportTests.pull(engine, seconds: 0.2)
        engine.pause()
        engine.previewNoteOn(pitch: 60, onStaff: 0, atTick: 0)
        engine.previewNoteOff(pitch: 60)
        #expect(volume() == Self.halfCC7)

        engine.play(in: score)

        #expect(volume() == 0)
    }

    /// The preview strikes the channel the music plays on: opening it would bring the part back under the music.
    @Test func aPreviewWhileTheScorePlaysLeavesTheMutedPartMuted() throws {
        let (engine, score, volume) = try Self.setUp()
        defer { engine.teardown() }
        engine.setMuted(forChannel: Self.first, to: true)
        engine.play(in: score)
        CountInTransportTests.pull(engine, seconds: 0.2)

        engine.playPreview(noteID: Self.firstNote, in: score)

        #expect(volume() == 0)
    }
}
