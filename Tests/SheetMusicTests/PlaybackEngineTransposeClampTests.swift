#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    extension AudioEngineSerial {
        /// `PlaybackEngine.setTranspose` accepts an octave either way.
        ///
        /// The clamp lives in three places — this engine, `AndroidPlaybackEngine.setTranspose`, and
        /// the NOTATION half in `LayoutOptionsWire.transposeDelta` — and they have to agree. Past a
        /// disagreement the score sounds in one key and reads in another, which is worse than either
        /// bound alone.
        ///
        /// What this suite is blind to: whether the coarse-tuning RPN actually reaches the sampler,
        /// and whether ±12 sounds right. Both are device observations.
        @Suite("PlaybackEngine — transpose clamp")
        @MainActor
        struct PlaybackEngineTransposeClampTests {
            private struct FakeResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            private static func engine() throws -> PlaybackEngine {
                let part = Part(
                    id: "p",
                    instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [Measure(voices: [])])],
                )
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                try engine.prepare(score: Score(division: 480, parts: [part]))
                return engine
            }

            @Test("an octave either way passes through")
            func octaveIsAccepted() throws {
                let engine = try Self.engine()
                engine.setTranspose(semitones: 12)
                #expect(engine.transposeSemitones == 12)
                engine.setTranspose(semitones: -12)
                #expect(engine.transposeSemitones == -12)
            }

            @Test("a major sixth passes through, where the old bound would have pinned it")
            func pastTheOldBoundIsAccepted() throws {
                // 8 is the discriminating value: the previous clamp pinned it to 7, so a test using
                // only ±12 and ±13 would pass against a clamp that had not moved at all if the bound
                // happened to be read from a constant this test also read.
                let engine = try Self.engine()
                engine.setTranspose(semitones: 8)
                #expect(engine.transposeSemitones == 8)
                engine.setTranspose(semitones: -8)
                #expect(engine.transposeSemitones == -8)
            }

            @Test("beyond an octave pins at the bound")
            func beyondTheOctaveIsPinned() throws {
                let engine = try Self.engine()
                engine.setTranspose(semitones: 13)
                #expect(engine.transposeSemitones == 12)
                engine.setTranspose(semitones: -13)
                #expect(engine.transposeSemitones == -12)
                // Far outside, to catch a clamp that merely subtracts rather than pins.
                engine.setTranspose(semitones: 400)
                #expect(engine.transposeSemitones == 12)
            }
        }
    }
#endif
