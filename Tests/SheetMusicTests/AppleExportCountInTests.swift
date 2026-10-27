#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicMIDI
    import SheetMusicMSCX
    import Testing

    /// `exportAudioFile(…, countIn: true)` puts the count live playback plays (`play(from:in:countIn:)`) in front of
    /// the music: its clicks at the metronome strip's volume whatever the metronome toggle says, and a file longer by
    /// the pre-roll at the export's rate. On both pipelines — AUMIDISynth, and a backend's offline instance.
    ///
    /// Every pre-roll below is computed from the score with `CountInBeats` itself, independently of the export, so a
    /// length that came out right by accident still has to match the count the score asks for.
    extension AudioEngineSerial {
        @Suite("Apple export count-in")
        @MainActor
        struct AppleExportCountInTests {
            private struct NoSoundFont: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            private struct FixedProvider: MetronomeClickProvider {
                let source: MetronomeClickSource
                func metronomeClickSource() -> MetronomeClickSource {
                    source
                }
            }

            private func loadScore(_ name: String) throws -> Score {
                let url = try #require(TestResources.url(forResource: name, withExtension: "mscx"))
                return try MSCXParser.parse(contentsOf: url)
            }

            /// The count a play from the top makes, on the sequence clock.
            private func preRollSeconds(of score: Score) throws -> TimeInterval {
                let plan = try #require(CountInBeats.compute(score: score, startCursor: nil))
                return plan.preRollSeconds(division: score.division)
            }

            /// Export the whole of `score` to a temporary WAV and hand back its URL; the caller removes it.
            private func export(
                _ engine: PlaybackEngine, _ score: Score, countIn: Bool,
            ) async throws -> URL {
                let url = AudioExportProbe.temporaryWAV()
                try await engine.exportAudioFile(
                    to: url, score: score,
                    format: .wav(PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo)),
                    countIn: countIn,
                )
                return url
            }

            private func seconds(of url: URL) throws -> TimeInterval {
                let file = try AVAudioFile(forReading: url)
                return Double(file.length) / file.fileFormat.sampleRate
            }

            private func exportSeconds(
                _ engine: PlaybackEngine, _ score: Score, countIn: Bool,
            ) async throws -> TimeInterval {
                let url = try await export(engine, score, countIn: countIn)
                defer { try? FileManager.default.removeItem(at: url) }
                return try seconds(of: url)
            }

            private func writeClickWav() throws -> URL {
                let wave = (0 ..< 4410).map { Int16($0 % 2 == 0 ? 14000 : -14000) }
                let data = WavTestSupport.pcm16(interleaved: wave, channels: 1, sampleRate: 44100)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("click-\(UUID().uuidString).wav")
                try data.write(to: url)
                return url
            }

            /// Clicks are note-ons on MIDI channel 9 (the GM percussion convention every backend's metronome uses).
            private func clickTicks(in midi: MidiFile?) -> [Int] {
                guard let midi else { return [] }
                return midi.tracks.flatMap { track in
                    track.events.compactMap { event -> Int? in
                        guard case let .noteOn(channel, _, velocity) = event.event,
                              channel == 9, velocity > 0
                        else { return nil }
                        return event.tick
                    }
                }.sorted()
            }

            /// One 4/4 bar of rests at 120 BPM: two seconds of music, and a count of one more bar.
            @Test func countInLengthensTheFileByThePreRoll() async throws {
                let score = try loadScore("multiPartMixedStaves")
                let engine = PlaybackEngine(soundfontResolver: NoSoundFont())
                try engine.prepare(score: score)
                let preRoll = try preRollSeconds(of: score)

                let plain = try await exportSeconds(engine, score, countIn: false)
                let counted = try await exportSeconds(engine, score, countIn: true)

                #expect(abs(plain - 2.0) < 0.01, "exported \(plain) s without a count-in")
                #expect(abs(counted - 4.0) < 0.01, "exported \(counted) s with a count-in")
                #expect(
                    abs(counted - (engine.totalTimeSeconds + preRoll)) < 0.01,
                    "exported \(counted) s, notated \(engine.totalTimeSeconds) s, pre-roll \(preRoll) s",
                )
            }

            /// The sequencer plays the pre-roll at the export rate too, so at half speed the count lasts twice as
            /// long as the music's own bar does at full speed: (2 + 2) / 0.5.
            @Test func theLengthScalesWithTheRate() async throws {
                let score = try loadScore("multiPartMixedStaves")
                let engine = PlaybackEngine(soundfontResolver: NoSoundFont())
                try engine.prepare(score: score)
                engine.setRate(0.5)

                let counted = try await exportSeconds(engine, score, countIn: true)

                #expect(abs(counted - 8.0) < 0.02, "exported \(counted) s at rate 0.5")
            }

            /// Twenty measure-plays of six notated measures: the count is one bar at the start's tempo, added once,
            /// not scaled by the unrolled length.
            @Test func countInAddsExactlyThePreRollToARepeatedScore() async throws {
                let score = try loadScore("repeat52")
                let engine = PlaybackEngine(soundfontResolver: NoSoundFont())
                try engine.prepare(score: score)
                let preRoll = try preRollSeconds(of: score)

                let plain = try await exportSeconds(engine, score, countIn: false)
                let counted = try await exportSeconds(engine, score, countIn: true)

                #expect(
                    abs((counted - plain) - preRoll) < 0.01,
                    "exported \(plain) s plain, \(counted) s counted, pre-roll \(preRoll) s",
                )
            }

            /// Counting in is an explicit request, not the metronome toggle: with the metronome off the count still
            /// sounds, and nothing clicks once the music has started.
            ///
            /// The score is one bar of rests, so anything in the file is a click. A score with notes will not do:
            /// without a SoundFont AUMIDISynth does not fall silent, it plays its seed sine tone, so `midi01`'s own
            /// notes filled every window here.
            @Test func theCountSoundsWithTheMetronomeOff() async throws {
                let score = try loadScore("multiPartMixedStaves")
                let click = try writeClickWav()
                defer { try? FileManager.default.removeItem(at: click) }
                let engine = PlaybackEngine(
                    soundfontResolver: NoSoundFont(),
                    metronomeClickProvider: FixedProvider(source: .clickSamples(strong: click, weak: click)),
                )
                try engine.prepare(score: score)
                // The toggle defaults to on (MuseScore's default); this test is about it being off.
                engine.setMetronomeEnabled(false)
                let preRoll = try preRollSeconds(of: score)

                let counted = try await export(engine, score, countIn: true)
                defer { try? FileManager.default.removeItem(at: counted) }
                let control = try await export(engine, score, countIn: false)
                defer { try? FileManager.default.removeItem(at: control) }

                let countPeak = try AudioExportProbe.peakAmplitude(of: counted, from: 0, to: preRoll)
                #expect(countPeak > 1e-4, "the count's window peaked at \(countPeak)")
                // The music is the file's last `totalTimeSeconds`; skip its first 0.2 s, where the count's last click
                // may still ring. Anchored at the end of the file rather than at `preRoll + 0.2`, so a file the
                // count never lengthened still has this window — its length is the length tests' to report.
                let end = try seconds(of: counted)
                let bodyPeak = try AudioExportProbe.peakAmplitude(
                    of: counted, from: end - engine.totalTimeSeconds + 0.2, to: end,
                )
                #expect(bodyPeak < 1e-5, "the music's window peaked at \(bodyPeak)")
                let controlPeak = try AudioExportProbe.peakAmplitude(of: control, from: 0, to: preRoll)
                #expect(controlPeak < 1e-5, "without a count-in the opening peaked at \(controlPeak)")
            }

            /// On the backend path the count rides the metronome transport, exactly as `startBackendCountIn` plays
            /// it live: loaded with the pre-roll's clicks ahead of the body's, muted as the toggle says (the backend
            /// sounds the count regardless), and the score held for the pre-roll.
            @Test func theBackendCountsInOnItsMetronomeTransport() async throws {
                let score = try loadScore("multiPartMixedStaves")
                let live = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NoSoundFont(), backend: live)
                try engine.prepare(score: score)
                engine.setMetronomeEnabled(false)

                let plainSeconds = try await exportSeconds(engine, score, countIn: false)
                let plain = try #require(live.offlineInstance)
                #expect(plain.countInSeconds == nil)
                #expect(abs(plainSeconds - 2.0) < 0.01, "exported \(plainSeconds) s without a count-in")
                let plainClicks = clickTicks(in: plain.lastMetronomeSequence)

                let countedSeconds = try await exportSeconds(engine, score, countIn: true)
                let offline = try #require(live.offlineInstance)
                #expect(offline !== plain)
                let countIn = try #require(offline.countInSeconds)
                #expect(abs(countIn - 2.0) < 0.001, "held the score for \(countIn) s")
                #expect(offline.metronomeMuted == true)
                let ticks = clickTicks(in: offline.lastMetronomeSequence)
                #expect(ticks.first == 0)
                #expect(ticks.count >= 4)
                // The count's clicks come on top of the body's own, which the plain export already carries.
                #expect(ticks.count > plainClicks.count, "\(ticks.count) clicks counted, \(plainClicks.count) plain")
                #expect(abs(offline.metronomeOffsetSeconds - 2.0) < 0.001)
                #expect(offline.seekCalls == [0])
                #expect(abs(countedSeconds - 4.0) < 0.01, "exported \(countedSeconds) s with a count-in")
            }
        }
    }
#endif
