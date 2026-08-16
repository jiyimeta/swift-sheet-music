#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// An A-B loop is a region of the SCORE, but the transport plays the UNROLLED render, where the
    /// same bar sits at one position per pass and generally at none of its notated ticks. The loop
    /// used to be compared against — and seeked with — its raw notated ticks, so on a score with a
    /// repeat the region was cut short and then replayed from whatever the sequence happened to be
    /// playing at that many notated seconds in: a different passage than the one highlighted.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine A-B loop transport coordinates")
        @MainActor
        struct PlaybackEngineLoopUnrollCoordinateTests {
            @MainActor
            private final class RecordingTransport: SynthBackend {
                let outputNode: AVAudioNode = AVAudioMixerNode()
                var currentTick = 0
                var currentPositionSeconds: TimeInterval = 0
                var isAtEnd = false
                /// Every `seek(toTick:)` argument, in call order.
                var seekTicks: [Int] = []

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
                    seekTicks.append(tick)
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

            /// `[m0, m1(||:x2:||), m2]`, four quarters each at division 480 and the default
            /// 120 BPM — one measure is 1920 ticks and 2 seconds.
            ///
            /// Notated: m0 `[0,1920)`, m1 `[1920,3840)`, m2 `[3840,5760)`.
            /// Unrolled: m0 `[0,1920)` → m1 `[1920,3840)` → m1' `[3840,5760)` → m2 `[5760,7680)`,
            /// i.e. m2 is heard from 6 s to 8 s while its notated time is 4 s to 6 s.
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

            private func itemID(measure: Int, element: Int) -> SheetMusicCore.ScoreItemID {
                .note(NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: measure, voiceIndex: 0,
                    elementIndex: element, noteIndexInChord: 0,
                ))
            }

            /// Loop the whole of m2 — the bar AFTER the repeat, so notated and unrolled disagree by
            /// one full measure-play.
            private func loopOverFinalMeasure(_ engine: PlaybackEngine) {
                engine.setLoop(
                    from: .item(itemID(measure: 2, element: 0)),
                    throughEndOf: itemID(measure: 2, element: 3),
                )
            }

            @Test("the loop projects onto the measure-play the region is actually heard in")
            func loopProjectsOntoTheTransport() throws {
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: RecordingTransport())
                try engine.prepare(score: makeRepeatScore())
                loopOverFinalMeasure(engine)

                // Notated, as the host set it and reads it back.
                #expect(engine.loopRange == LoopRange(startTick: 3840, endTick: 5760))
                // Projected: m2's single measure-play is unrolled `[5760, 7680)` = 6 s…8 s.
                let projected = try #require(engine.transportLoop)
                #expect(projected.startTick == 5760)
                #expect(projected.endTick == 7680)
                #expect(abs(projected.startSeconds - 6) < 0.001)
                #expect(abs(projected.endSeconds - 8) < 0.001)
            }

            /// A loop over the REPEATED bar must cover that bar's own play only. Resolving the end
            /// tick by its own first occurrence would land on the NEXT measure-play and swallow the
            /// repeat's second take.
            @Test("a loop over a repeated bar covers one pass, not both")
            func loopOverRepeatedBarCoversOnePass() throws {
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: RecordingTransport())
                try engine.prepare(score: makeRepeatScore())
                engine.setLoop(
                    from: .item(itemID(measure: 1, element: 0)),
                    throughEndOf: itemID(measure: 1, element: 3),
                )

                let projected = try #require(engine.transportLoop)
                #expect(projected.startTick == 1920)
                #expect(projected.endTick == 3840)
            }

            @Test("the region plays to its end instead of wrapping at the notated end time")
            func doesNotWrapEarly() throws {
                let backend = RecordingTransport()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeRepeatScore()
                try engine.prepare(score: score)
                loopOverFinalMeasure(engine)
                engine.play(in: score)
                backend.seekTicks.removeAll()

                // 7 s: mid-m2 on the transport's clock — inside the loop. The notated end time is
                // 6 s, which is what used to fire the wrap here, a whole measure early.
                backend.currentPositionSeconds = 7
                engine.tickCursor()

                #expect(backend.seekTicks.isEmpty)
                #expect(engine.currentCursor == .item(itemID(measure: 2, element: 2)))
            }

            @Test("the wrap seeks back to the loop's own start, not to that many notated seconds in")
            func wrapsToTheRegionsOwnStart() throws {
                let backend = RecordingTransport()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeRepeatScore()
                try engine.prepare(score: score)
                loopOverFinalMeasure(engine)
                engine.play(in: score)
                backend.seekTicks.removeAll()

                // Just past the region's audible end (8 s).
                backend.currentPositionSeconds = 8.05
                engine.tickCursor()

                // The seek argument is a NOTATED tick — the backend projects it onto its own clock
                // through the map the engine hands it — and it is m2's onset.
                #expect(backend.seekTicks == [3840])
                #expect(engine.currentCursor == .item(itemID(measure: 2, element: 0)))
            }

            /// The projection the backend applies to that notated tick: m2's onset is 4 s on the
            /// notated clock and 6 s on the transport's.
            @Test("the notated loop start projects onto the transport's clock")
            func backendProjectsTheSeekTarget() {
                let score = makeRepeatScore()
                let timeline = PlaybackTimeline(score: score)
                let map = UnrolledTimeMap(
                    unroll: MidiRenderer.playbackUnroll(score: score), timeline: timeline,
                )
                let notated = timeline.seconds(atTick: 3840)
                #expect(abs(notated - 4) < 0.001)
                #expect(abs(map.unrolledSeconds(fromNotated: notated) - 6) < 0.001)
            }
        }
    }
#endif
