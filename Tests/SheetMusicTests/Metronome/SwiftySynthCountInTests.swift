#if canImport(SwiftySynth)
    import AVFoundation
    import Foundation
    import SheetMusic
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicAudioSwiftySynth
    import SheetMusicMIDI
    import SheetMusicMSCX
    import Testing

    extension AudioEngineSerial {
        /// What a count-in has to sound like on the backend, measured off the render thread
        /// rather than inferred from the sequences.
        ///
        /// Two things it used to get wrong, both because the count was baked into the SCORE
        /// SMF: it clicked through the score's SoundFont (GM wood blocks, never the host's
        /// click samples — only the metronome synth loads those), and it was skipped whenever a
        /// loop was active. The count now runs on the metronome transport while the backend
        /// holds the score transport for the length of the pre-roll.
        ///
        /// Same discriminator as `SwiftySynthMetronomeClickTests`: a click SF2 holding a 1.5 s
        /// square wave, at a tempo slow enough that a GM wood block would have decayed long
        /// before the window being measured.
        @Suite("SwiftySynth count-in")
        @MainActor
        struct SwiftySynthCountInTests {
            private static let sampleRate = 44100.0
            private static let gmSoundfont = URL(fileURLWithPath: swiftySynthSoundfontPath)
            /// 100 ms per rendered chunk, so a chunk index is a tenth of a second.
            private static let chunkFrames: AVAudioFrameCount = 4410

            private func writeLongClickSoundFont() throws -> URL {
                let wave = (0 ..< 66150).map { i -> Int16 in
                    (i / 100) % 2 == 0 ? 16000 : -16000
                }
                let sf2 = ClickSoundFontBuilder.build(
                    strong: wave, strongRate: 44100, weak: wave, weakRate: 44100,
                )
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("count-in-click-\(UUID().uuidString).sf2")
                try sf2.write(to: url)
                return url
            }

            private func awaitReady(_ backend: SwiftySynthBackend) async throws {
                for _ in 0 ..< 250 {
                    if backend.isReady { return }
                    try await Task.sleep(for: .milliseconds(20))
                }
                Issue.record("SwiftySynthBackend never became ready")
            }

            /// A score SMF holding one long, loud note at tick 0 — so any sound during the
            /// pre-roll window that is not the click is the body having started early.
            private func scoreSequence() -> SheetMusicMIDI.MidiFile {
                SheetMusicMIDI.MidiFile(division: 480, tracks: [
                    MidiTrack(events: [
                        // 8 s per quarter: one beat is 8 s, so nothing else can intrude on the
                        // windows measured below.
                        TimedMidiEvent(
                            tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 8_000_000)),
                        ),
                        TimedMidiEvent(
                            tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 127),
                        ),
                        TimedMidiEvent(
                            tick: 960, event: .noteOff(channel: 0, pitch: 60, velocity: 0),
                        ),
                    ]),
                ])
            }

            /// Render `chunks` x 100 ms of a count-in playback and return the peak per chunk.
            ///
            /// - Parameters:
            ///   - preRollSeconds: how long the backend must hold the score transport.
            ///   - metronomeMuted: the host's metronome toggle. `true` is the case that matters —
            ///     a count-in is asked for explicitly and has to sound anyway.
            ///   - metronomeVolume: set to 0 to silence the click and measure the score alone.
            private func envelope(
                preRollSeconds: TimeInterval,
                metronomeMuted: Bool,
                metronomeVolume: Float? = nil,
                clickSoundfont: URL?,
                chunks: Int,
            ) async throws -> [Float] {
                let backend = SwiftySynthBackend(sampleRate: Self.sampleRate)
                backend.prepare(
                    soundfontURL: Self.gmSoundfont,
                    metronomeSoundfontURL: clickSoundfont,
                    drumChannels: [],
                )
                try await awaitReady(backend)

                let scoreURL = try #require(
                    Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
                )
                let score = try MSCXParser.parse(contentsOf: scoreURL)
                let rendered = scoreSequence()
                backend.loadSequence(rendered, timeline: PlaybackTimeline(score: score))
                // The count's own clicks, filling the pre-roll ahead of the (absent) body beats —
                // the shape `PlaybackEngine.startBackendCountIn` loads.
                backend.loadMetronomeSequence(
                    PreRollSequenceAssembler.metronomeOnly(
                        rendered: rendered,
                        metronomeBeats: [],
                        plan: CountInBeats.Result(
                            preRollTicks: 480,
                            beats: [MetronomeBeat(tick: 0, isDownbeat: true)],
                            quarterBpm: 7.5, // 8 s per quarter
                        ),
                        baseTick: 0,
                        includingPreRollClicks: true,
                    ),
                    offsetSeconds: preRollSeconds,
                )
                backend.setMetronomeMuted(metronomeMuted)
                if let metronomeVolume { backend.setMetronomeVolume(metronomeVolume) }

                let engine = AVAudioEngine()
                let format = try #require(AVAudioFormat(
                    standardFormatWithSampleRate: Self.sampleRate, channels: 2,
                ))
                engine.attach(backend.sourceNode)
                engine.connect(backend.sourceNode, to: engine.mainMixerNode, format: format)
                try engine.enableManualRenderingMode(
                    .offline, format: format, maximumFrameCount: Self.chunkFrames,
                )
                try engine.start()
                backend.play(afterCountInSeconds: preRollSeconds)

                let buffer = try #require(AVAudioPCMBuffer(
                    pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.chunkFrames,
                ))
                var peaks: [Float] = []
                for _ in 0 ..< chunks {
                    var peak: Float = 0
                    let status = try engine.renderOffline(Self.chunkFrames, to: buffer)
                    if status == .success, let ch = buffer.floatChannelData {
                        for i in 0 ..< Int(buffer.frameLength) {
                            peak = max(peak, abs(ch[0][i]))
                        }
                    }
                    peaks.append(peak)
                }
                engine.stop()
                engine.disableManualRenderingMode()
                return peaks
            }

            @Test(
                "the count sounds with the host's click SoundFont even with the metronome off",
                .enabled(if: swiftySynthGMSoundfontAvailable),
            )
            func countInUsesTheHostClickWhileMuted() async throws {
                let click = try writeLongClickSoundFont()
                defer { try? FileManager.default.removeItem(at: click) }
                let peaks = try await envelope(
                    preRollSeconds: 1.4, metronomeMuted: true,
                    clickSoundfont: click, chunks: 10,
                )
                // 0.4 s - 0.9 s: the click SF2's 1.5 s sample is still going; a GM wood block
                // (what the score synth would have played) is long gone by then.
                let sustain = peaks[4 ... 9].min() ?? 0
                let message = "the count must sound the host's click even with the metronome "
                    + "toggle off: \(peaks)"
                #expect(sustain > 0.001, Comment(rawValue: message))
            }

            @Test(
                "the score stays silent until the count-in ends",
                .enabled(if: swiftySynthGMSoundfontAvailable),
            )
            func scoreTransportIsHeldForThePreRoll() async throws {
                // Volume 0 silences the click, so everything measured here is the score.
                let peaks = try await envelope(
                    preRollSeconds: 0.5, metronomeMuted: true, metronomeVolume: 0,
                    clickSoundfont: nil, chunks: 10,
                )
                let message = "the body must not start before the count ends: \(peaks)"
                #expect((peaks[0 ... 3].max() ?? 1) < 0.0001, Comment(rawValue: message))
                #expect((peaks[6 ... 9].min() ?? 0) > 0.001, Comment(rawValue: message))
            }
        }
    }
#endif
