#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    /// The master output stage selector. Both shaping nodes stay wired
    /// into the chain permanently and are switched by `bypass`, so these
    /// assert the bypass flags rather than the graph's shape.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine master output stage")
        @MainActor
        struct PlaybackEngineMasterOutputStageTests { // swiftlint:disable:this inclusive_language
            /// Linear by default. The peak limiter used to be unconditional,
            /// and it makes the master gain run backwards above unity —
            /// measured, an 8x drive came out 2.4 dB quieter than 1x. A
            /// host has to opt into that, not inherit it.
            @Test("defaults to no shaping at all")
            func defaultsToLinear() {
                let engine = PlaybackEngine(soundfontResolver: NullStageResolver())
                #expect(engine.masterOutputStage == .none)
                #expect(engine.softClipIsBypassed)
                #expect(engine.limiterIsBypassed)
            }

            @Test("soft clip engages only the soft clip node")
            func softClipEngagesOnlySoftClip() {
                let engine = PlaybackEngine(soundfontResolver: NullStageResolver())

                engine.setMasterOutputStage(.softClip)

                #expect(engine.masterOutputStage == .softClip)
                #expect(engine.softClipIsBypassed == false)
                #expect(engine.limiterIsBypassed)
            }

            @Test("peak limiter engages only the limiter")
            func peakLimiterEngagesOnlyLimiter() {
                let engine = PlaybackEngine(soundfontResolver: NullStageResolver())

                engine.setMasterOutputStage(.peakLimiter)

                #expect(engine.masterOutputStage == .peakLimiter)
                #expect(engine.softClipIsBypassed)
                #expect(engine.limiterIsBypassed == false)
            }

            @Test("switching back to none bypasses everything again")
            func switchingBackToNone() {
                let engine = PlaybackEngine(soundfontResolver: NullStageResolver())

                engine.setMasterOutputStage(.peakLimiter)
                engine.setMasterOutputStage(.none)

                #expect(engine.masterOutputStage == .none)
                #expect(engine.softClipIsBypassed)
                #expect(engine.limiterIsBypassed)
            }

            /// An export that ignored the stage would not sound like what
            /// the user just heard — the same reason the snapshot already
            /// carries `masterGain`.
            @Test("the export snapshot carries the stage")
            func exportSnapshotCarriesTheStage() {
                let engine = PlaybackEngine(soundfontResolver: NullStageResolver())

                #expect(engine.exportEngineSnapshot().masterOutputStage == .none)

                engine.setMasterOutputStage(.softClip)
                #expect(engine.exportEngineSnapshot().masterOutputStage == .softClip)

                engine.setMasterOutputStage(.peakLimiter)
                #expect(engine.exportEngineSnapshot().masterOutputStage == .peakLimiter)
            }

            /// The master chain is built once in `init` and outlives every
            /// score, exactly like `masterGain`.
            @Test("the stage survives prepare(score:)")
            func survivesPrepare() throws {
                let part = Part(
                    id: "p",
                    instrument: Instrument(
                        id: "i",
                        channels: [InstrumentChannel(program: 0)],
                    ),
                    staves: [Staff(measures: [Measure(voices: [])])],
                )
                let score = Score(division: 480, parts: [part])
                let engine = PlaybackEngine(soundfontResolver: NullStageResolver())

                engine.setMasterOutputStage(.softClip)
                try engine.prepare(score: score)

                #expect(engine.masterOutputStage == .softClip)
                #expect(engine.softClipIsBypassed == false)
            }
        }
    }

    private struct NullStageResolver: SoundfontResolver {
        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }
#endif
