#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    import SheetMusicAudioCore
    @testable import SheetMusicAudioSwiftySynthCore
    import SheetMusicCore
    import SheetMusicMIDI
    import Testing

    /// `PlaybackEngineRecordingRepeatTests`' score and warp, for the hosted synth's notated clock.
    ///
    /// `|: A :| B`, 4/4 quarters at 120 BPM. The transport plays A at 0–2 s, A again at 2–4 s and B at 4–6 s; notated,
    /// A is 0–2 s and B 2–4 s. The warp makes A's first pass last 2.5 s and its second 3 s, so B starts at warped
    /// 5.5 s.
    enum RepeatedScoreFixture {
        static func score() -> Score {
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
                division: 480, parts: [part], systemMeasures: IdentifiedArray([tempo, SystemMeasure()]), metaTags: [:],
            )
        }

        static func unrolledTimeMap() -> UnrolledTimeMap {
            let score = score()
            return UnrolledTimeMap(
                unroll: MidiRenderer.playbackUnroll(score: score), timeline: PlaybackTimeline(score: score),
            )
        }

        static let spans: [PlaybackTimeWarp.Span] = [
            .init(start: 0, end: 2, duration: 2.5), .init(start: 2, end: 4, duration: 3),
        ]

        static func warp() throws -> PlaybackTimeWarp {
            try PlaybackTimeWarp(spans: spans)
        }
    }

    /// `HostedSynth.notatedSeconds(atOutput:)` / `outputSeconds(atNotated:)`: Android's half of Apple's
    /// `PlaybackEngine.notatedSeconds(forReportedSeconds:)` / `reportedSeconds(forNotatedSeconds:)`, which the same
    /// score and warp pin there.
    @Suite("HostedSynth's notated clock")
    struct HostedSynthNotatedClockTests {
        private static let wholeRecording = [RecordingSegment(sourceStart: 0, sourceEnd: 10, outputStart: 0)]

        private static func synth() throws -> HostedSynth {
            try #require(HostedSynth(sampleRate: 48000, voicing: .score))
        }

        @Test("without a warp or a map both ways are the identity")
        func identity() throws {
            let synth = try Self.synth()
            #expect(synth.notatedSeconds(atOutput: 3.2) == 3.2)
            #expect(synth.outputSeconds(atNotated: 3.2) == 3.2)
        }

        @Test("over a repeat and a warp, both ways read as Apple's engine reads them")
        func repeatAndWarp() throws {
            let synth = try Self.synth()
            synth.setUnrolledTimeMap(RepeatedScoreFixture.unrolledTimeMap())
            try synth.setPlaybackAlignment(warp: RepeatedScoreFixture.warp(), segments: Self.wholeRecording)

            // 1.2 s into A's second pass is A's notated 1.2 s.
            #expect(abs(synth.notatedSeconds(atOutput: 4.3) - 1.2) < 1e-9)
            // B's third quarter, both ways.
            #expect(abs(synth.notatedSeconds(atOutput: 6.5) - 3.0) < 1e-9)
            #expect(abs(synth.outputSeconds(atNotated: 3.0) - 6.5) < 1e-9)
            // Notated 1.2 s plays in both passes of A; it reports at the first, which lasts 2.5 s for its 2.
            #expect(abs(synth.outputSeconds(atNotated: 1.2) - 1.5) < 1e-9)
            // B's downbeat is past both passes.
            #expect(abs(synth.outputSeconds(atNotated: 2.0) - 5.5) < 1e-9)
        }

        @Test("the map alone folds a repeat's later pass, and the warp alone is the speed table")
        func mapAndWarpApart() throws {
            let folded = try Self.synth()
            folded.setUnrolledTimeMap(RepeatedScoreFixture.unrolledTimeMap())
            #expect(abs(folded.notatedSeconds(atOutput: 3.2) - 1.2) < 1e-9, "A's second pass")
            #expect(abs(folded.outputSeconds(atNotated: 1.2) - 1.2) < 1e-9, "its first occurrence")
            #expect(abs(folded.outputSeconds(atNotated: 3.0) - 5.0) < 1e-9, "B, after both passes")

            let warped = try Self.synth()
            try warped.setPlaybackAlignment(warp: RepeatedScoreFixture.warp(), segments: Self.wholeRecording)
            #expect(abs(warped.notatedSeconds(atOutput: 4.3) - 3.2) < 1e-9)
            #expect(abs(warped.outputSeconds(atNotated: 3.2) - 4.3) < 1e-9)
        }

        @Test("a new map replaces the last")
        func mapReplaced() throws {
            let synth = try Self.synth()
            synth.setUnrolledTimeMap(RepeatedScoreFixture.unrolledTimeMap())
            synth.setUnrolledTimeMap(.identity)
            #expect(synth.notatedSeconds(atOutput: 3.2) == 3.2)
        }
    }
#endif
