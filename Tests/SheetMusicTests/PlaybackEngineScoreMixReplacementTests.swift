#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    extension AudioEngineSerial {
        /// A replacement that changes only a strip's own mix — what a mixer's "save to score" writes — keeps the synth,
        /// where it used to re-prepare and reload the SoundFont under playing music.
        @Suite("PlaybackEngine score mix replacement")
        @MainActor
        struct PlaybackEngineScoreMixReplacementTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            @Test("a change to a strip's own mix keeps the synth and takes the settings the score changed")
            func scoreMixEditUsesFastPath() throws {
                let original = makeScore()
                let edited = makeScore(program: 40, isMuted: true, instrumentName: "Guitar")
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                let instrument = try #require(engine.mixerChannels.first { $0.id != .metronome })
                engine.setVolume(forChannel: instrument.id, to: 0.35)
                let channel = try #require(engine.midiChannel(forChannel: instrument.id))

                let outcome = try engine.replaceScore(with: PreparedPlayback.make(score: edited))

                #expect(outcome == .swappedInPlace)
                #expect(backend.prepareCallCount == 1)
                let updated = try #require(engine.mixerChannels.first { $0.id == instrument.id })
                #expect(updated.program == 40)
                #expect(updated.isMuted)
                #expect(updated.instrumentName == "Guitar")
                // The score's level did not change, so the listener's stays.
                #expect(updated.volume == 0.35)
                #expect(backend.programSends.last?.channel == channel)
                #expect(backend.programSends.last?.program == 40)
            }

            @Test("a score mix saved from the listener's own settings keeps playing")
            func savedMixKeepsPlaying() throws {
                let original = makeScore()
                // The listener's level, written into the score as its own: 0.8 × 127 ≈ 102.
                let edited = makeScore(volume: 102)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                let instrument = try #require(engine.mixerChannels.first { $0.id != .metronome })
                engine.setVolume(forChannel: instrument.id, to: 0.8)
                engine.play(in: original)

                let outcome = try engine.replaceScore(with: PreparedPlayback.make(score: edited))

                #expect(outcome == .swappedInPlace)
                #expect(backend.prepareCallCount == 1)
                #expect(engine.state == .playing)
                let updated = try #require(engine.mixerChannels.first { $0.id == instrument.id })
                #expect(updated.volume == Float(102) / 127)
            }

            /// One 4/4 measure of quarter-note middle Cs on a one-part score whose own mix the arguments set.
            private func makeScore(
                program: Int = 0,
                volume: Int = 100,
                isMuted: Bool = false,
                instrumentName: String = "Piano",
            ) -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let measure = Measure(voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                ])])
                return Score(
                    division: 480,
                    parts: [Part(
                        id: "piano",
                        instrument: Instrument(
                            id: "piano", longName: instrumentName,
                            channels: [InstrumentChannel(program: program, volume: volume, isMuted: isMuted)],
                        ),
                        staves: [Staff(measures: [measure])],
                    )],
                    systemMeasures: IdentifiedArray([SystemMeasure()]),
                )
            }
        }
    }
#endif
