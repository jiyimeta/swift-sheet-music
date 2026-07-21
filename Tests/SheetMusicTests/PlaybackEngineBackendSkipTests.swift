#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// `skip(by:)` is the relative-seek entry point behind a host's seek bar, the lock-screen
    /// scrubber (`changePlaybackPositionCommand`), and the ±N-second skip buttons. On the
    /// injected-backend path the AUMIDISynth `AVAudioSequencer` is never built, so a `skip(by:)`
    /// that guards on `sequencer` — as its sibling `seek(to:)` does NOT — silently no-ops and the
    /// transport never moves. These tests pin that the resolved target actually reaches the
    /// backend transport, both while playing and while paused.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine backend skip")
        @MainActor
        struct PlaybackEngineBackendSkipTests {
            /// Minimal transport-only backend: `seek(toTick:)` moves its own seconds clock, which
            /// is exactly what `currentTimeSeconds` reads back. If `skip` fails to reach the
            /// backend, that clock stays at 0 and the assertions below catch it.
            @MainActor
            private final class TransportBackend: SynthBackend {
                let outputNode: AVAudioNode = AVAudioMixerNode()
                var currentPositionSeconds: TimeInterval = 0
                var isAtEnd = false
                private(set) var seekCallCount = 0
                private var timeline: PlaybackTimeline?

                var currentTick: Int {
                    guard let timeline else { return 0 }
                    return timeline.frame(atTime: currentPositionSeconds)?.tick ?? 0
                }

                func attach(to engine: AVAudioEngine) {
                    engine.attach(outputNode)
                }

                func prepare(soundfontURL _: URL?, drumChannels _: Set<UInt8>) {}
                func loadSequence(_: MidiFile, timeline: PlaybackTimeline) {
                    self.timeline = timeline
                }

                func loadMetronomeSequence(_: MidiFile) {}
                func setMetronomeMuted(_: Bool) {}
                func play() {}
                func pause() {}
                func stop() {}
                func seek(toTick tick: Int) {
                    seekCallCount += 1
                    guard let timeline else { return }
                    currentPositionSeconds = timeline.seconds(atTick: Double(tick))
                }

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

            /// Plain four-measure score, four quarters each, no repeats — 7680 notated ticks.
            private func makeFourMeasureScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                func measure(first: Bool = false) -> Measure {
                    var elements: [VoiceElement] = []
                    if first {
                        elements.append(.timeSignature(TimeSignature(numerator: 4, denominator: 4)))
                    }
                    elements.append(contentsOf: [
                        .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                    ])
                    return Measure(voices: [Voice(elements: elements)])
                }
                let part = Part(
                    id: "p",
                    instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [measure(first: true), measure(), measure(), measure()])],
                )
                return Score(division: 480, parts: [part])
            }

            private func makeEngine(_ backend: TransportBackend, _ score: Score) throws -> PlaybackEngine {
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                return engine
            }

            @Test("skip(by:) moves the injected backend transport while playing")
            func skipWhilePlayingMovesBackend() throws {
                let backend = TransportBackend()
                let score = makeFourMeasureScore()
                let engine = try makeEngine(backend, score)
                engine.play(in: score)
                #expect(abs(engine.currentTimeSeconds) < 0.001) // starts at the top

                let measureSeconds = engine.totalTimeSeconds / 4
                engine.skip(by: measureSeconds * 2) // +2 measures

                #expect(backend.seekCallCount > 0)
                #expect(abs(engine.currentTimeSeconds - measureSeconds * 2) < 0.05)
            }

            @Test("skip(by:) moves the injected backend transport while paused")
            func skipWhilePausedMovesBackend() throws {
                let backend = TransportBackend()
                let score = makeFourMeasureScore()
                let engine = try makeEngine(backend, score)
                engine.play(in: score)
                engine.pause()

                let measureSeconds = engine.totalTimeSeconds / 4
                engine.skip(by: measureSeconds * 2)

                #expect(backend.seekCallCount > 0)
                #expect(abs(engine.currentTimeSeconds - measureSeconds * 2) < 0.05)
            }

            @Test("backward skip(by:) moves the injected backend transport toward the start")
            func backwardSkipMovesBackend() throws {
                let backend = TransportBackend()
                let score = makeFourMeasureScore()
                let engine = try makeEngine(backend, score)
                engine.play(in: score)

                let measureSeconds = engine.totalTimeSeconds / 4
                engine.skip(by: measureSeconds * 3) // jump to m3
                #expect(abs(engine.currentTimeSeconds - measureSeconds * 3) < 0.05)

                engine.skip(by: -measureSeconds * 2) // back to m1
                #expect(abs(engine.currentTimeSeconds - measureSeconds) < 0.05)
            }
        }
    }
#endif
