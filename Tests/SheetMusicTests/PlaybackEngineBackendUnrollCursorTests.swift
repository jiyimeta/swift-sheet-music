#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// The injected-backend cursor poll reads the transport's position and looks it up in
    /// `PlaybackTimeline` — but the transport plays the UNROLLED SMF (`MidiRenderer.render`,
    /// repeats and jumps expanded) while the timeline is NOTATED. `backendTickCursor` does no
    /// `unroll.notatedTick(fromUnrolled:)` translation, unlike the AUMIDISynth `tickCursor`
    /// (which applies it before the frame lookup and compares against
    /// `unroll.totalUnrolledTicks`).
    ///
    /// Consequence on any score with a repeat: from the second pass onward the cursor runs a
    /// full measure-play ahead of the audio, and once the unrolled position passes the notated
    /// duration it saturates on the last frame and stops moving entirely.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine backend unroll cursor")
        @MainActor
        struct PlaybackEngineBackendUnrollCursorTests {
            @MainActor
            private final class TransportBackend: SynthBackend {
                let outputNode: AVAudioNode = AVAudioMixerNode()
                var currentTick = 0
                var currentPositionSeconds: TimeInterval = 0
                var isAtEnd = false

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
                func seek(toTick tick: Int) {
                    currentTick = tick
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

            /// `[m0, m1(||:x2:||), m2]`, each measure four quarters at division 480. m1 needs
            /// BOTH `startRepeat` and `endRepeat` or the repeat loops back to m0 instead of
            /// itself — same fixture shape `PlaybackUnrollTests` pins.
            ///
            /// Notated: 3 measures × 1920 = 5760 ticks, frames every 480.
            /// Unrolled: 4 measure-plays × 1920 = 7680 ticks —
            ///   m0 `[0,1920)` → m1 `[1920,3840)` → m1' `[3840,5760)` → m2 `[5760,7680)`.
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

            private func noteID(measure: Int, element: Int) -> NoteID {
                NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: measure, voiceIndex: 0,
                    elementIndex: element, noteIndexInChord: 0,
                )
            }

            /// Sanity-check the fixture actually unrolls, so a failure below is the cursor
            /// mapping and not a mis-built score.
            @Test("fixture unrolls the repeated measure")
            func fixtureUnrolls() {
                let unroll = MidiRenderer.playbackUnroll(score: makeRepeatScore())
                #expect(unroll.totalUnrolledTicks == 7680)
                #expect(unroll.notatedTick(fromUnrolled: 4800) == 2880) // 2nd pass → back in m1
            }

            @Test("during a repeat's second pass the cursor tracks the repeated measure, not the one after it")
            func secondPassCursorStaysInRepeatedMeasure() throws {
                let backend = TransportBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeRepeatScore()
                try engine.prepare(score: score)

                // One notated measure's duration, derived rather than assuming a tempo.
                let measureSeconds = engine.totalTimeSeconds / 3

                engine.play(in: score)

                // Transport at UNROLLED tick 4800 — the 3rd quarter of m1's SECOND pass, which
                // notates to tick 2880 (m1, element 2). Read naively against the notated
                // timeline it looks like tick 4800 → m2.
                backend.currentPositionSeconds = measureSeconds * 2.5
                engine.tickCursor()

                #expect(engine.currentCursor == .item(.note(noteID(measure: 1, element: 2))))
            }

            @Test("past the notated duration the cursor keeps moving instead of saturating on the last frame")
            func pastNotatedDurationCursorKeepsMoving() throws {
                let backend = TransportBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeRepeatScore()
                try engine.prepare(score: score)
                let measureSeconds = engine.totalTimeSeconds / 3

                engine.play(in: score)

                // UNROLLED tick 6720 — the 3rd quarter of m2, the final measure-play. It sits
                // past the NOTATED duration (5760 ticks), where `frame(atTime:)` clamps.
                backend.currentPositionSeconds = measureSeconds * 3.5
                engine.tickCursor()

                #expect(engine.currentCursor == .item(.note(noteID(measure: 2, element: 2))))
            }
        }
    }
#endif
