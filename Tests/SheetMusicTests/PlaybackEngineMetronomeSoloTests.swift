#if !os(Android)
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// The metronome sits OUTSIDE the solo bus. It is a reference click, not a part of the mix, so soloing an
    /// instrument must not silence it — the reported symptom was exactly that: solo a part and the click, which the
    /// host exposes as its own global toggle, went silent with the toggle still reading "on".
    ///
    /// The rule is symmetric, and both directions are pinned here: no other channel's solo silences the metronome,
    /// and the metronome cannot silence the instruments either. The Android engine already models this by keeping the
    /// click out of `mixerChannels` entirely; these tests hold the Apple engine to the same behavior.
    ///
    /// `exportEngineSnapshot().metronomeEnabled` is the observable — it reads the same
    /// `MetronomeController.isEnabled` that `applyMixerState` writes, and it is what the offline export reproduces,
    /// so asserting on it covers live playback and export in one shot. Instrument audibility is read off
    /// `RecordingBackend`'s CC 7 traffic.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine metronome vs. solo")
        @MainActor
        struct PlaybackEngineMetronomeSoloTests {
            private static let staff0 = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 0)
            private static let staff1 = MixerChannel.Kind.instrument(partIndex: 1, ordinal: 0)

            @Test("soloing a staff leaves the metronome audible")
            func soloingAStaffLeavesMetronomeAudible() throws {
                let engine = try makeEngine()
                #expect(engine.exportEngineSnapshot().metronomeEnabled == true)

                engine.setSoloed(forChannel: Self.staff0, to: true)

                #expect(engine.exportEngineSnapshot().metronomeEnabled == true)
            }

            /// Solo exemption is not a licence to ignore the metronome's own mute — that mute is how a host turns the
            /// click off, and it has to keep working while a part is soloed.
            @Test("the metronome's own mute still silences it while a staff is soloed")
            func metronomeMuteWinsWhileSoloed() throws {
                let engine = try makeEngine()
                engine.setMuted(forChannel: .metronome, to: true)
                engine.setSoloed(forChannel: Self.staff0, to: true)

                #expect(engine.exportEngineSnapshot().metronomeEnabled == false)

                // …and un-soloing doesn't smuggle the click back on.
                engine.setSoloed(forChannel: Self.staff0, to: false)
                #expect(engine.exportEngineSnapshot().metronomeEnabled == false)
            }

            /// The other half of the contract: exempting the metronome must not weaken solo between instruments.
            @Test("soloing a staff still silences the other staves")
            func soloingAStaffSilencesOtherStaves() throws {
                let backend = RecordingBackend()
                let engine = try makeEngine(backend: backend)
                backend.clearRecordings()

                engine.setSoloed(forChannel: Self.staff0, to: true)

                #expect(lastCC7(backend, forChannel: Self.staff0, in: engine) != 0)
                #expect(lastCC7(backend, forChannel: Self.staff1, in: engine) == 0)
            }

            /// The metronome is outside the solo bus in BOTH directions: its own solo flag can't put the instruments
            /// into the silenced-by-solo state. Hosts express this by hiding the solo control on a strip whose
            /// `isSoloable` is `false`; the engine enforces it regardless of what the host sends.
            @Test("soloing the metronome does not silence the staves")
            func soloingMetronomeLeavesStavesAudible() throws {
                let backend = RecordingBackend()
                let engine = try makeEngine(backend: backend)
                backend.clearRecordings()

                engine.setSoloed(forChannel: .metronome, to: true)

                #expect(lastCC7(backend, forChannel: Self.staff0, in: engine) != 0)
                #expect(lastCC7(backend, forChannel: Self.staff1, in: engine) != 0)
                let metronome = try #require(
                    engine.mixerChannels.first { $0.id == .metronome },
                )
                #expect(metronome.isSoloable == false)
                #expect(metronome.isSoloed == false)
            }

            // MARK: - Helpers

            /// Latest CC 7 the engine sent for `id`'s MIDI channel, or `nil` if it sent none. `nil` and `0` are
            /// deliberately distinct: "never addressed" is a different failure from "silenced".
            private func lastCC7(
                _ backend: RecordingBackend,
                forChannel id: MixerChannel.Kind,
                in engine: PlaybackEngine,
            ) -> UInt8? {
                guard let midiChannel = engine.midiChannel(forChannel: id) else { return nil }
                return backend.volumeSends.last { $0.channel == midiChannel }?.cc7
            }

            private func makeEngine(backend: RecordingBackend? = nil) throws -> PlaybackEngine {
                let engine = PlaybackEngine(
                    soundfontResolver: NullResolver(), backend: backend,
                )
                try engine.prepare(score: Self.twoPartScore())
                return engine
            }

            /// Two single-staff parts, one measure of quarters each — enough for a balance between staves to exist,
            /// and for `rebuildMixerChannels` to lay out two instrument strips plus the metronome.
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
