#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    /// Unit tests for `PlaybackEngine`'s master output gain. These do
    /// not exercise audio output — they verify the public clamping
    /// contract, that the clamped value reaches the underlying mixer
    /// node, and that the value survives `prepare(score:)`. Audible
    /// limiter behavior is verified in the Mac example app with a real
    /// GM soundfont (CI has no audio device).
    extension AudioEngineSerial {
        @Suite("PlaybackEngine master gain")
        @MainActor
        struct PlaybackEngineMasterGainTests { // swiftlint:disable:this inclusive_language
            @Test("defaults to unity gain")
            func defaultsToUnity() {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                #expect(engine.masterGain == 1.0)
                #expect(engine.scoreGainMixerOutputVolume == 1.0)
            }

            @Test("setMasterGain clamps negatives to zero and reaches the node")
            func clampsAndApplies() {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())

                engine.setMasterGain(1.5)
                #expect(engine.masterGain == 1.5)
                #expect(engine.scoreGainMixerOutputVolume == 1.5)

                engine.setMasterGain(-1) // below floor
                #expect(engine.masterGain == 0.0)
                #expect(engine.scoreGainMixerOutputVolume == 0.0)
            }

            /// There is deliberately no ceiling: a host calibrating a quiet backend against a
            /// louder reference can need well past the old 3.0 limit, and that judgement is the
            /// host's to make, not this engine's.
            @Test("setMasterGain has no upper limit")
            func acceptsGainAboveTheOldCeiling() {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())

                engine.setMasterGain(5)
                #expect(engine.masterGain == 5.0)
                #expect(engine.scoreGainMixerOutputVolume == 5.0)

                engine.setMasterGain(12)
                #expect(engine.masterGain == 12.0)
                #expect(engine.scoreGainMixerOutputVolume == 12.0)
            }

            @Test("master gain persists across prepare(score:)")
            func persistsAcrossPrepare() throws {
                let part = Part(
                    id: "p",
                    instrument: Instrument(
                        id: "i",
                        channels: [InstrumentChannel(program: 0)],
                    ),
                    staves: [Staff(measures: [Measure(voices: [])])],
                )
                let score = Score(division: 480, parts: [part])
                let engine = PlaybackEngine(soundfontResolver: NullResolver())

                engine.setMasterGain(2.0)
                try engine.prepare(score: score)

                #expect(engine.masterGain == 2.0)
                #expect(engine.scoreGainMixerOutputVolume == 2.0)
                #expect(engine.melodicSynth != nil)
            }
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
