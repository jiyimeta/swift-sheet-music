#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    /// The master output stage selector. The shaping node stays wired into the chain permanently and is switched by
    /// `bypass`, so these assert the bypass flag rather than the graph's shape.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine master output stage")
        @MainActor
        struct PlaybackEngineMasterOutputStageTests { // swiftlint:disable:this inclusive_language
            /// Linear by default. The peak limiter this engine once applied unconditionally made the master gain run
            /// backwards above unity — measured, an 8x drive came out 2.4 dB quieter than 1x. Shaping is something a
            /// host opts into, not something it inherits.
            @Test("defaults to no shaping at all")
            func defaultsToLinear() {
                let engine = PlaybackEngine(soundfontResolver: NullStageResolver())
                #expect(engine.masterOutputStage == .none)
                #expect(engine.softClipIsBypassed)
            }

            @Test("soft clip engages the soft clip node")
            func softClipEngagesOnlySoftClip() {
                let engine = PlaybackEngine(soundfontResolver: NullStageResolver())

                engine.setMasterOutputStage(.softClip)

                #expect(engine.masterOutputStage == .softClip)
                #expect(engine.softClipIsBypassed == false)
            }

            @Test("switching back to none bypasses the shaping again")
            func switchingBackToNone() {
                let engine = PlaybackEngine(soundfontResolver: NullStageResolver())

                engine.setMasterOutputStage(.softClip)
                engine.setMasterOutputStage(.none)

                #expect(engine.masterOutputStage == .none)
                #expect(engine.softClipIsBypassed)
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
