#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// The mixer is the *sole* authority on a staff channel's volume / program: their tick-0 CC 7 and
    /// programChange are stripped from the SMF (`postProcessForMIDISynth`) so the transport's
    /// controller chase can't clobber the user's balance. The flip side is that any transport
    /// operation which resets the synth's channels — every backend seek does, because SwiftySynth's
    /// `MidiFileSequencer.seek` calls `Synthesizer.reset()` — leaves those channels at the GM
    /// default (CC 7 = 100) with nothing in the SMF to restore them. Every other `backend.seek`
    /// call site re-asserts the mixer afterwards; these tests pin that `seek(to:)` (and therefore
    /// `skip(by:)`, the lock-screen ±10 s / scrubber entry point) does too.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine backend seek mixer re-assert")
        @MainActor
        struct PlaybackEngineBackendSeekMixerTests {
            /// Transport-only backend that also records the per-channel mixer traffic it receives,
            /// so a test can assert what was re-sent after a seek.
            @MainActor
            private final class RecordingBackend: SynthBackend {
                let outputNode: AVAudioNode = AVAudioMixerNode()
                var currentPositionSeconds: TimeInterval = 0
                var isAtEnd = false
                private(set) var volumeSends: [(channel: UInt8, cc7: UInt8)] = []
                private(set) var programSends: [(channel: UInt8, program: UInt8)] = []
                private var timeline: PlaybackTimeline?

                func clearRecordings() {
                    volumeSends.removeAll()
                    programSends.removeAll()
                }

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
                    guard let timeline else { return }
                    currentPositionSeconds = timeline.seconds(atTick: Double(tick))
                }

                func setRate(_: Float) {}
                func setTuning(cents _: Double, transposeSemitones _: Int) {}
                func setProgram(channel: UInt8, program: UInt8) {
                    programSends.append((channel, program))
                }

                func sendVolume(channel: UInt8, cc7: UInt8) {
                    volumeSends.append((channel, cc7))
                }

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

            /// Two-part score (so a *balance* between staves exists), four measures of quarters each.
            private func makeTwoStaffScore() -> Score {
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
                func part(_ id: String, program: Int) -> Part {
                    Part(
                        id: id,
                        instrument: Instrument(
                            id: "i-\(id)", channels: [InstrumentChannel(program: program)],
                        ),
                        staves: [Staff(measures: [
                            measure(first: true), measure(), measure(), measure(),
                        ])],
                    )
                }
                return Score(division: 480, parts: [part("p0", program: 0), part("p1", program: 40)])
            }

            private func makeEngine(
                _ backend: RecordingBackend, _ score: Score,
            ) throws -> PlaybackEngine {
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                return engine
            }

            /// The reported bug: adjust the balance, then skip back 10 s from the lock screen — the
            /// mix went flat because nothing re-sent the mixer's CC 7 after the seek reset the synth.
            @Test("skip(by:) while playing re-asserts the mixer's staff volumes")
            func skipWhilePlayingReassertsVolumes() throws {
                let backend = RecordingBackend()
                let score = makeTwoStaffScore()
                let engine = try makeEngine(backend, score)
                engine.play(in: score)
                engine.setVolume(forChannel: .instrument(partIndex: 0, ordinal: 0), to: 0.25)
                engine.setVolume(forChannel: .instrument(partIndex: 1, ordinal: 0), to: 1.0)
                backend.clearRecordings()

                engine.skip(by: -engine.totalTimeSeconds / 4)

                #expect(backend.volumeSends.contains { $0.cc7 == 32 }) // 0.25 → 31.75 → 32
                #expect(backend.volumeSends.contains { $0.cc7 == 127 }) // 1.0
            }

            /// Same for a seek taken while paused: the lock-screen scrubber works paused too, and the
            /// next `play()` must not be the first thing that restores the balance.
            @Test("skip(by:) while paused re-asserts the mixer's staff volumes")
            func skipWhilePausedReassertsVolumes() throws {
                let backend = RecordingBackend()
                let score = makeTwoStaffScore()
                let engine = try makeEngine(backend, score)
                engine.play(in: score)
                engine.pause()
                engine.setVolume(forChannel: .instrument(partIndex: 0, ordinal: 0), to: 0.25)
                backend.clearRecordings()

                engine.skip(by: engine.totalTimeSeconds / 4)

                #expect(backend.volumeSends.contains { $0.cc7 == 32 })
            }

            /// A mute is CC 7 = 0 through the same path, so it dies the same way — the muted staff
            /// came back at full level after a skip.
            @Test("skip(by:) re-asserts a muted staff")
            func skipReassertsMute() throws {
                let backend = RecordingBackend()
                let score = makeTwoStaffScore()
                let engine = try makeEngine(backend, score)
                engine.play(in: score)
                engine.setMuted(forChannel: .instrument(partIndex: 0, ordinal: 0), to: true)
                backend.clearRecordings()

                engine.skip(by: engine.totalTimeSeconds / 2)

                #expect(backend.volumeSends.contains { $0.cc7 == 0 })
            }

            /// `Synthesizer.reset()` also drops each channel back to program 0, and the SMF's tick-0
            /// programChange is stripped for mixer-managed channels — so without a re-assert every
            /// staff sounds as Acoustic Grand Piano after a skip.
            @Test("skip(by:) re-asserts the mixer's staff programs")
            func skipReassertsPrograms() throws {
                let backend = RecordingBackend()
                let score = makeTwoStaffScore()
                let engine = try makeEngine(backend, score)
                engine.play(in: score)
                backend.clearRecordings()

                engine.skip(by: engine.totalTimeSeconds / 2)

                #expect(backend.programSends.contains { $0.program == 40 })
            }
        }
    }
#endif
