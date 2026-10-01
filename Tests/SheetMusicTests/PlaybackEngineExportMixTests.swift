#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    /// An audio export silences a strip exactly as live playback does.
    ///
    /// Regression: both export pipelines carried their own copy of the mute / solo rule, under which solo won — so a
    /// strip both muted and soloed was silent in playback (`MixerChannel.isSilenced`: mute wins) but sounded in the
    /// exported file. Live audibility is read off the live `RecordingBackend`'s CC 7 traffic (what `applyMixerState`
    /// sends), export audibility two ways: `PlaybackEngine.exportVolumeCC7(of:soloing:)`, the decision BOTH export
    /// pipelines make (the AUMIDISynth one has no other observable), and the CC 7 traffic the backend export actually
    /// pushed onto its offline instance.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine export mix vs. live mix")
        @MainActor
        struct PlaybackEngineExportMixTests {
            private static let staff0 = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 0)
            private static let staff1 = MixerChannel.Kind.instrument(partIndex: 1, ordinal: 0)

            /// One strip's mute / solo buttons. Crossed over two strips this covers every combination on a strip, with
            /// the solo bus both engaged and not.
            enum StripState: CaseIterable, Sendable, CustomTestStringConvertible {
                case plain, muted, soloed, mutedAndSoloed

                var isMuted: Bool {
                    self == .muted || self == .mutedAndSoloed
                }

                var isSoloed: Bool {
                    self == .soloed || self == .mutedAndSoloed
                }

                var testDescription: String {
                    switch self {
                    case .plain: "plain"
                    case .muted: "muted"
                    case .soloed: "soloed"
                    case .mutedAndSoloed: "muted+soloed"
                    }
                }
            }

            @Test(
                "export renders every strip at the CC 7 live playback sends",
                arguments: StripState.allCases, StripState.allCases,
            )
            func exportMatchesLive(_ state0: StripState, _ state1: StripState) async throws {
                let live = RecordingBackend()
                let score = Self.twoPartScore()
                let engine = try makeEngine(backend: live, score: score)
                set(state0, on: Self.staff0, in: engine)
                set(state1, on: Self.staff1, in: engine)

                let live0 = try #require(lastCC7(live, forChannel: Self.staff0, in: engine))
                let live1 = try #require(lastCC7(live, forChannel: Self.staff1, in: engine))

                // The decision both export pipelines make.
                let soloing = engine.mixerChannels.isSoloing
                let channel0 = try #require(engine.mixerChannels.first { $0.id == Self.staff0 })
                let channel1 = try #require(engine.mixerChannels.first { $0.id == Self.staff1 })
                #expect(PlaybackEngine.exportVolumeCC7(of: channel0, soloing: soloing) == live0)
                #expect(PlaybackEngine.exportVolumeCC7(of: channel1, soloing: soloing) == live1)

                // What the backend export actually sent.
                let offline = try await export(engine, score: score, live: live)
                #expect(lastCC7(offline, forChannel: Self.staff0, in: engine) == live0)
                #expect(lastCC7(offline, forChannel: Self.staff1, in: engine) == live1)
            }

            /// The case the two rules disagreed on, pinned by value rather than by comparison: the other strip is
            /// soloed too, so the file is not silent across the board and only mute can account for the zero.
            @Test("a strip both muted and soloed is silent in export")
            func mutedAndSoloedStripIsSilentInExport() async throws {
                let live = RecordingBackend()
                let score = Self.twoPartScore()
                let engine = try makeEngine(backend: live, score: score)
                set(.mutedAndSoloed, on: Self.staff0, in: engine)
                set(.soloed, on: Self.staff1, in: engine)

                let channel0 = try #require(engine.mixerChannels.first { $0.id == Self.staff0 })
                #expect(PlaybackEngine.exportVolumeCC7(of: channel0, soloing: true) == 0)

                let offline = try await export(engine, score: score, live: live)
                #expect(lastCC7(offline, forChannel: Self.staff0, in: engine) == 0)
                let other = try #require(lastCC7(offline, forChannel: Self.staff1, in: engine))
                #expect(other > 0)
            }

            // MARK: - Helpers

            private func set(_ state: StripState, on id: MixerChannel.Kind, in engine: PlaybackEngine) {
                engine.setMuted(forChannel: id, to: state.isMuted)
                engine.setSoloed(forChannel: id, to: state.isSoloed)
            }

            /// Exports `score` through the injected backend and returns the offline instance the export built.
            private func export(
                _ engine: PlaybackEngine, score: Score, live: RecordingBackend,
            ) async throws -> RecordingBackend {
                let url = AudioExportProbe.temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(to: url, score: score, format: .wav())
                return try #require(live.offlineInstance)
            }

            /// Latest CC 7 `backend` received on `id`'s MIDI channel, or `nil` if it received none. `nil` and `0` are
            /// deliberately distinct: "never addressed" is a different failure from "silenced".
            private func lastCC7(
                _ backend: RecordingBackend,
                forChannel id: MixerChannel.Kind,
                in engine: PlaybackEngine,
            ) -> UInt8? {
                guard let midiChannel = engine.midiChannel(forChannel: id) else { return nil }
                return backend.volumeSends.last { $0.channel == midiChannel }?.cc7
            }

            private func makeEngine(backend: RecordingBackend, score: Score) throws -> PlaybackEngine {
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                return engine
            }

            /// Two single-staff parts, one measure of quarters each — two instrument strips plus the metronome.
            private static func twoPartScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                func part(_ id: String, program: Int) -> Part {
                    let voice = Voice(elements: [
                        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                        .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                    ])
                    return Part(
                        id: id,
                        instrument: Instrument(
                            id: "i-\(id)", channels: [InstrumentChannel(program: program)],
                        ),
                        staves: [Staff(measures: [Measure(voices: [voice])])],
                    )
                }
                return Score(division: 480, parts: [part("p0", program: 0), part("p1", program: 40)])
            }
        }
    }

    private struct NullResolver: SoundfontResolver {
        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }
#endif
