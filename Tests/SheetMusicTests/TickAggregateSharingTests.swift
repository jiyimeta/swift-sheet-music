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

        /// Reference implementation of the derivation `aggregatedTickWeights`
        /// used to run INLINE, per measure, before Task 3 hoisted it into
        /// `effectiveMeasureDurationsAcrossStaves` + `measureDuration(_:at:)`.
        /// Kept here ONLY as a diff spec — never call it outside this test.
        private func oldInlineMeasureDuration(
            staves: [Staff], measureIdx: Int,
        ) -> Fraction {
            guard let staff = staves.first(where: { measureIdx < $0.measures.count })
            else {
                return Fraction(numerator: 4, denominator: 4)
            }
            let durations = staff.measures.effectiveMeasureDurations()
            return measureIdx < durations.count
                ? durations[measureIdx]
                : Fraction(numerator: 4, denominator: 4)
        }

        /// Index-by-index differential against `oldInlineMeasureDuration`
        /// across staff shapes deliberately chosen to be awkward: the 17
        /// golden fixtures all have uniform-length, single-time-signature
        /// staves, so byte-identical golden output can't distinguish "first
        /// staff covering index i" from "always staff 0" or a constant
        /// vector. This test is what actually pins the refactor.
        @Test("agrees with the old per-index derivation across awkward staff shapes")
        func matchesOldDerivationAcrossShapes() {
            let c4 = Note(pitch: 60, tpc: 14)
            let quarter = VoiceElement.chord(Chord(duration: .quarter, notes: [c4]))
            func timeSig(_ n: Int, _ d: Int) -> VoiceElement {
                .timeSignature(TimeSignature(numerator: n, denominator: d))
            }

            // A: short staff first, long staff second, with a MID-SCORE
            // time signature change on the long staff — the carried-
            // forward value must differ per index, not be a constant.
            let short: [Measure] = [
                Measure(voices: [Voice(elements: [timeSig(3, 4), quarter])]),
                Measure(voices: [Voice(elements: [quarter])]),
            ]
            let long: [Measure] = [
                Measure(voices: [Voice(elements: [timeSig(5, 4), quarter])]),
                Measure(voices: [Voice(elements: [quarter])]),
                Measure(voices: [Voice(elements: [timeSig(6, 8), quarter])]),
                Measure(voices: [Voice(elements: [quarter])]),
            ]
            let scenarioA = [Staff(measures: short), Staff(measures: long)]

            // B: same two staves, REVERSED — the long staff is first, so
            // it must win at every index, including the ones the short
            // staff would otherwise cover.
            let scenarioB = [Staff(measures: long), Staff(measures: short)]

            // C: a staff with ZERO measures sitting first — it must never
            // be selected, at any index.
            let scenarioC = [
                Staff(measures: []),
                Staff(measures: [
                    Measure(voices: [Voice(elements: [timeSig(7, 8), quarter])]),
                    Measure(voices: [Voice(elements: [quarter])]),
                ]),
            ]

            // D: `actualLength` overrides the prevailing signature for ONE
            // measure on the staff the merge picks, without disturbing the
            // carried-forward value on the other staff.
            let scenarioD = [
                Staff(measures: [
                    Measure(
                        voices: [Voice(elements: [quarter])],
                        actualLength: Fraction(numerator: 2, denominator: 4),
                    ),
                ]),
                Staff(measures: [
                    Measure(voices: [Voice(elements: [timeSig(9, 8), quarter])]),
                    Measure(voices: [Voice(elements: [quarter])]),
                ]),
            ]

            for staves in [scenarioA, scenarioB, scenarioC, scenarioD] {
                let table = LayoutEngine
                    .effectiveMeasureDurationsAcrossStaves(staves: staves)
                let maxLen = staves.map(\.measures.count).max() ?? 0
                // Walk two indices PAST every staff's end too, to pin the
                // shared 4/4 fallback.
                for idx in 0 ..< (maxLen + 2) {
                    let old = oldInlineMeasureDuration(
                        staves: staves, measureIdx: idx,
                    )
                    let new = LayoutEngine.measureDuration(table, at: idx)
                    #expect(
                        new == old,
                        "index \(idx) diverged: old \(old) new \(new)",
                    )
                }
            }
        }

        /// `staves: []` must agree with the old rule at any index — the
        /// `first(where:)` guard in the old rule always fails on an empty
        /// array, and the table-based fallback must match.
        @Test("empty staves array matches the old fallback at any index")
        func emptyStavesMatchesFallback() {
            let table = LayoutEngine
                .effectiveMeasureDurationsAcrossStaves(staves: [])
            for idx in 0 ..< 4 {
                let old = oldInlineMeasureDuration(staves: [], measureIdx: idx)
                let new = LayoutEngine.measureDuration(table, at: idx)
                #expect(new == old)
                #expect(new == Fraction(numerator: 4, denominator: 4))
            }
        }
    }
#endif
