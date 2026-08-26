#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    import SheetMusic
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicAudioSwiftySynth
    import SheetMusicCore
    import SheetMusicMIDI
    import SheetMusicMSCX
    import Testing

    /// `exportAudioFile` must render through the injected `SynthBackend`, not
    /// through AUMIDISynth.
    ///
    /// Regression: the export pipeline predates the backend seam and built its
    /// own AUMIDISynth unconditionally, so a host that injected
    /// `SwiftySynthBackend` to escape AUMIDISynth's voice stealing still got a
    /// stolen-voice (and ~20 dB louder) export. Every test here fails against
    /// that build.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine.exportAudioFile (injected backend)")
        @MainActor
        struct PlaybackEngineExportBackendTests {
            @Test("Export drives the backend's offline instance, not AUMIDISynth")
            func exportUsesOfflineBackendInstance() async throws {
                let score = try loadScore()
                let live = RecordingBackend()
                let engine = PlaybackEngine(
                    soundfontResolver: NullResolver(), backend: live,
                )
                try engine.prepare(score: score)

                let url = temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(
                    to: url, score: score, format: .wav(),
                )

                let offline = try #require(live.offlineInstance)
                // A distinct instance: the live transport must be left alone.
                #expect(offline !== live)
                #expect(offline.lastSequence != nil)
                #expect(offline.didPlay)
                #expect(offline.seekCalls == [0])
                // The live backend was never driven by the export.
                #expect(!live.didPlay)
                #expect(live.lastSequence == nil)
                #expect(try AVAudioFile(forReading: url).length > 0)
                #expect(engine.state == .stopped)
            }

            @Test("Offline instance is built at the export's own sample rate")
            func offlineInstanceGetsExportSampleRate() async throws {
                let score = try loadScore()
                let live = RecordingBackend()
                let engine = PlaybackEngine(
                    soundfontResolver: NullResolver(), backend: live,
                )
                try engine.prepare(score: score)

                let url = temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(
                    to: url,
                    score: score,
                    format: .wav(
                        PCMOptions(
                            sampleRate: 22050, bitDepth: .int16, channels: .stereo,
                        ),
                    ),
                )
                #expect(live.offlineSampleRate == 22050)
            }

            @Test("Muted strip is silenced on the offline backend")
            func mutedStripReachesOfflineBackend() async throws {
                let score = try loadScore()
                let live = RecordingBackend()
                let engine = PlaybackEngine(
                    soundfontResolver: NullResolver(), backend: live,
                )
                try engine.prepare(score: score)
                let strip = try #require(
                    engine.mixerChannels.first { $0.id != .metronome }?.id,
                )
                engine.setMuted(forChannel: strip, to: true)

                let url = temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(
                    to: url, score: score, format: .wav(),
                )

                let offline = try #require(live.offlineInstance)
                // Every CC 7 the export sent for an instrument strip was zero:
                // this score's only instrument strip is the muted one.
                #expect(!offline.volumeSends.isEmpty)
                #expect(offline.volumeSends.allSatisfy { $0.cc7 == 0 })
            }

            @Test("Metronome state is carried onto the offline backend")
            func metronomeStateReachesOfflineBackend() async throws {
                let score = try loadScore()
                let live = RecordingBackend()
                let engine = PlaybackEngine(
                    soundfontResolver: NullResolver(), backend: live,
                )
                try engine.prepare(score: score)
                engine.setMetronomeEnabled(true)

                let url = temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(
                    to: url, score: score, format: .wav(),
                )

                let offline = try #require(live.offlineInstance)
                // The click rides the backend's OWN metronome transport, not a
                // track appended to the score SMF (that is the AUMIDISynth shape).
                #expect(offline.lastMetronomeSequence != nil)
                #expect(offline.metronomeMuted == false)
            }

            @Test("A backend without an offline instance still exports (AU fallback)")
            func offlinelessBackendFallsBackToAUMIDISynth() async throws {
                let score = try loadScore()
                let live = OfflinelessBackend()
                let engine = PlaybackEngine(
                    soundfontResolver: NullResolver(), backend: live,
                )
                try engine.prepare(score: score)

                let url = temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(
                    to: url, score: score, format: .wav(),
                )
                #expect(try AVAudioFile(forReading: url).length > 0)
                #expect(engine.state == .stopped)
            }

            /// The claim the recording doubles can't make: a real
            /// `SwiftySynthBackend`, pulled by `AVAudioEngine` in manual
            /// rendering mode, actually writes audio into the export file.
            /// Silence here would mean the whole path is wired but mute.
            @Test(.enabled(if: swiftySynthAssetsAvailable))
            func realBackendExportIsNotSilent() async throws {
                let score = try SheetMusic.loadScore(
                    msczURL: URL(fileURLWithPath: swiftySynthShinogonoPath),
                )
                let engine = PlaybackEngine(
                    soundfontResolver: FixedSoundfontResolver(
                        url: URL(fileURLWithPath: swiftySynthSoundfontPath),
                    ),
                    backend: SwiftySynthBackend(),
                )
                try engine.prepare(score: score)

                let url = temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(
                    to: url,
                    score: score,
                    format: .wav(),
                    // The opening bar is enough — a full render of this score
                    // would dominate the suite's runtime for no extra signal.
                    range: .region(
                        from: .beat(measureIndex: 0, tickInMeasure: 0),
                        to: .beat(measureIndex: 2, tickInMeasure: 0),
                    ),
                )
                #expect(try AudioExportProbe.peakAmplitude(of: url) > 0.001)
            }

            private func loadScore() throws -> Score {
                let url = try #require(
                    TestResources.url(forResource: "midi01", withExtension: "mscx"),
                )
                return try MSCXParser.parse(contentsOf: url)
            }

            private func temporaryWAV() -> URL {
                AudioExportProbe.temporaryWAV()
            }
        }
    }

    /// `SwiftySynthBackend` is the reason this seam exists — assert it actually
    /// opts in, and at the rate it was asked for. Without a running engine, so
    /// this suite stays outside `AudioEngineSerial`.
    @Suite("SwiftySynthBackend.makeOfflineInstance")
    @MainActor
    struct SwiftySynthOfflineInstanceTests {
        @Test("Returns a second SwiftySynthBackend at the requested sample rate")
        func offlineInstanceHonorsSampleRate() throws {
            let live = SwiftySynthBackend(sampleRate: 44100)
            let offline = try #require(
                live.makeOfflineInstance(sampleRate: 48000) as? SwiftySynthBackend,
            )
            #expect(offline !== live)
            #expect(offline.sampleRate == 48000)
            // The live instance is untouched.
            #expect(live.sampleRate == 44100)
        }
    }

    /// Minimal transport-only double that leaves `makeOfflineInstance` at its
    /// protocol default (`nil`) — the fallback contract for a backend that
    /// can't render offline.
    @MainActor
    private final class OfflinelessBackend: SynthBackend {
        let outputNode: AVAudioNode = AVAudioMixerNode()
        var currentPositionSeconds: TimeInterval = 0
        var currentTick = 0

        func attach(to engine: AVAudioEngine) {
            engine.attach(outputNode)
        }

        func prepare(
            soundfontURL _: URL?, metronomeSoundfontURL _: URL?, drumChannels _: Set<UInt8>,
        ) {}
        func loadSequence(_: MidiFile, timeline _: PlaybackTimeline) {}
        func loadMetronomeSequence(_: MidiFile, offsetSeconds _: TimeInterval) {}
        func setMetronomeMuted(_: Bool) {}
        func play() {}
        func pause() {}
        func stop() {}
        func seek(toTick _: Int) {}
        func setRate(_: Float) {}
        func setTuning(cents _: Double, transposeSemitones _: Int) {}
        func setProgram(channel _: UInt8, program _: UInt8) {}
        func sendVolume(channel _: UInt8, cc7 _: UInt8) {}
        func startNote(channel _: UInt8, pitch _: UInt8, velocity _: UInt8) {}
        func stopNote(channel _: UInt8, pitch _: UInt8) {}
        func teardown() {}
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
