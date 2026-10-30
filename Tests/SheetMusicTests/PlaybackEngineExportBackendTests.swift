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

            /// The offline transport runs the UNROLLED render while the range is notated ticks: without the projection
            /// a range after a repeat would start on whatever the sequence plays that many notated seconds in.
            @Test("The offline instance gets the unrolled time map, so a range after a repeat starts where it should")
            func offlineInstanceGetsTheUnrolledTimeMap() async throws {
                // |: m1 :| m2, 4/4 quarters at 120 BPM: m2 starts 2 s into the notation and 4 s into the playback.
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let first = Voice(elements: [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                    + Array(repeating: VoiceElement.chord(quarter), count: 4))
                let second = Voice(elements: Array(repeating: VoiceElement.chord(quarter), count: 4))
                let part = Part(
                    id: "p", instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [
                        Measure(voices: [first], startRepeat: true, endRepeatCount: 2), Measure(voices: [second]),
                    ])],
                )
                let score = Score(division: 480, parts: [part])
                let live = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: live)
                try engine.prepare(score: score)

                let url = temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(
                    to: url, score: score, format: .wav(),
                    range: .region(
                        from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 1, tickInMeasure: 1920),
                    ),
                )

                let offline = try #require(live.offlineInstance)
                let map = try #require(offline.unrolledTimeMap)
                #expect(abs(map.unrolledSeconds(fromNotated: 2) - 4) < 1e-9)
                #expect(offline.seekCalls == [1920])
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

            /// Audio and video export render through the backend, so they choke as playback does: the sequence the
            /// offline instance is handed carries the choke marker the SMF export leaves out.
            @Test("The export sequence carries the choke marker")
            func exportSequenceCarriesTheChoke() async throws {
                let score = RevoiceFixtures.editingChord(
                    RevoiceFixtures.score([["C/4 r/4 r/2"]]), measure: 0, voice: 0, element: 1,
                ) { $0.articulations = [ChordArticulation(kind: .chokeCymbal)] }
                let live = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: live)
                try engine.prepare(score: score)

                let url = temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(to: url, score: score, format: .wav())

                let sequence = try #require(live.offlineInstance?.lastSequence)
                let chokes = sequence.tracks.flatMap(\.events).filter {
                    if case let .controlChange(_, controller, value) = $0.event {
                        return controller == ChokeMarker.controller && value == 49
                    }
                    return false
                }
                #expect(chokes.count == 1)
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

    /// Minimal transport-only double whose `makeOfflineInstance` returns `nil` — the fallback contract for a backend
    /// that can't render offline.
    @MainActor
    private final class OfflinelessBackend: SynthBackendTestDouble {
        let outputNode: AVAudioNode = AVAudioMixerNode()
        var currentPositionSeconds: TimeInterval = 0
        var currentTick = 0

        func attach(to engine: AVAudioEngine) {
            engine.attach(outputNode)
        }

        /// Spelled out rather than taken from `SynthBackendTestDouble`: returning `nil` is what this double is for.
        func makeOfflineInstance(sampleRate _: Double) -> (any SynthBackend)? {
            nil
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
