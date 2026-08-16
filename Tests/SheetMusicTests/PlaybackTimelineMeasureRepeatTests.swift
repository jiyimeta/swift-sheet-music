#if !os(Android)
    import Foundation
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// `PlaybackTimeline`'s measure spine and `MidiRenderer.measureTicks` are two independent
    /// derivations of the same quantity — where each bar starts. They have to agree tick for tick:
    /// the cursor's frames are placed on the timeline's spine while the notes are placed on the
    /// renderer's, so any disagreement is the playhead pointing at the wrong bar.
    @Suite("PlaybackTimeline measure spine vs MidiRenderer")
    struct PlaybackTimelineMeasureRepeatTests {
        private static let division = 480

        /// Three 4/4 bars where the middle one is a `𝄎` measure repeat — the bar carries the marker
        /// instead of chords, and the renderer splices bar 1's notes in at playback time.
        private static func measureRepeatScore() -> Score {
            let quarters = Voice(elements: (0 ..< 4).map { i in
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60 + i, tpc: 14)]))
            })
            let repeated = Voice(elements: [
                .measureRepeat(MeasureRepeat(numMeasures: 1, duration: .measure)),
            ])
            return Score(
                division: division,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "i", articulations: [InstrumentArticulation()]),
                    staves: [Staff(measures: [
                        Measure(voices: [quarters]),
                        Measure(voices: [repeated]),
                        Measure(voices: [quarters]),
                    ])],
                )],
            )
        }

        /// Regression: the spine walk counted `.chord` and `.breath` only, so a measure-repeat bar
        /// contributed ZERO ticks while `measureTicks` gave it a full bar. Every measure after a
        /// `𝄎` therefore started a bar early on the cursor's timeline, and the playhead ran a whole
        /// measure ahead of the audio for the rest of the piece.
        @Test("a measure-repeat bar occupies its bar on the timeline's spine")
        func measureRepeatAdvancesTheSpine() {
            let score = Self.measureRepeatScore()
            let timeline = PlaybackTimeline(score: score)
            let bar = 4 * Self.division
            #expect(timeline.measureStartTicks == [0, bar, 2 * bar])
            #expect(timeline.totalTicks == 3 * bar)
        }

        @Test("the spine matches MidiRenderer's measure bases")
        func spineMatchesRendererBases() {
            let score = Self.measureRepeatScore()
            let timeline = PlaybackTimeline(score: score)
            let measures = score.parts.first?.staves.first?.measures ?? []
            let durations = measures.effectiveMeasureDurations()
            var base = 0
            for (i, measure) in measures.enumerated() {
                #expect(timeline.measureStartTicks[i] == base)
                base += MidiRenderer.measureTicks(
                    measure: measure, division: Self.division,
                    measureDuration: i < durations.count
                        ? durations[i]
                        : Fraction(numerator: 4, denominator: 4),
                )
            }
        }

        @Test("the repeated bar still gets beat frames to park the cursor on")
        func repeatedBarHasBeatFrames() {
            let timeline = PlaybackTimeline(score: Self.measureRepeatScore())
            let bar = 4 * Self.division
            let inRepeatedBar = timeline.frames.filter { $0.tick >= bar && $0.tick < 2 * bar }
            #expect(inRepeatedBar.map(\.tick) == [bar, bar + 480, bar + 960, bar + 1440])
            #expect(inRepeatedBar.allSatisfy {
                if case .beat = $0.cursor { return true }
                return false
            })
        }
    }
#endif
