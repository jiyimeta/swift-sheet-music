#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// The strip-naming rule as a value rather than a string, so a mixer laid out in groups can title the group with
    /// the part and label the row with the instrument. The rule itself is covered by
    /// `InstrumentChangeMixerStripNamingTests`, which drives it through a real engine; these two tests cover only what
    /// splitting adds — that both halves are reported even where the composed name shows one of them.
    ///
    /// The function also exists to be the single copy. It was written twice before: `PlaybackEngine+Mixer.stripName`
    /// and `AudioMidiBridge.instrumentParams`, the latter under a comment promising it "mirrors stripName exactly".
    @Suite("LiveChannelPlan strip labels")
    struct StripLabelsTests {
        @Test("the instrument is reported even when the composed name suppresses it")
        func instrumentSurvivesSuppression() throws {
            // A part named after its own instrument — the common case, and the one where "Piano (Piano)" would be
            // absurd, so `displayName` drops the suffix. A host grouping by part still needs the instrument.
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "piano", longName: "Piano", channels: [InstrumentChannel()]),
                    staves: [Staff(measures: [Measure(voices: [Voice(elements: [])])])],
                )],
                systemMeasures: [SystemMeasure()],
            )
            let plan = LiveChannelPlan.build(score: score)
            let strip = try #require(plan.strips.first)

            let labels = plan.labels(for: strip, in: score)

            #expect(labels.displayName == labels.partName)
            #expect(labels.instrumentName == "Piano")
        }

        @Test("both halves survive the composed name for an instrument-change part")
        func multiStripReportsPartAndInstrumentSeparately() throws {
            let score = try InstrumentChangeMixerTests.fixtureScore()
            let plan = LiveChannelPlan.build(score: score)
            let piano = try #require(plan.strips.first { $0.instrument.id == "piano" })
            let accordion = try #require(plan.strips.first { $0.instrument.id == "accordion" })

            let pianoLabels = plan.labels(for: piano, in: score)
            let accordionLabels = plan.labels(for: accordion, in: score)

            // Same part, so one group title covers both rows and only the instrument distinguishes them.
            #expect(pianoLabels.partName == accordionLabels.partName)
            #expect(pianoLabels.instrumentName == "Piano")
            #expect(accordionLabels.instrumentName == "Accordion")
            // And the composed form is exactly what the engine and the Android bridge produced before the split.
            #expect(accordionLabels.displayName == "\(accordionLabels.partName) (Accordion)")
        }
    }
#endif
