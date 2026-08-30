#if os(macOS)
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    @Suite("LayoutCache")
    struct LayoutCacheTests {
        private let _installApple = TestSupport.installApple

        /// Builds a tiny multi-measure score for cache exercises.
        private static func sampleScore() -> Score {
            let note = Note(pitch: 60, tpc: 14)
            let m1 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [note])),
            ])])
            let m2 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .half, notes: [note])),
                .chord(Chord(duration: .half, notes: [note])),
            ])])
            let m3 = Measure(voices: [Voice(elements: [
                .rest(duration: .whole),
            ])])
            return Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [m1, m2, m3])])],
            )
        }

        @Test("Cold cache produces same document as cache-less layout")
        func coldCacheEquivalence() {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.sampleScore()
            let baseline = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let cache = LayoutCache()
            let cached = LayoutEngine.layout(
                score: score, options: .init(),
                availableWidth: 800, cache: cache,
            )
            #expect(cached.systems == baseline.systems)
            #expect(cached.size == baseline.size)
        }

        @Test("Cold call: every width / placement / system is a miss")
        func coldCallAllMisses() {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.sampleScore()
            let cache = LayoutCache()
            _ = LayoutEngine.layout(
                score: score, options: .init(),
                availableWidth: 800, cache: cache,
            )
            #expect(cache.entries.count == 3)
            #expect(cache.widthHits == 0)
            #expect(cache.widthMisses == 3)
            // Single-staff score → one placement per measure.
            #expect(cache.placementHits == 0)
            #expect(cache.placementMisses == 3)
            // The 3 measures pack into one system on a wide canvas.
            #expect(cache.systemHits == 0)
            #expect(cache.systemMisses == 1)
        }

        @Test("Warm call on identical score: system hits short-circuit")
        func warmCallSystemHits() {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.sampleScore()
            let cache = LayoutCache()
            let first = LayoutEngine.layout(
                score: score, options: .init(),
                availableWidth: 800, cache: cache,
            )
            let second = LayoutEngine.layout(
                score: score, options: .init(),
                availableWidth: 800, cache: cache,
            )
            #expect(first.systems == second.systems)
            #expect(first.size == second.size)
            // Width cache fires for every measure (it runs in packSystems
            // before the system-level lookup).
            #expect(cache.widthHits == 3)
            #expect(cache.widthMisses == 0)
            // System hit short-circuits buildSystem; placement counters
            // do not increment since `placeMeasureElements` is never
            // called.
            #expect(cache.systemHits == 1)
            #expect(cache.systemMisses == 0)
            #expect(cache.placementHits == 0)
            #expect(cache.placementMisses == 0)
        }

        @Test("Editing one measure: only that measure's system misses")
        func singleMeasureEditMisses() {
            guard #available(macOS 15.0, *) else { return }
            let scoreA = Self.sampleScore()
            let cache = LayoutCache()
            _ = LayoutEngine.layout(
                score: scoreA, options: .init(),
                availableWidth: 800, cache: cache,
            )
            // Now edit measure 1: replace its content.
            var staff = scoreA.parts[0].staves[0]
            var measures = staff.measures
            let editedMeasure1 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .half, notes: [
                    Note(pitch: 60, tpc: 14),
                ])),
                .rest(duration: .half),
            ])])
            measures[1] = editedMeasure1
            staff = Staff(measures: measures)
            let scoreB = Score(
                division: scoreA.division,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
            )
            _ = LayoutEngine.layout(
                score: scoreB, options: .init(),
                availableWidth: 800, cache: cache,
            )
            // Measures 0 and 2 unchanged → 2 width hits; measure 1 → 1 miss.
            #expect(cache.widthHits == 2)
            #expect(cache.widthMisses == 1)
            // The 3 measures still pack into one system, but the system's
            // inputs changed (one measure differs) → system miss.
            #expect(cache.systemHits == 0)
            #expect(cache.systemMisses == 1)
            // Per-(measure, staff) placement: inside the missed system,
            // measures 0 + 2 hit on placement, measure 1 misses.
            #expect(cache.placementHits == 2)
            #expect(cache.placementMisses == 1)
        }

        /// `sampleScore()` with a rehearsal mark written into the system
        /// lane at `measureIndex` and NOTHING else changed — no staff, no
        /// measure, no voice. This is the shape of a rehearsal-mark /
        /// tempo / system-text edit.
        private static func addingRehearsalMark(
            _ text: String,
            atMeasure measureIndex: Int,
            of score: Score,
        ) -> Score {
            let measureCount = score.parts[0].staves[0].measures.count
            var lane = (0 ..< measureCount).map { idx in
                idx < score.systemMeasures.count
                    ? score.systemMeasures[idx] : SystemMeasure()
            }
            lane[measureIndex].elements.append(PositionedSystemElement(
                position: .start,
                element: .rehearsalMark(RehearsalMark(text: text)),
            ))
            return Score(
                division: score.division,
                parts: score.parts,
                systemMeasures: lane,
            )
        }

        /// True when any system of `doc` draws a `.rehearsalMark`.
        private static func drawsRehearsalMark(_ doc: LayoutDocument) -> Bool {
            doc.systems.contains { system in
                system.measures.contains { measure in
                    measure.elements.contains { element in
                        if case .rehearsalMark = element { return true }
                        return false
                    }
                }
            }
        }

        /// An edit that touches ONLY `Score.systemMeasures` must still
        /// invalidate the system that contains the edited bar. Every
        /// per-staff `Measure` is bit-identical across such an edit, so
        /// without the system lane in `SystemInputs` the whole system is
        /// served from the cache and the mark never reaches the page.
        @Test("System-lane-only edit invalidates the containing system")
        func systemLaneOnlyEditMisses() {
            guard #available(macOS 15.0, *) else { return }
            let scoreA = Self.sampleScore()
            let cache = LayoutCache()
            _ = LayoutEngine.layout(
                score: scoreA, options: .init(),
                availableWidth: 800, cache: cache,
            )
            let scoreB = Self.addingRehearsalMark(
                "A", atMeasure: 1, of: scoreA,
            )
            _ = LayoutEngine.layout(
                score: scoreB, options: .init(),
                availableWidth: 800, cache: cache,
            )
            // No staff measure changed, so the per-measure width entries
            // legitimately all hit — the mark adds no width.
            #expect(cache.widthHits == 3)
            #expect(cache.widthMisses == 0)
            // ...but the system carrying measure 1 must rebuild.
            #expect(cache.systemHits == 0)
            #expect(cache.systemMisses == 1)
        }

        /// The user-visible half of the case above: after the same
        /// system-lane-only edit through a warm cache, the re-engraved
        /// document must actually contain the mark. Pins the symptom
        /// rather than the cache statistic, so a "fix" that invalidates
        /// the entry without reaching placement still fails here.
        @Test("System-lane-only edit reaches placement: the mark is drawn")
        func systemLaneOnlyEditDrawsMark() {
            guard #available(macOS 15.0, *) else { return }
            let scoreA = Self.sampleScore()
            let cache = LayoutCache()
            let cold = LayoutEngine.layout(
                score: scoreA, options: .init(),
                availableWidth: 800, cache: cache,
            )
            #expect(!Self.drawsRehearsalMark(cold))
            let scoreB = Self.addingRehearsalMark(
                "A", atMeasure: 1, of: scoreA,
            )
            let warm = LayoutEngine.layout(
                score: scoreB, options: .init(),
                availableWidth: 800, cache: cache,
            )
            #expect(Self.drawsRehearsalMark(warm))
            // And the warm result must match a layout that never saw a
            // cache — a cache may only skip work, never change output.
            let uncached = LayoutEngine.layout(
                score: scoreB, options: .init(), availableWidth: 800,
            )
            #expect(warm.systems == uncached.systems)
        }

        /// `MultiMeasureRestPlanner.plan` is derived from
        /// `Score.systemMeasures` too — a mark written into the middle of a
        /// collapsible run splits it. The plan is rebuilt on every
        /// `LayoutEngine.layout` call (it is computed at layout entry, not
        /// inside `buildSystem`), and the split it produces reaches the
        /// system predicate twice over: through the changed `widths`, and
        /// through `systemMeasuresForRange`. Pinned here because the two
        /// derivations of the same lane have to stay in agreement.
        @Test("Mark splitting a multi-measure-rest run reaches a warm cache")
        func multiMeasureRestRunSplitThroughCache() {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            let sounding = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [note])),
            ])])
            let rest = Measure(voices: [Voice(elements: [
                .rest(duration: .measure),
            ])])
            let measures = [sounding, rest, rest, rest, rest, sounding]
            let scoreA = Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
            )
            let options = ScoreViewOptions(
                multiMeasureRest: .collapse(minimumMeasures: 2),
            )
            let cache = LayoutCache()
            let cold = LayoutEngine.layout(
                score: scoreA, options: options,
                availableWidth: 1200, cache: cache,
            )
            #expect(Self.restRunLengths(cold) == [4])
            // Mark on measure 3 — the middle of the run. Measures 1-2 stay
            // collapsible (a run of 2); measure 4 alone no longer meets the
            // 2-measure minimum, so exactly one H-bar survives.
            let scoreB = Self.addingRehearsalMark(
                "A", atMeasure: 3, of: scoreA,
            )
            let warm = LayoutEngine.layout(
                score: scoreB, options: options,
                availableWidth: 1200, cache: cache,
            )
            #expect(Self.restRunLengths(warm) == [2])
            #expect(Self.drawsRehearsalMark(warm))
            let uncached = LayoutEngine.layout(
                score: scoreB, options: options, availableWidth: 1200,
            )
            // Measures 3 and 4 were run INTERIORS on the cold call and are
            // drawn individually now. They only come back at a real width if
            // `Entry.minWidth` kept the natural width rather than the
            // collapse override — see `minWidthSurvivesLeavingACollapsedRun`.
            #expect(warm.systems == uncached.systems)
        }

        /// The transition a `LayoutCache` has to survive: a measure that was
        /// INSIDE a collapsed run and then leaves it must come back at its
        /// natural width. Driven by the plainest trigger there is — toggling
        /// `multiMeasureRest` off through a warm cache, no score edit at all,
        /// which is enough because the plan is deliberately not part of the
        /// per-measure width predicate. When the entry stored the post-
        /// override width, the three ex-interior bars came back at width 0.
        @Test("minWidth survives a measure leaving a collapsed run")
        func minWidthSurvivesLeavingACollapsedRun() {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            let sounding = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [note])),
            ])])
            let rest = Measure(voices: [Voice(elements: [
                .rest(duration: .measure),
            ])])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [
                        sounding, rest, rest, rest, rest, sounding,
                    ])],
                )],
            )
            let cache = LayoutCache()
            let collapsed = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(
                    multiMeasureRest: .collapse(minimumMeasures: 2),
                ),
                availableWidth: 1200, cache: cache,
            )
            // Precondition: the run really did collapse, so the entries this
            // test is about were written under an override.
            #expect(Self.restRunLengths(collapsed) == [4])
            let warm = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(),
                availableWidth: 1200, cache: cache,
            )
            // Every bar is drawn individually again — none at width 0.
            let widths = warm.systems.flatMap(\.measures).map(\.width)
            #expect(widths.count == 6)
            #expect(widths.allSatisfy { $0 > 0 })
            #expect(Self.restRunLengths(warm).isEmpty)
            let uncached = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(),
                availableWidth: 1200,
            )
            #expect(widths == uncached.systems.flatMap(\.measures).map(\.width))
            #expect(warm.systems == uncached.systems)
        }

        /// H-bar lengths in document order.
        private static func restRunLengths(_ doc: LayoutDocument) -> [Int] {
            doc.systems
                .flatMap(\.measures)
                .compactMap(\.multiMeasureRest)
        }

        /// Realistic equivalence: layouts of a parsed mscx fixture must
        /// be byte-identical between cache-less and cache-aware paths.
        @Test("Real mscx fixture: cache-aware layout matches cache-less")
        func realFixtureEquivalence() throws {
            guard #available(macOS 15.0, *) else { return }
            let fixtures = [
                "midi01",
                "midi02",
                "midi03",
                "testArpeggio",
                "testVoltaDynamic",
                "testRepeatsWithKeySigs",
            ]
            for name in fixtures {
                guard let url = TestResources.url(
                    forResource: name, withExtension: "mscx",
                ) else {
                    Issue.record("Missing fixture: \(name).mscx")
                    continue
                }
                let data = try Data(contentsOf: url)
                let score = try MSCXParser.parse(data)
                let baseline = LayoutEngine.layout(
                    score: score, options: .init(), availableWidth: 800,
                )
                let cache = LayoutCache()
                let cached = LayoutEngine.layout(
                    score: score, options: .init(),
                    availableWidth: 800, cache: cache,
                )
                #expect(
                    cached.systems == baseline.systems,
                    "systems differ for \(name)",
                )
                #expect(
                    cached.size == baseline.size,
                    "size differs for \(name)",
                )
            }
        }

        /// On a real fixture, a warm second call must hit the system
        /// cache for every system — `buildSystem` is skipped wholesale.
        @Test("Real mscx fixture: warm call is fully cached at system level")
        func realFixtureWarmHitRate() throws {
            guard #available(macOS 15.0, *) else { return }
            guard let url = TestResources.url(
                forResource: "midi01", withExtension: "mscx",
            ) else {
                Issue.record("Missing fixture: midi01.mscx")
                return
            }
            let score = try MSCXParser.parse(Data(contentsOf: url))
            let cache = LayoutCache()
            _ = LayoutEngine.layout(
                score: score, options: .init(),
                availableWidth: 800, cache: cache,
            )
            let widthMissesCold = cache.widthMisses
            let systemMissesCold = cache.systemMisses
            _ = LayoutEngine.layout(
                score: score, options: .init(),
                availableWidth: 800, cache: cache,
            )
            // Warm call: zero misses, every prior miss is now a hit.
            #expect(cache.widthMisses == 0)
            #expect(cache.systemMisses == 0)
            #expect(cache.widthHits == widthMissesCold)
            #expect(cache.systemHits == systemMissesCold)
            // System hit short-circuits buildSystem entirely.
            #expect(cache.placementHits == 0)
            #expect(cache.placementMisses == 0)
        }

        /// Changing the staffSize (which changes `metrics.sp`) must
        /// invalidate every per-measure entry — none of the cached
        /// widths or placements remain valid at a different sp.
        @Test("Changing staffSize invalidates the entire cache")
        func staffSizeChangeInvalidates() throws {
            guard #available(macOS 15.0, *) else { return }
            guard let url = TestResources.url(
                forResource: "midi01", withExtension: "mscx",
            ) else {
                Issue.record("Missing fixture: midi01.mscx")
                return
            }
            let score = try MSCXParser.parse(Data(contentsOf: url))
            let cache = LayoutCache()
            _ = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(staffSize: 7),
                availableWidth: 800, cache: cache,
            )
            _ = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(staffSize: 9),
                availableWidth: 800, cache: cache,
            )
            // sp changed → every measure should miss again.
            #expect(cache.widthHits == 0)
            #expect(cache.widthMisses > 0)
            #expect(cache.placementHits == 0)
            #expect(cache.placementMisses > 0)
        }
    }
#endif
