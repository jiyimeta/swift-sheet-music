#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import SheetMusicMIDI
    import Testing

    /// Regression tests for end-of-score / loop-wrap detection on the injected-backend
    /// (`SwiftySynthBackend`) cursor path.
    ///
    /// The 1.2.0 backend switch made `backendTickCursor` compare a FRAME-SNAPPED tick against
    /// OFFSET-valued boundaries. `SwiftySynthBackend.currentTick` is
    /// `timeline.frame(atTime:)?.tick`, and `frame(atTime:)` clamps to the last frame — and
    /// `frames` holds note ONSETS only. Both boundaries it was compared against sit strictly
    /// past the final onset: `timeline.totalTicks` is documented as the last note's offset, and
    /// `setLoop(from:throughEndOf:)` takes its end from `itemEndTicks` (also an offset). So the
    /// polled tick saturated below both, `stop()` never fired (the engine stayed `.playing`
    /// forever with the cursor parked on the last note) and a whole-score repeat never wrapped.
    ///
    /// The AUMIDISynth path never had this: its tick is `currentPositionInBeats * division`, a
    /// continuous transform of the transport clock, so it climbs past the final onset.
    ///
    /// These drive `tickCursor()` directly rather than waiting on the 30 Hz poll — same
    /// determinism trick `PlaybackEngineLoopWrapMixerTests` uses for `wrapToLoopStart`.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine backend end detection")
        @MainActor
        struct PlaybackEngineBackendEndDetectionTests {
            /// Transport stub whose position / end flag the test sets directly, so a tick can be
            /// parked at the exact saturated value the real backend reports at end of piece.
            @MainActor
            private final class TransportBackend: SynthBackend {
                let outputNode: AVAudioNode = AVAudioMixerNode()
                var currentTick = 0
                var currentPositionSeconds: TimeInterval = 0
                var isAtEnd = false
                private(set) var seekCalls: [Int] = []

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
                    seekCalls.append(tick)
                    currentTick = tick
                }

                /// Drop the seeks `play` itself emits, so a test asserts only on the wrap's.
                func resetSeekCalls() {
                    seekCalls.removeAll()
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

            /// One 4/4 measure of four quarter notes at division 480: onsets at 0 / 480 / 960 /
            /// 1440, `totalTicks` 1920. The gap between the final onset (1440) and `totalTicks`
            /// (1920) is exactly the window the saturating tick could never cross.
            private func makeFourQuarterScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let voice = Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                ])
                let part = Part(
                    id: "p",
                    instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )
                return Score(division: 480, parts: [part])
            }

            private func noteID(elementIndex: Int) -> NoteID {
                NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: 0, voiceIndex: 0,
                    elementIndex: elementIndex, noteIndexInChord: 0,
                )
            }

            /// Element indices are into `voice.elements`, so the time signature at index 0 shifts
            /// the four chords to 1...4.
            private var firstNoteID: NoteID {
                noteID(elementIndex: 1)
            }

            private var lastNoteID: NoteID {
                noteID(elementIndex: 4)
            }

            @Test("end of score stops the engine even though the polled tick saturates below totalTicks")
            func endOfScoreStopsDespiteSaturatedTick() throws {
                let backend = TransportBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeFourQuarterScore()
                try engine.prepare(score: score)

                engine.play(in: score)
                #expect(engine.state == .playing)

                // The exact state the real backend reports once the SMF has run out: the transport
                // clock has reached the end of the piece, but `currentTick` is frame-snapped to the
                // final note's ONSET and can never climb to `totalTicks`.
                backend.currentPositionSeconds = engine.totalTimeSeconds
                backend.currentTick = 1440
                backend.isAtEnd = true

                engine.tickCursor()

                #expect(engine.state == .stopped)
                #expect(engine.currentCursor == nil)
            }

            @Test("a whole-score loop wraps even though its end tick sits past every frame")
            func wholeScoreLoopWrapsPastFinalOnset() throws {
                let backend = TransportBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeFourQuarterScore()
                try engine.prepare(score: score)

                // Exactly what folino's `setLoopRange` builds for "repeat whole score": the end
                // anchor is the last chord of the last measure, resolved through `itemEndTicks`.
                engine.setLoop(from: .item(.note(firstNoteID)), throughEndOf: .note(lastNoteID))
                let loop = try #require(engine.loopRange)
                // Offset-based, so it sits past the final onset frame (1440) — the whole bug.
                #expect(loop.endTick == 1920)

                engine.play(in: score)
                backend.currentPositionSeconds = engine.totalTimeSeconds
                backend.currentTick = 1440
                backend.resetSeekCalls()

                engine.tickCursor()

                #expect(backend.seekCalls == [loop.startTick])
                #expect(engine.state == .playing) // a wrap must not stop playback
            }

            @Test("a count-in playback also stops at end of score")
            func countInPlaybackStopsAtEnd() throws {
                let backend = TransportBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeFourQuarterScore()
                try engine.prepare(score: score)

                // A count-in leaves the score transport un-shifted (the count runs on the
                // metronome transport), so end detection must behave exactly as it does for a
                // plain play — including past the saturating frame lookup.
                engine.play(from: nil, in: score, countIn: true)
                #expect(engine.state == .playing)

                backend.currentPositionSeconds = 1000 // far past pre-roll + score
                backend.currentTick = 1440
                backend.isAtEnd = true

                engine.tickCursor()

                #expect(engine.state == .stopped)
            }
        }
    }
#endif
