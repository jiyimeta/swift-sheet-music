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

        /// `buildSystem` must not recompute the tick aggregation for a
        /// measure `packSystems`'s width pass (`minWidths`) already
        /// computed: it always runs first within the same `packSystems`
        /// call, so `buildSystem`'s lookup is a hit for every measure it
        /// touches, even on the very first (cold-cache) layout call.
        ///
        /// Deviation from the plan's literal test: the plan expected
        /// `tickAggregateMisses > 0` after the FIRST call, on the
        /// assumption that a fresh cache means "miss". But `minWidths`
        /// unconditionally populates `entries[i].tickAggregate` for
        /// EVERY measure index — on a per-measure cache MISS via a
        /// fresh `crossStaffMinimumMeasureWidthWithAggregate` call, on a
        /// HIT by carrying `prior.tickAggregate` forward — before
        /// `buildSystem` ever runs. So `buildSystem`'s lookup can only
        /// ever miss when `context.cache` itself is nil (caching
        /// disabled). Confirmed with a temporary debug print during
        /// development: `cachedAggregate` was already `true` for all 8
        /// measures on the very first call. Because a real miss is
        /// therefore unreachable, `LayoutCache.tickAggregateMisses` was
        /// removed entirely in review fix round 1 (Finding 4) rather
        /// than kept as permanently-dead-in-production instrumentation
        /// — this test now asserts only `tickAggregateHits`.
        @Test("warm relayout reuses the cached tick aggregate")
        func warmRelayoutReusesAggregate() {
            guard #available(macOS 15.0, *) else { return }
            let c4 = Note(pitch: 60, tpc: 14)
            let quarter = VoiceElement.chord(
                Chord(duration: .quarter, notes: [c4]),
            )
            let measures = (0 ..< 8).map { _ in
                Measure(voices: [Voice(elements: [
                    quarter, quarter, quarter, quarter,
                ])])
            }
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "P0",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
            )
            let opts = ScoreViewOptions(wrapToViewWidth: false)
            let width = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )
            let cache = LayoutCache()
            _ = LayoutEngine.layout(
                score: score, options: opts,
                availableWidth: width, cache: cache,
            )
            // First (cold) call: `buildSystem` still finds every
            // measure's aggregate already sitting in the cache, since
            // `minWidths` populated it moments earlier in the same
            // `packSystems` call.
            #expect(cache.tickAggregateHits == measures.count)

            // Second call: bump `availableWidth` so the SYSTEM-level
            // cache (`LayoutCache.SystemEntry`, keyed in part on
            // `availableWidth`) misses and `buildSystem` runs again —
            // an unchanged `availableWidth` would hit the system cache
            // and skip `buildSystem` entirely, which would trivially
            // (and uninterestingly) leave the tick-aggregate counters
            // at zero without ever exercising the per-measure reuse
            // this test targets. The measures themselves are untouched,
            // so `minWidths` treats every one as a per-measure cache
            // HIT and carries `prior.tickAggregate` forward — which is
            // exactly what `buildSystem` must find without recomputing.
            _ = LayoutEngine.layout(
                score: score, options: opts,
                availableWidth: width + 50, cache: cache,
            )
            #expect(cache.tickAggregateHits == measures.count)
        }

        /// Finding 1 regression test (fix round 1): `measureDuration`
        /// must be part of `LayoutCache.Entry`'s cache-hit predicate,
        /// not just `measures` / `sp` / `division`. Reproduces the
        /// review's exact scenario:
        ///
        ///   - Measure 0 declares the time signature (edited between
        ///     the two layout calls).
        ///   - Measure 1 is untouched across both calls and holds a
        ///     `.measure`-duration (full-bar) rest in voice 1 alongside
        ///     four quarters in voice 0. `NoteDuration.resolved(in:)`
        ///     resolves that rest against the PREVAILING duration, so
        ///     its tick span — and therefore `gapWeights` /
        ///     `totalWeight` / every tick's x — differs between 4/4 and
        ///     2/4 even though measure 1's own `Measure` value never
        ///     changes.
        ///
        /// Without `measureDuration` in the predicate, measure 1 is a
        /// per-measure cache HIT on the second call (its `Measure`
        /// value is byte-identical), so the STALE tick columns from
        /// the first call would be served straight into placement.
        /// This test lays out once under 4/4, edits ONLY measure 0's
        /// time signature to 2/4, lays out again with the SAME cache,
        /// and asserts measure 1's tick columns changed.
        ///
        /// Verified load-bearing: reverting the `measureDuration` field
        /// (i.e. dropping it from `Entry` and the hit predicate) makes
        /// this test FAIL — see the fix-round report for the exact
        /// command and output.
        @Test("editing an earlier measure's time signature invalidates a later measure's cached tick columns")
        func earlierTimeSignatureEditInvalidatesLaterMeasureAggregate() throws {
            guard #available(macOS 15.0, *) else { return }
            let c4 = Note(pitch: 60, tpc: 14)
            let quarter = VoiceElement.chord(
                Chord(duration: .quarter, notes: [c4]),
            )
            let fullBarRest = VoiceElement.chord(
                Chord(duration: .measure, notes: []),
            )

            func makeScore(timeSig: TimeSignature) -> Score {
                let measure0 = Measure(voices: [Voice(elements: [
                    .timeSignature(timeSig),
                    quarter, quarter, quarter, quarter,
                ])])
                // Measure 1 is IDENTICAL across both scores: voice 0 has
                // four quarters (so there are multiple ticks to compare),
                // voice 1 holds a single full-bar rest whose resolved
                // duration depends entirely on the PREVAILING time
                // signature carried forward from measure 0.
                let measure1 = Measure(voices: [
                    Voice(elements: [quarter, quarter, quarter, quarter]),
                    Voice(elements: [fullBarRest]),
                ])
                return Score(
                    division: 480,
                    parts: [Part(
                        id: "P0",
                        instrument: Instrument(id: "x"),
                        staves: [Staff(measures: [measure0, measure1])],
                    )],
                )
            }

            let scoreV1 = makeScore(
                timeSig: TimeSignature(numerator: 4, denominator: 4),
            )
            let opts = ScoreViewOptions(wrapToViewWidth: false)
            let width = LayoutEngine.naturalContentWidth(
                score: scoreV1, options: opts,
            )
            let cache = LayoutCache()
            let doc1 = LayoutEngine.layout(
                score: scoreV1, options: opts,
                availableWidth: width, cache: cache,
            )
            let cols1 = try #require(
                doc1.systems.first?.measures.dropFirst().first?.tickColumns,
            )

            // Edit ONLY measure 0's time signature. Measure 1's `Measure`
            // value is untouched — same `Voice` / `VoiceElement` values —
            // so a predicate that ignores `measureDuration` would treat
            // it as an unconditional per-measure cache HIT.
            let scoreV2 = makeScore(
                timeSig: TimeSignature(numerator: 2, denominator: 4),
            )
            let doc2 = LayoutEngine.layout(
                score: scoreV2, options: opts,
                availableWidth: width, cache: cache,
            )
            let cols2 = try #require(
                doc2.systems.first?.measures.dropFirst().first?.tickColumns,
            )

            let message = "measure 1's tick columns must change when the "
                + "prevailing time signature carried into it changes, even "
                + "though measure 1's own content is untouched — got "
                + "identical columns both times (\(cols1)), meaning a "
                + "stale cached aggregate was served"
            #expect(cols1 != cols2, "\(message)")
        }
    }
#endif
