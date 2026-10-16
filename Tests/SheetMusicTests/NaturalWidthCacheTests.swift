#if os(macOS)
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// `naturalContentWidth(score:options:cache:)` and the layout that follows it at that width — the horizontal
    /// host's pair (`ScoreRelayoutEngine.layoutAtNaturalWidth` in folino) — measuring each measure once between them.
    @Suite("NaturalWidthCache")
    struct NaturalWidthCacheTests {
        private let _installApple = TestSupport.installApple

        private static let quarter = VoiceElement.chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))

        /// An E natural the key already gives: an AUTO accidental `suppressingRedundantAccidentals` hides, so the
        /// layout reads this measure differently from the natural-width walk, which reads the score as given.
        private static let redundantNatural = VoiceElement.chord(Chord(
            duration: .quarter, notes: [Note(pitch: 64, tpc: 18, accidental: .natural, accidentalRole: .auto)],
        ))

        private static func score(_ measures: [[VoiceElement]]) -> Score {
            Score(
                division: 480,
                parts: [Part(
                    id: "P0",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures.map { Measure(voices: [Voice(elements: $0)]) })],
                )],
            )
        }

        private static func plain(_ count: Int) -> [[VoiceElement]] {
            (0 ..< count).map { _ in [quarter, quarter, quarter, quarter] }
        }

        private let options = ScoreViewOptions(wrapToViewWidth: false)

        @Test("a cached walk returns the uncached width, cold and across edits")
        func cachedWidthMatchesUncached() {
            var measures = Self.plain(6)
            measures[2] = [Self.redundantNatural, Self.quarter, Self.quarter, Self.quarter]
            let cache = LayoutCache()
            var steps = [Self.score(measures)]
            // A wider measure, the same width back again, and a time signature that every later measure inherits.
            measures[4] = [.chord(Chord(duration: .eighth, notes: [Note(pitch: 62, tpc: 16)]))] + measures[4]
            steps.append(Self.score(measures))
            steps.append(steps[0])
            measures[1].insert(.timeSignature(TimeSignature(numerator: 3, denominator: 4)), at: 0)
            steps.append(Self.score(measures))
            for (index, score) in steps.enumerated() {
                let cached = LayoutEngine.naturalContentWidth(score: score, options: options, cache: cache)
                let uncached = LayoutEngine.naturalContentWidth(score: score, options: options)
                #expect(cached == uncached, "step \(index)")
                // The layout in between is what the next walk may read widths back from.
                _ = LayoutEngine.layout(score: score, options: options, availableWidth: cached, cache: cache)
            }
        }

        @Test("the layout after the walk measures no measure again")
        func layoutReusesTheWalk() {
            let score = Self.score(Self.plain(8))
            let cache = LayoutCache()
            let width = LayoutEngine.naturalContentWidth(score: score, options: options, cache: cache)
            _ = LayoutEngine.layout(score: score, options: options, availableWidth: width, cache: cache)
            #expect(cache.widthMisses == 0)
            #expect(cache.widthHits == 8)
        }

        @Test("a measure the layout reads with an accidental suppressed is measured by each pass")
        func suppressedMeasureIsMeasuredTwice() {
            var measures = Self.plain(5)
            measures[3] = [Self.redundantNatural, Self.quarter, Self.quarter, Self.quarter]
            let score = Self.score(measures)
            let cache = LayoutCache()
            let width = LayoutEngine.naturalContentWidth(score: score, options: options, cache: cache)
            _ = LayoutEngine.layout(score: score, options: options, availableWidth: width, cache: cache)
            #expect(cache.widthMisses == 1)
            #expect(cache.widthHits == 4)

            // Unchanged on the next round, each pass finds its own entry: neither evicted the other's.
            let again = LayoutEngine.naturalContentWidth(score: score, options: options, cache: cache)
            #expect(again == width)
            _ = LayoutEngine.layout(score: score, options: options, availableWidth: again, cache: cache)
            #expect(cache.widthMisses == 0)
        }

        @Test("a cached layout at the cached width is the uncached one")
        func layoutMatchesUncached() {
            var measures = Self.plain(6)
            measures[0] = [Self.redundantNatural, Self.quarter, Self.quarter, Self.quarter]
            let cache = LayoutCache()
            var score = Self.score(measures)
            _ = LayoutEngine.layout(
                score: score, options: options,
                availableWidth: LayoutEngine.naturalContentWidth(score: score, options: options, cache: cache),
                cache: cache,
            )
            let half = VoiceElement.chord(Chord(duration: .half, notes: [Note(pitch: 67, tpc: 15)]))
            measures[3] = [half, Self.quarter, Self.quarter]
            score = Self.score(measures)
            let width = LayoutEngine.naturalContentWidth(score: score, options: options, cache: cache)
            let cached = LayoutEngine.layout(score: score, options: options, availableWidth: width, cache: cache)
            let uncached = LayoutEngine.layout(
                score: score, options: options,
                availableWidth: LayoutEngine.naturalContentWidth(score: score, options: options),
            )
            #expect(cached == uncached)
        }
    }

    /// The playback cursor resolving `.beat` against the measure durations the layout kept
    /// (`LayoutDocument.staffMeasureDurations`) rather than re-deriving them from the score on every tick.
    @Suite("BeatCursorDurationTable")
    struct BeatCursorDurationTableTests {
        private let _installApple = TestSupport.installApple

        @Test("beat frames read from the layout's table are the ones derived from the score")
        func tableMatchesDerived() throws {
            let quarter = VoiceElement.chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
            let eighth = VoiceElement.chord(Chord(duration: .eighth, notes: [Note(pitch: 62, tpc: 16)]))
            let fullBarRest = VoiceElement.chord(Chord(duration: .measure, notes: []))
            // A pickup, a time signature change mid-score, a `.measure` rest the duration resolves, and a second staff
            // whose bars are written differently.
            let upper = Staff(measures: [
                Measure(voices: [Voice(elements: [quarter])], actualLength: Fraction(numerator: 1, denominator: 4)),
                Measure(voices: [Voice(elements: [quarter, quarter, quarter, quarter])]),
                Measure(voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 3, denominator: 4)), quarter, eighth, eighth, quarter,
                ])]),
                Measure(voices: [Voice(elements: [fullBarRest])]),
            ])
            let lower = Staff(measures: [
                Measure(voices: [Voice(elements: [quarter])], actualLength: Fraction(numerator: 1, denominator: 4)),
                Measure(voices: [Voice(elements: [fullBarRest])]),
                Measure(voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 3, denominator: 4)), eighth, eighth, quarter, quarter,
                ])]),
                Measure(voices: [Voice(elements: [quarter, quarter, quarter])]),
            ])
            let score = Score(
                division: 480,
                parts: [Part(id: "P0", instrument: Instrument(id: "x"), staves: [upper, lower])],
            )
            for wrap in [false, true] {
                let options = ScoreViewOptions(wrapToViewWidth: wrap)
                let withTable = LayoutEngine.layout(score: score, options: options, availableWidth: 600)
                try #require(withTable.staffMeasureDurations.count == 2)
                var withoutTable = withTable
                withoutTable.staffMeasureDurations = []
                for measure in 0 ..< 4 {
                    for tick in stride(from: 0, through: 4 * 480, by: 240) {
                        let cursor = ScoreCursor.beat(measureIndex: measure, tickInMeasure: tick)
                        #expect(
                            withTable.cursorFrame(for: cursor, in: score)
                                == withoutTable.cursorFrame(for: cursor, in: score),
                            "measure \(measure) tick \(tick) wrap \(wrap)",
                        )
                    }
                }
            }
        }

        @Test("a page keeps its document's table")
        func subdocumentKeepsTable() {
            let quarter = VoiceElement.chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "P0", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: (0 ..< 3).map { _ in
                        Measure(voices: [Voice(elements: [quarter, quarter, quarter, quarter])])
                    })],
                )],
            )
            let document = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(wrapToViewWidth: true), availableWidth: 600,
            )
            let page = document.subdocument(systems: 0 ..< document.systems.count, yOffset: 0)
            #expect(!document.staffMeasureDurations.isEmpty)
            #expect(page.staffMeasureDurations == document.staffMeasureDurations)
        }
    }
#endif
