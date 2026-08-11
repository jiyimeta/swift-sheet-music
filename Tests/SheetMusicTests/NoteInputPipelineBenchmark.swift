#if os(macOS)
    import Foundation
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    /// Benchmarks the *whole* note-input pipeline stage by stage, not
    /// just `LayoutEngine.layout`. Disabled by default — set
    /// `SHEETMUSIC_RUN_LAYOUT_BENCH=1` to opt in.
    ///
    /// Builds a synthetic large score (measures of a bundled fixture
    /// repeated to `measureTarget`, replicated across `staffCount`
    /// staves) so the numbers are reproducible without the gitignored
    /// `Examples/Apple/SheetMusicExample/test.mscx`.
    @Suite("NoteInputPipelineBenchmark", .serialized, .enabled(
        if: ProcessInfo.processInfo.environment[
            "SHEETMUSIC_RUN_LAYOUT_BENCH",
        ] == "1",
    ))
    struct NoteInputPipelineBenchmark {
        private let _installApple = TestSupport.installApple

        private static let measureTarget = 1300
        private static let staffCount = 6

        @Test("horizontal mode: layout vs equality vs layer build")
        func horizontalPipeline() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = try Self.makeLargeScore()
            let opts = ScoreViewOptions(wrapToViewWidth: false)
            let width = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )
            print(
                "score: \(score.allStaves.first?.staff.measures.count ?? 0) "
                    + "measures x \(score.totalStaffCount) staves, width \(Int(width))",
            )

            let cache = LayoutCache()
            var doc = time("layout cold (populate)") {
                LayoutEngine.layout(
                    score: score, options: opts,
                    availableWidth: width, cache: cache,
                )
            }
            _ = time("layout warm (all hits)") {
                LayoutEngine.layout(
                    score: score, options: opts,
                    availableWidth: width, cache: cache,
                )
            }

            let edited = Self.bumpFirstChord(of: score)
            doc = time("layout edit (1 measure)") {
                LayoutEngine.layout(
                    score: edited, options: opts,
                    availableWidth: width, cache: cache,
                )
            }

            guard let system = doc.systems.first else { return }
            print(
                "systems: \(doc.systems.count), "
                    + "measures in system 0: \(system.measures.count)",
            )

            let copy = system
            _ = time("LayoutSystem == (identical, full walk)") {
                copy == system
            }

            _ = time("ScoreLayerBuilder.buildSystemWithItems (full)") {
                ScoreLayerBuilder.buildSystemWithItems(
                    system, metrics: doc.metrics,
                )
            }
        }

        /// Measures the realistic edit path for `SystemLayerView`'s
        /// incremental update (Task 8): plan the diff via
        /// `MeasureLayerDiffPlanner.plan`, then rebuild only the
        /// measures the plan flags `.rebuild` via
        /// `ScoreLayerBuilder.buildMeasure`. This exercises the actual
        /// production decision logic (`SystemLayerView+MeasureDiff.swift`
        /// calls the same two APIs), not a hand-rolled approximation of
        /// it — unlike `buildSystemWithItems (full)` above, which always
        /// rebuilds every measure and so cannot show Phase 2's win.
        @Test("horizontal mode: incremental measure rebuild via MeasureLayerDiffPlanner")
        func incrementalLayerUpdate() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = try Self.makeLargeScore()
            let opts = ScoreViewOptions(wrapToViewWidth: false)
            let width = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )
            let cache = LayoutCache()
            let before = LayoutEngine.layout(
                score: score, options: opts,
                availableWidth: width, cache: cache,
            )
            let after = LayoutEngine.layout(
                score: Self.bumpFirstChord(of: score), options: opts,
                availableWidth: width, cache: cache,
            )
            guard let oldSystem = before.systems.first,
                  let newSystem = after.systems.first
            else { return }
            let systemSize = CGSize(
                width: newSystem.size.width,
                height: newSystem.size.height + 1,
            )
            let plan = time("MeasureLayerDiffPlanner.plan") {
                MeasureLayerDiffPlanner.plan(previous: oldSystem, system: newSystem)
            }
            let rebuilt = time("rebuild only measures the plan flags") {
                var rebuilt = 0
                for measure in newSystem.measures {
                    guard plan.updates[measure.measureIndex] == .rebuild else {
                        continue
                    }
                    _ = ScoreLayerBuilder.buildMeasure(
                        measure, metrics: after.metrics,
                        systemSize: systemSize,
                        showsInvisibleElements: newSystem.showsInvisibleElements,
                    )
                    rebuilt += 1
                }
                return rebuilt
            }
            print("    measures rebuilt: \(rebuilt) of \(newSystem.measures.count)")
            // Self-verify, or the headline number is meaningless: the
            // edit touches exactly one measure, so the plan must flag
            // exactly one. A change that silently made this benchmark
            // rebuild ZERO measures would otherwise just report a
            // wonderful time.
            #expect(
                rebuilt == 1,
                Comment(
                    rawValue: "expected the 1-note edit to flag exactly one "
                        + "measure for rebuild, got \(rebuilt) of "
                        + "\(newSystem.measures.count)",
                ),
            )
        }

        /// Split the 1-measure-edit relayout in horizontal mode into
        /// its constituent passes, so we know which ones are worth
        /// making incremental.
        @Test("horizontal mode: pass-by-pass breakdown of one edit")
        func horizontalBreakdown() throws { // swiftlint:disable:this function_body_length
            guard #available(macOS 15.0, *) else { return }
            let raw = try Self.makeLargeScore()
            let opts = ScoreViewOptions(wrapToViewWidth: false)
            let width = LayoutEngine.naturalContentWidth(
                score: raw, options: opts,
            )
            let cache = LayoutCache()
            _ = LayoutEngine.layout(
                score: raw, options: opts,
                availableWidth: width, cache: cache,
            )
            // Now time the same passes the edit relayout runs.
            let score = Self.bumpFirstChord(of: raw)

            let suppressed = time("score.suppressingRedundantAccidentals") {
                score.suppressingRedundantAccidentals()
            }
            let metrics = StaffMetrics(staffSize: opts.staffSize)
            let effTicks = time("computeEffectiveMelismaTicks") {
                LayoutEngine.computeEffectiveMelismaTicks(
                    score: suppressed, division: suppressed.division,
                )
            }
            let melismas = time("computeMelismaContinuations") {
                LayoutEngine.computeMelismaContinuations(
                    score: suppressed, division: suppressed.division,
                    effectiveTicks: effTicks,
                )
            }
            let coverage = time("belowStaffSpannerCoverage") {
                LayoutEngine.belowStaffSpannerCoverage(score: suppressed)
            }
            let mmr = time("MultiMeasureRestPlanner.plan") {
                MultiMeasureRestPlanner.plan(
                    for: suppressed, policy: opts.multiMeasureRest,
                )
            }
            let staves = suppressed.allStaves.map(\.staff)
            let measureDurations = LayoutEngine
                .effectiveMeasureDurationsAcrossStaves(staves: staves)
            let staffMeasureDurations: [[Fraction]] = staves.map {
                $0.measures.effectiveMeasureDurations()
            }
            let context = LayoutEngine.RenderContext(
                score: suppressed,
                options: opts,
                metrics: metrics,
                availableWidth: width,
                melismaContinuations: melismas,
                effectiveMelismaTicks: effTicks,
                cache: cache,
                belowStaffSpannerCoverage: coverage,
                spannerAnchors: LayoutEngine.collectSpanners(score: score),
                multiMeasureRestPlan: mmr,
                measureDurations: measureDurations,
                staffMeasureDurations: staffMeasureDurations,
            )
            let hits0 = cache.placementHits
            let misses0 = cache.placementMisses
            let widthHits0 = cache.widthHits
            let widthMisses0 = cache.widthMisses
            let systems = time("packSystems (incl. buildSystem)") {
                LayoutEngine.packSystems(context: context)
            }
            print(
                "    placement hits/misses: "
                    + "\(cache.placementHits - hits0)/"
                    + "\(cache.placementMisses - misses0)  "
                    + "width hits/misses: \(cache.widthHits - widthHits0)/"
                    + "\(cache.widthMisses - widthMisses0)  "
                    + "system hits/misses: \(cache.systemHits)/\(cache.systemMisses)",
            )
            let anchors = time("collectSpanners") {
                LayoutEngine.collectSpanners(score: suppressed)
            }
            let withSpanners = time("attachSpanners") {
                LayoutEngine.attachSpanners(
                    to: systems, anchors: anchors,
                    score: suppressed, metrics: metrics,
                )
            }
            let doc = LayoutDocument(
                size: CGSize(width: width, height: 1),
                systems: withSpanners, metrics: metrics, titleFrame: nil,
            )
            let ties = time("resolveTies") {
                LayoutEngine.resolveTies(for: doc, score: suppressed)
            }
            let withTies = time("attachTies") {
                LayoutEngine.attachTies(
                    to: withSpanners, pairs: ties, metrics: metrics,
                )
            }
            let gliss = time("resolveGlissandi") {
                LayoutEngine.resolveGlissandi(for: doc, score: suppressed)
            }
            _ = time("attachGlissandi") {
                LayoutEngine.attachGlissandi(
                    to: withTies, pairs: gliss, metrics: metrics,
                )
            }
            // How much of a system rebuild is just `LayoutSystem.init`
            // recomputing eventColumns for the whole score?
            if let sys = withTies.first {
                _ = time("LayoutSystem.init (eventColumns rebuild)") {
                    LayoutEngine.shift(sys, byY: 1)
                }
            }
        }

        @Test("vertical mode: layout vs per-system equality + rebuild")
        func verticalPipeline() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = try Self.makeLargeScore()
            let opts = ScoreViewOptions(wrapToViewWidth: true)
            let width: CGFloat = 900

            let cache = LayoutCache()
            _ = time("layout cold (populate)") {
                LayoutEngine.layout(
                    score: score, options: opts,
                    availableWidth: width, cache: cache,
                )
            }
            let edited = Self.bumpFirstChord(of: score)
            let doc = time("layout edit (1 measure)") {
                LayoutEngine.layout(
                    score: edited, options: opts,
                    availableWidth: width, cache: cache,
                )
            }
            print("systems: \(doc.systems.count)")

            let systems = doc.systems
            let copies = systems
            _ = time("all systems == (identical, full walk)") {
                zip(copies, systems).allSatisfy { $0 == $1 }
            }

            _ = time("rebuild ALL systems' layers") {
                systems.map {
                    ScoreLayerBuilder.buildSystemWithItems(
                        $0, metrics: doc.metrics,
                    )
                }
            }
            if let first = systems.first {
                _ = time("rebuild ONE system's layers") {
                    ScoreLayerBuilder.buildSystemWithItems(
                        first, metrics: doc.metrics,
                    )
                }
            }
        }

        // MARK: - Helpers

        @discardableResult
        private func time<T>(_ label: String, _ body: () -> T) -> T {
            let t0 = Date()
            let result = body()
            let ms = Date().timeIntervalSince(t0) * 1000
            let padded = label.count < 46
                ? label + String(repeating: " ", count: 46 - label.count)
                : label
            print("  \(padded) \(String(format: "%8.1f", ms)) ms")
            return result
        }

        /// Repeat a fixture's measures up to `measureTarget` and clone
        /// the staff across `staffCount` parts.
        private static func makeLargeScore() throws -> Score {
            let url = URL(
                fileURLWithPath:
                "Tests/SheetMusicTests/Resources/testMeasureRepeats.mscx",
            )
            let base = try MSCXParser.parse(Data(contentsOf: url))
            guard let template = base.parts.first,
                  let staff = template.staves.first,
                  !staff.measures.isEmpty
            else {
                throw SheetMusicError.malformedScore(reason: "empty fixture")
            }

            var measures: [Measure] = []
            while measures.count < measureTarget {
                measures.append(contentsOf: staff.measures)
            }
            measures = Array(measures.prefix(measureTarget))

            let parts = (0 ..< staffCount).map { idx in
                Part(
                    id: "P\(idx)",
                    trackName: "Staff \(idx + 1)",
                    instrument: template.instrument,
                    staves: [Staff(measures: measures)],
                )
            }
            return Score(
                division: base.division,
                parts: parts,
                metaTags: base.metaTags,
                titleFrame: base.titleFrame,
                style: base.style,
            )
        }

        /// Mutate one chord in the first staff's first eligible measure.
        private static func bumpFirstChord(of score: Score) -> Score {
            var parts = score.parts
            guard !parts.isEmpty, !parts[0].staves.isEmpty else { return score }
            var measures = parts[0].staves[0].measures
            for mi in measures.indices {
                var voices = measures[mi].voices
                var changed = false
                outer: for vi in voices.indices {
                    var elements = voices[vi].elements
                    for ei in elements.indices {
                        if case var .chord(c) = elements[ei], !c.notes.isEmpty {
                            let n = c.notes[0]
                            c.notes[0] = Note(
                                pitch: n.pitch == 60 ? 62 : 60,
                                tpc: n.pitch == 60 ? 16 : 14,
                            )
                            elements[ei] = .chord(c)
                            voices[vi] = Voice(elements: elements)
                            changed = true
                            break outer
                        }
                    }
                }
                if changed {
                    measures[mi] = Measure(
                        voices: voices,
                        lineBreak: measures[mi].lineBreak,
                        pageBreak: measures[mi].pageBreak,
                    )
                    parts[0].staves[0] = Staff(measures: measures)
                    return Score(
                        division: score.division,
                        parts: parts,
                        metaTags: score.metaTags,
                        titleFrame: score.titleFrame,
                        style: score.style,
                    )
                }
            }
            return score
        }
    }
#endif
