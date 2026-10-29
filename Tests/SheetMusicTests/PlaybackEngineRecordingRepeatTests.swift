#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import Testing

    extension AudioEngineSerial {
        /// `PlaybackEngine`'s time reporting under an alignment on a score with a repeat, against `RecordingBackend`.
        /// The warp is a table over the transport's clock, where repeats are played out, so a position in a repeat's
        /// second pass is warped as that pass, not as the notated second the cursor shows.
        ///
        /// `|: A :| B`, 4/4 quarters at 120 BPM. The transport plays A at 0–2 s, A again at 2–4 s and B at 4–6 s;
        /// notated, A is 0–2 s and B 2–4 s. The warp makes A's first pass last 2.5 s and its second 3 s, so B starts at
        /// warped 5.5 s and the whole lasts 7.5 s.
        @Suite("PlaybackEngine time under an alignment on a score with a repeat")
        @MainActor
        final class PlaybackEngineRecordingRepeatTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            private let backend: RecordingBackend
            private let score: Score
            private let engine: PlaybackEngine

            init() throws {
                backend = RecordingBackend()
                score = Self.makeScore()
                engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
            }

            private static func makeScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let a = Measure(
                    voices: [Voice(elements: [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                            + Array(repeating: VoiceElement.chord(quarter), count: 4))],
                    startRepeat: true, endRepeatCount: 2,
                )
                let b = Measure(voices: [Voice(elements: Array(repeating: VoiceElement.chord(quarter), count: 4))])
                let part = Part(
                    id: "p0", instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [a, b])],
                )
                let tempo = SystemMeasure(elements: [
                    PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2.0))),
                ])
                return Score(
                    division: 480, parts: [part], systemMeasures: IdentifiedArray([tempo, SystemMeasure()]),
                    metaTags: [:],
                )
            }

            /// A's first pass (transport 0–2 s) lasts 2.5 s, its second (2–4 s) 3 s; B (4–6 s) keeps its 2 s.
            private static func warp() throws -> PlaybackTimeWarp {
                try PlaybackTimeWarp(spans: [
                    .init(start: 0, end: 2, duration: 2.5), .init(start: 2, end: 4, duration: 3),
                ])
            }

            private static let wholeRecording = [RecordingSegment(sourceStart: 0, sourceEnd: 10, outputStart: 0)]

            private func align() throws {
                try engine.setAlignment(warp: Self.warp(), segments: Self.wholeRecording)
            }

            @Test("a position in the repeat's second pass reads the warped seconds of that pass")
            func secondPassReadsItsOwnWarpedSeconds() throws {
                try align()

                // Transport 3.2 s is 1.2 s into A's second pass, which lasts 3 s for its 2: warped 2.5 + 1.8.
                backend.currentPositionSeconds = 3.2
                #expect(abs(engine.currentTimeSecondsContinuous - 4.3) < 1e-9)
                // Snapped to the quarter at notated 1.0 s, transport 3.0 s in the second pass: warped 2.5 + 1.5.
                #expect(abs(engine.currentTimeSeconds - 4.0) < 1e-9)
                // B, past every span: the 1 s the warp added carries on.
                backend.currentPositionSeconds = 4.5
                #expect(abs(engine.currentTimeSecondsContinuous - 6.0) < 1e-9)
            }

            @Test("the total is the warped length of every pass, and the notated length without an alignment")
            func totalIsTheWarpedUnrolledLength() throws {
                #expect(abs(engine.totalTimeSeconds - 4.0) < 1e-9)
                try align()
                #expect(abs(engine.totalTimeSeconds - 7.5) < 1e-9)
            }

            @Test("a seek to a warped second in B lands in B")
            func seekIntoTheMeasureAfterTheRepeatLandsThere() throws {
                engine.play(in: score)
                try align()

                // Warped 6.5 s is transport 5.0 s, 1 s into B: notated 3.0 s, B's third quarter, tick 2880.
                engine.seek(toTimeSeconds: 6.5)
                #expect(backend.seekCalls.last == 2880)
                // Warped 5.5 s, B's downbeat: tick 1920, not the end of A's second pass.
                engine.seek(toTimeSeconds: 5.5)
                #expect(backend.seekCalls.last == 1920)
            }

            // MARK: The notated clock and the conversions

            @Test("the notated clock is the continuous one without an alignment, and stays notated under one")
            func notatedClockStaysNotated() throws {
                backend.currentPositionSeconds = 3.2
                #expect(abs(engine.notatedTimeSecondsContinuous - 1.2) < 1e-9)
                #expect(engine.notatedTimeSecondsContinuous == engine.currentTimeSecondsContinuous)

                try align()
                // A's second pass reads A's notated second, where the reported clock reads the warped pass.
                #expect(abs(engine.notatedTimeSecondsContinuous - 1.2) < 1e-9)
                #expect(abs(engine.currentTimeSecondsContinuous - 4.3) < 1e-9)
                backend.currentPositionSeconds = 4.5
                #expect(abs(engine.notatedTimeSecondsContinuous - 2.5) < 1e-9)
            }

            @Test("reported and notated seconds convert both ways, a notated second reporting at its first pass")
            func reportedAndNotatedSecondsConvert() throws {
                // Without an alignment the reported clock is the notated one.
                #expect(engine.reportedSeconds(forNotatedSeconds: 3.0) == 3.0)
                #expect(engine.notatedSeconds(forReportedSeconds: 3.0) == 3.0)

                try align()
                // 1.2 s into A's second pass is A's notated 1.2 s.
                #expect(abs(engine.notatedSeconds(forReportedSeconds: 4.3) - 1.2) < 1e-9)
                // B's third quarter, both ways.
                #expect(abs(engine.notatedSeconds(forReportedSeconds: 6.5) - 3.0) < 1e-9)
                #expect(abs(engine.reportedSeconds(forNotatedSeconds: 3.0) - 6.5) < 1e-9)
                // Notated 1.2 s plays in both passes of A; it reports at the first, which lasts 2.5 s for its 2.
                #expect(abs(engine.reportedSeconds(forNotatedSeconds: 1.2) - 1.5) < 1e-9)
                // B's downbeat is past both passes, and the notated end is the reported total.
                #expect(abs(engine.reportedSeconds(forNotatedSeconds: 2.0) - 5.5) < 1e-9)
                #expect(abs(engine.reportedSeconds(forNotatedSeconds: 4.0) - engine.totalTimeSeconds) < 1e-9)
            }
        }
    }
#endif
