#if os(macOS)
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("TickAggregateSharing")
    struct TickAggregateSharingTests {
        private let _installApple = TestSupport.installApple

        /// The shared duration table must reproduce the old derivation:
        /// read from the FIRST staff whose measure list covers the index.
        @Test("durations come from the first staff covering the measure")
        func firstStaffCovering() {
            let c4 = Note(pitch: 60, tpc: 14)
            let quarter = VoiceElement.chord(
                Chord(duration: .quarter, notes: [c4]),
            )
            // Staff 0 is SHORT: it only covers measure 0.
            let short = Staff(measures: [
                Measure(voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 3, denominator: 4)),
                    quarter,
                ])]),
            ])
            // Staff 1 covers 0...1 with a different time signature.
            let long = Staff(measures: [
                Measure(voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 5, denominator: 4)),
                    quarter,
                ])]),
                Measure(voices: [Voice(elements: [quarter])]),
            ])

            let durations = LayoutEngine
                .effectiveMeasureDurationsAcrossStaves(staves: [short, long])

            #expect(durations.count == 2)
            // Measure 0: staff 0 covers it, so 3/4 (not staff 1's 5/4).
            #expect(durations[0] == Fraction(numerator: 3, denominator: 4))
            // Measure 1: staff 0 does not cover it, so staff 1's 5/4.
            #expect(durations[1] == Fraction(numerator: 5, denominator: 4))
        }

        @Test("no staves yields an empty table")
        func noStaves() {
            #expect(
                LayoutEngine
                    .effectiveMeasureDurationsAcrossStaves(staves: [])
                    .isEmpty,
            )
        }
    }
#endif
