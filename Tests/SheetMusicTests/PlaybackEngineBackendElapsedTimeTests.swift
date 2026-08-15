#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// `currentTimeSeconds` / `currentTimeSecondsContinuous` are the elapsed-time readers that
    /// drive a host's scrubber (folino publishes them as
    /// `MPNowPlayingInfoPropertyElapsedPlaybackTime`). On the injected-backend path both read
    /// through `backend.currentTick`, which carries the same two defects the cursor poll had:
    /// it is a NOTATED `frame(atTime:)` lookup of an UNROLLED position, and `frame(atTime:)`
    /// clamps to the last frame — so on a repeat score the reported time runs ahead from the
    /// second pass on, and it freezes entirely once the transport passes the notated duration.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine backend elapsed time")
        @MainActor
        struct PlaybackEngineBackendElapsedTimeTests {
            @MainActor
            private final class TransportBackend: SynthBackend {
                let outputNode: AVAudioNode = AVAudioMixerNode()
                var currentPositionSeconds: TimeInterval = 0
                var isAtEnd = false
                private var timeline: PlaybackTimeline?

                /// Derived exactly as `SwiftySynthBackend` derives it — a NOTATED
                /// `frame(atTime:)` lookup of the transport's position, which is what makes it
                /// both unroll-blind and saturating. Stubbing this as a stored `0` would hide
                /// the very defect under test.
                var currentTick: Int {
                    guard let timeline else { return 0 }
                    return timeline.frame(atTime: currentPositionSeconds)?.tick ?? 0
                }

                func attach(to engine: AVAudioEngine) {
                    engine.attach(outputNode)
                }

                func prepare(
                    soundfontURL _: URL?, metronomeSoundfontURL _: URL?, drumChannels _: Set<UInt8>,
                ) {}
                func loadSequence(_: MidiFile, timeline: PlaybackTimeline) {
                    self.timeline = timeline
                }

                func loadMetronomeSequence(_: MidiFile, offsetSeconds _: TimeInterval) {}
                func setMetronomeMuted(_: Bool) {}
                func play() {}
                func pause() {}
                func stop() {}
                func seek(toTick tick: Int) {
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

            /// Same fixture as the cursor tests: `[m0, m1(||:x2:||), m2]`, four quarters each.
            /// Notated 5760 ticks / 3 measures; unrolled 7680 ticks / 4 measure-plays.
            private func makeRepeatScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                func measure(startRepeat: Bool = false, endRepeat: Int? = nil, first: Bool = false) -> Measure {
                    var elements: [VoiceElement] = []
                    if first {
                        elements.append(.timeSignature(TimeSignature(numerator: 4, denominator: 4)))
                    }
                    elements.append(contentsOf: [
                        .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                    ])
                    return Measure(
                        voices: [Voice(elements: elements)],
                        startRepeat: startRepeat,
                        endRepeatCount: endRepeat,
                    )
                }
                let part = Part(
                    id: "p",
                    instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [
                        measure(first: true),
                        measure(startRepeat: true, endRepeat: 2),
                        measure(),
                    ])],
                )
                return Score(division: 480, parts: [part])
            }

            private func makeEngine(
                _ backend: TransportBackend, _ score: Score,
            ) throws -> PlaybackEngine {
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                engine.play(in: score)
                return engine
            }

            @Test("elapsed time reports the repeated measure's notated time during the second pass")
            func elapsedTimeFollowsRepeatSecondPass() throws {
                let backend = TransportBackend()
                let score = makeRepeatScore()
                let engine = try makeEngine(backend, score)
                let measureSeconds = engine.totalTimeSeconds / 3

                // Transport at unrolled tick 4800 — 3rd quarter of m1's SECOND pass, notating
                // to tick 2880. Snapped to that frame, its notated time is 1.5 measures in.
                backend.currentPositionSeconds = measureSeconds * 2.5

                #expect(abs(engine.currentTimeSeconds - measureSeconds * 1.5) < 0.001)
                #expect(abs(engine.currentTimeSecondsContinuous - measureSeconds * 1.5) < 0.001)
            }

            @Test("elapsed time keeps advancing past the notated duration instead of freezing")
            func elapsedTimeDoesNotFreezePastNotatedDuration() throws {
                let backend = TransportBackend()
                let score = makeRepeatScore()
                let engine = try makeEngine(backend, score)
                let measureSeconds = engine.totalTimeSeconds / 3

                // Unrolled 3.25 and 3.75 measure-plays in — both inside the FINAL measure-play
                // (m2) but past the notated duration, where `frame(atTime:)` clamps. The
                // reported time must differ between the two, not sit on the same last frame.
                backend.currentPositionSeconds = measureSeconds * 3.25
                let earlier = engine.currentTimeSecondsContinuous
                backend.currentPositionSeconds = measureSeconds * 3.75
                let later = engine.currentTimeSecondsContinuous

                #expect(later > earlier)
                // m2 spans notated [2, 3) measures, so 3.75 unrolled → 2.75 notated.
                #expect(abs(later - measureSeconds * 2.75) < 0.001)
            }

            @Test("continuous reader is genuinely continuous, not quantized to note onsets")
            func continuousReaderResolvesBelowAFrame() throws {
                let backend = TransportBackend()
                let score = makeRepeatScore()
                let engine = try makeEngine(backend, score)
                let measureSeconds = engine.totalTimeSeconds / 3
                let quarterSeconds = measureSeconds / 4

                // Two positions inside the SAME quarter-note frame. The snapping reader must
                // collapse them; the continuous one must not.
                backend.currentPositionSeconds = quarterSeconds * 0.25
                let a = engine.currentTimeSecondsContinuous
                backend.currentPositionSeconds = quarterSeconds * 0.75
                let b = engine.currentTimeSecondsContinuous

                #expect(b > a)
            }
        }
    }
#endif
