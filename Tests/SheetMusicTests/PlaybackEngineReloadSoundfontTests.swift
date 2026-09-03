#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
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

            /// Two DISTINCT parts (not a single grand-staff part) — the
            /// mixer is keyed one strip per (part × distinct instrument),
            /// so two strips require two parts, not two staves of one.
            private static func twoPartScore() -> Score {
                func part(_ id: String) -> Part {
                    Part(
                        id: id,
                        instrument: Instrument(
                            id: "i-\(id)", channels: [InstrumentChannel(program: 0)],
                        ),
                        staves: [Staff(measures: [Measure(voices: [])])],
                    )
                }
                return Score(division: 480, parts: [part("p0"), part("p1")])
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
                engine.setVolume(forChannel: .instrument(partIndex: 0, ordinal: 0), to: 0.3)
                engine.setMuted(forChannel: .instrument(partIndex: 0, ordinal: 0), to: true)
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: nil))
                let ch = try #require(
                    engine.mixerChannels.first { $0.id == .instrument(partIndex: 0, ordinal: 0) },
                )
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

            @Test("preserves playback rate across the reload")
            func preservesRate() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                engine.setRate(1.5)
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: nil))
                #expect(engine.exportEngineSnapshot().rate == 1.5)
            }

            @Test("preserves master tuning across the reload")
            func preservesMasterTuning() throws { // swiftlint:disable:this inclusive_language
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                engine.setMasterTuning(cents: -31.77)
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: nil))
                #expect(engine.masterTuningCents == -31.77)
            }

            @Test("preserves whole-score transpose across the reload")
            func preservesTranspose() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                engine.setTranspose(semitones: 5)
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: nil))
                #expect(engine.transposeSemitones == 5)
            }

            @Test("preserves solo state on multiple channels across the reload")
            func preservesMultiSolo() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.twoPartScore())
                engine.setSoloed(forChannel: .instrument(partIndex: 0, ordinal: 0), to: true)
                engine.setSoloed(forChannel: .instrument(partIndex: 1, ordinal: 0), to: true)
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: nil))
                let strip0 = try #require(
                    engine.mixerChannels.first { $0.id == .instrument(partIndex: 0, ordinal: 0) },
                )
                let strip1 = try #require(
                    engine.mixerChannels.first { $0.id == .instrument(partIndex: 1, ordinal: 0) },
                )
                #expect(strip0.isSoloed == true)
                #expect(strip1.isSoloed == true)
            }

            @Test("preserves metronome mute and enabled state across the reload")
            func preservesMetronomeState() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                // Both differ from their defaults (enabled defaults true,
                // the metronome strip defaults un-muted), so a reload that
                // dropped them would flip the assertions.
                engine.setMetronomeEnabled(false)
                engine.setMuted(forChannel: .metronome, to: true)
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: nil))
                let metronome = try #require(engine.mixerChannels.first { $0.id == .metronome })
                #expect(metronome.isMuted == true)
                #expect(engine.exportEngineSnapshot().metronomeEnabled == false)
            }

            @Test("restartGraphPreservingState keeps a paused cursor and mixer state")
            func restartSeamPreservesState() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.setVolume(forChannel: .instrument(partIndex: 0, ordinal: 0), to: 0.4)
                engine.play(from: nil, in: score)
                engine.pause()
                let before = try #require(engine.currentCursor)

                try engine.restartGraphPreservingState()

                #expect(engine.currentCursor == before)
                #expect(engine.state == .paused)
                #expect(engine.graphRestartCount == 1)
                let channel = try #require(
                    engine.mixerChannels.first { $0.id == .instrument(partIndex: 0, ordinal: 0) },
                )
                #expect(channel.volume == 0.4)
                #expect(engine.lastGraphRestartError == nil)
            }

            @Test("restartGraphPreservingState is a no-op before any prepare")
            func restartSeamWithoutScore() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.restartGraphPreservingState()
                #expect(engine.graphRestartCount == 0)
            }

            @Test("a failed restart is recorded and stops claiming to play")
            func restartSeamFailureIsRecorded() throws {
                struct Boom: Error {}
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.play(from: nil, in: score)
                #expect(engine.state == .playing)

                engine.graphRestartFailureForTesting = Boom()
                #expect(throws: Boom.self) {
                    try engine.restartGraphPreservingState()
                }
                engine.recordGraphRestartFailure(Boom())

                #expect(engine.state == .stopped)
                #expect(engine.lastGraphRestartError is Boom)
                #expect(engine.graphRestartCount == 0)
                engine.teardown()
            }

            @Test("a successful restart clears a previously recorded failure")
            func restartSeamClearsPreviousFailure() throws {
                struct Boom: Error {}
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                engine.recordGraphRestartFailure(Boom())
                #expect(engine.lastGraphRestartError != nil)

                try engine.restartGraphPreservingState()

                #expect(engine.lastGraphRestartError == nil)
                #expect(engine.graphRestartCount == 1)
            }

            /// A host is documented as able to re-`prepare` on `lastGraphRestartError` to dismiss it. Before this
            /// fix `prepare(score:)` neither set nor cleared the field, so an error from a prior automatic rebuild
            /// stuck around on `@Observable` state even after a plain, successful re-`prepare`.
            @Test("prepare(score:) clears a previously recorded graph-restart failure")
            func prepareClearsPreviousRestartFailure() throws {
                struct Boom: Error {}
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: nil))
                try engine.prepare(score: Self.singleStaffScore())
                engine.recordGraphRestartFailure(Boom())
                #expect(engine.lastGraphRestartError != nil)

                try engine.prepare(score: Self.singleStaffScore())

                #expect(engine.lastGraphRestartError == nil)
            }

            /// Pins what `reloadSoundfont(resolver:)` does differently from the configuration-change path on
            /// failure: the resolver (and the click resolver built from it) are swapped BEFORE the rebuild, so a
            /// failed rebuild leaves the engine with a new resolver bound to an old, now-stopped graph — the same
            /// `lastGraphRestartError` / `.stopped` glue `restartGraphPreservingState()` produces for every
            /// caller, but reached here through the resolver-swap-then-rebuild path rather than a direct call.
            @Test("a failed reload records the error and stops claiming to play")
            func reloadFailureIsRecorded() throws {
                struct Boom: Error {}
                let engine = PlaybackEngine(soundfontResolver: FakeResolver(gmURL: Self.urlA))
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.play(from: nil, in: score)
                #expect(engine.state == .playing)

                engine.graphRestartFailureForTesting = Boom()
                engine.reloadSoundfont(resolver: FakeResolver(gmURL: Self.urlB))

                #expect(engine.state == .stopped)
                #expect(engine.lastGraphRestartError is Boom)
                #expect(engine.exportEngineSnapshot().resolver.defaultGMSoundfontURL == Self.urlB)
                engine.teardown()
            }
        }
    }
#endif
