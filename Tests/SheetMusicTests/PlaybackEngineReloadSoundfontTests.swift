#if !os(Android)
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    extension AudioEngineSerial {
        @Suite("PlaybackEngine reloadSoundfont")
        @MainActor
        struct PlaybackEngineReloadSoundfontTests {
            private struct FakeResolver: SoundfontResolver {
                let gmURL: URL?
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    gmURL
                }
            }

            private static func singleStaffScore() -> Score {
                let part = Part(
                    id: "p",
                    instrument: Instrument(
                        id: "i", channels: [InstrumentChannel(program: 0)],
                    ),
                    staves: [Staff(measures: [Measure(voices: [])])],
                )
                return Score(division: 480, parts: [part])
            }

            private static let urlA = URL(fileURLWithPath: "/tmp/font-a.sf2")
            private static let urlB = URL(fileURLWithPath: "/tmp/font-b.sf2")

            @Test("swaps the resolver used by later prepare/export")
            func swapsResolver() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: Self.urlA))
                try engine.prepare(score: Self.singleStaffScore())
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: Self.urlB))
                #expect(engine.exportEngineSnapshot().resolver.defaultGMSoundfontURL == Self.urlB)
                #expect(engine.melodicSynth != nil)
            }

            @Test("preserves per-channel mixer state across the reload")
            func preservesMixer() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                engine.setVolume(forChannel: .staff(0), to: 0.3)
                engine.setMuted(forChannel: .staff(0), to: true)
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: nil))
                let ch = try #require(engine.mixerChannels.first { $0.id == .staff(0) })
                #expect(ch.volume == 0.3)
                #expect(ch.isMuted == true)
            }

            @Test("before any prepare, only replaces the resolver")
            func beforePrepare() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: Self.urlA))
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: Self.urlB))
                #expect(engine.exportEngineSnapshot().resolver.defaultGMSoundfontURL == Self.urlB)
                try engine.prepare(score: Self.singleStaffScore())
                #expect(engine.melodicSynth != nil)
            }

            @Test("is a no-op while exporting")
            func noOpWhileExporting() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: Self.urlA))
                try engine.prepare(score: Self.singleStaffScore())
                engine.setStateForExport(.exporting)
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: Self.urlB))
                #expect(engine.exportEngineSnapshot().resolver.defaultGMSoundfontURL == Self.urlA)
                engine.setStateForExport(.stopped)
            }

            @Test("a paused reload keeps its cursor and paused state")
            func preservesPausedPosition() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                // Play then pause to produce a real, non-nil paused cursor.
                engine.play(from: nil, in: score)
                engine.pause()
                let before = try #require(engine.currentCursor)
                #expect(engine.state == .paused)

                engine.reloadSoundfont(resolver: FakeResolver(gmURL: nil))

                // "preserving playback position" must hold for the paused
                // case too: the cursor and the paused state both survive.
                #expect(engine.currentCursor == before)
                #expect(engine.state == .paused)
            }
        }
    }
#endif
