#if !os(Android)
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// Smoke tests for `PlaybackEngine`'s single-shared AUMIDISynth.
    /// These don't exercise audio output — they just verify that
    /// `prepare(score:)` completes without crashing and builds the
    /// expected channel mapping. Real audible verification happens in
    /// the example apps with a real GM SoundFont.
    @Suite("PlaybackEngine prepare")
    @MainActor
    struct PlaybackEnginePrepareTests {
        @Test("prepare with mixed melodic + drum staves builds channel map")
        func prepareMixedScore() throws {
            let melodic = Part(
                id: "lead",
                instrument: Instrument(
                    id: "violin",
                    channels: [InstrumentChannel(program: 40)],
                ),
                staves: [Staff(measures: [Measure(voices: [])])],
            )
            let drums = Part(
                id: "drums",
                instrument: Instrument(
                    id: "drumset",
                    channels: [InstrumentChannel(program: 0)],
                    useDrumset: true,
                ),
                staves: [Staff(measures: [Measure(voices: [])])],
            )
            let bass = Part(
                id: "bass",
                instrument: Instrument(
                    id: "double-bass",
                    channels: [InstrumentChannel(program: 32)],
                ),
                staves: [Staff(measures: [Measure(voices: [])])],
            )
            let score = Score(
                division: 480, parts: [melodic, drums, bass],
            )
            let engine = PlaybackEngine(
                soundfontResolver: NullResolver(),
            )
            try engine.prepare(score: score)

            // Renderer assigns: melodic=0, drums=9, bass=1 (skipping 9).
            #expect(engine.midiChannel(forStaff: 0) == 0)
            #expect(engine.midiChannel(forStaff: 1) == 9)
            #expect(engine.midiChannel(forStaff: 2) == 1)
            #expect(engine.isDrumStaff(0) == false)
            #expect(engine.isDrumStaff(1) == true)
            #expect(engine.isDrumStaff(2) == false)
            #expect(engine.synth != nil)
        }

        @Test("re-prepare swaps cleanly")
        func reprepareClearsState() throws {
            let part = Part(
                id: "p",
                instrument: Instrument(
                    id: "i",
                    channels: [InstrumentChannel(program: 0)],
                ),
                staves: [Staff(measures: [Measure(voices: [])])],
            )
            let score = Score(division: 480, parts: [part])
            let engine = PlaybackEngine(
                soundfontResolver: NullResolver(),
            )
            try engine.prepare(score: score)
            #expect(engine.midiChannel(forStaff: 0) != nil)
            try engine.prepare(score: score)
            #expect(engine.midiChannel(forStaff: 0) != nil)
            #expect(engine.synth != nil)
        }
    }

    private struct NullResolver: SoundfontResolver {
        func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }
#endif
