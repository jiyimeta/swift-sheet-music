#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// Horizontal snapping between a hairpin and the dynamic anchored at
    /// its own start / end tick — MuseScore
    /// `TLayout::manageHairpinSnapping`
    /// (`src/engraving/rendering/score/tlayout.cpp`).
    ///
    /// The vertical skyline pass cannot fix this pair: `AutoplaceRules`
    /// exempts `dynamics × hairpin` (they share one band by design) and
    /// hairpins never move, so without the horizontal trim the wedge is
    /// drawn straight through the dynamic's glyph.
    @Suite("Hairpin ↔ dynamic snapping")
    struct HairpinDynamicSnapTests {
        private let _installApple = TestSupport.installApple

        private static let division = 480
        /// `Sid::autoplaceHairpinDynamicsDistance`.
        private static let clearanceSp: CGFloat = 0.5

        /// One 4/4 measure of four quarter chords. `startDynamic` sits at
        /// tick 0, `endDynamic` at tick 1440 (beat 4), and the hairpin
        /// spans tick 0 → tick 1440.
        private static func score(
            startDynamic: String?,
            endDynamic: String?,
            spannerKind: Spanner.Kind = .hairpin,
        ) -> Score {
            let note = Note(pitch: 60, tpc: 14)
            var elements: [VoiceElement] = []
            if let startDynamic {
                elements.append(.dynamic(
                    Dynamic(subtype: startDynamic, velocity: 80),
                ))
            }
            elements.append(.spanner(Spanner(
                kind: spannerKind,
                rawType: spannerKind == .hairpin ? "HairPin" : "Pedal",
                nextMeasuresOffset: 0,
                nextFractionsOffset: Fraction(
                    numerator: 3, denominator: 4,
                ),
            )))
            for beat in 0 ..< 4 {
                if beat == 3, let endDynamic {
                    elements.append(.dynamic(
                        Dynamic(subtype: endDynamic, velocity: 96),
                    ))
                }
                elements.append(.chord(Chord(
                    duration: .quarter, notes: [note],
                )))
            }
            return Score(division: division, parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [
                    Measure(voices: [Voice(elements: elements)]),
                ])],
            )])
        }

        private static func layout(
            _ score: Score, availableWidth: CGFloat = 800,
        ) -> LayoutDocument {
            LayoutEngine.layout(
                score: score, options: .init(), availableWidth: availableWidth,
            )
        }

        /// `(fromX, toX)` of the system's single spanner segment.
        private static func segmentX(
            _ system: LayoutSystem,
        ) -> (from: CGFloat, to: CGFloat)? {
            for element in system.spanners {
                if case let .spannerSegment(_, from, to, _, _, _) = element {
                    return (from.x, to.x)
                }
            }
            return nil
        }

        @Test("A dynamic at the hairpin's start tick pushes the line right")
        func startDynamicPushesLineRight() {
            guard #available(macOS 15.0, *) else { return }
            let doc = Self.layout(
                Self.score(startDynamic: "sfz", endDynamic: nil),
            )
            guard let system = doc.systems.first,
                  let measure = system.measures.first,
                  let segment = Self.segmentX(system)
            else {
                Issue.record("expected one system with a hairpin segment")
                return
            }
            let extent = measure.dynamicExtents.first { $0.tick == 0 }
            guard let extent else {
                Issue.record("expected a dynamic extent at tick 0")
                return
            }
            let sp = doc.metrics.sp
            // The untrimmed start is the tick-0 chord column, and `sfz`
            // is wide enough to reach past it — otherwise this test
            // would pass without the snapping code running at all.
            let column = measure.origin.x + (measure.tickColumns[0] ?? 0)
            #expect(measure.origin.x + extent.maxX > column)
            #expect(abs(
                segment.from
                    - (
                        measure.origin.x + extent.maxX
                            + sp * Self.clearanceSp
                    ),
            ) < 0.001)
        }

        @Test("A dynamic at the hairpin's end tick pulls the line left")
        func endDynamicPullsLineLeft() {
            guard #available(macOS 15.0, *) else { return }
            let doc = Self.layout(
                Self.score(startDynamic: nil, endDynamic: "f"),
            )
            guard let system = doc.systems.first,
                  let measure = system.measures.first,
                  let segment = Self.segmentX(system)
            else {
                Issue.record("expected one system with a hairpin segment")
                return
            }
            let endTick = 3 * Self.division
            let extent = measure.dynamicExtents.first { $0.tick == endTick }
            guard let extent else {
                Issue.record("expected a dynamic extent at tick \(endTick)")
                return
            }
            let sp = doc.metrics.sp
            let column = measure.origin.x
                + (measure.tickColumns[endTick] ?? 0)
            // The dynamic is drawn 1 sp left of its own chord column,
            // so the untrimmed right edge really was inside its ink.
            #expect(measure.origin.x + extent.minX < column)
            #expect(abs(
                segment.to
                    - (
                        measure.origin.x + extent.minX
                            - sp * Self.clearanceSp
                    ),
            ) < 0.001)
            #expect(segment.to < segment.from + column) // sanity: not inverted
            #expect(segment.to > segment.from)
        }

        @Test("Without dynamics the hairpin keeps its full tick-column span")
        func noDynamicsLeavesGeometryUntouched() {
            guard #available(macOS 15.0, *) else { return }
            let doc = Self.layout(
                Self.score(startDynamic: nil, endDynamic: nil),
            )
            guard let system = doc.systems.first,
                  let measure = system.measures.first,
                  let segment = Self.segmentX(system)
            else {
                Issue.record("expected one system with a hairpin segment")
                return
            }
            #expect(measure.dynamicExtents.isEmpty)
            let startColumn = measure.origin.x
                + (measure.tickColumns[0] ?? 0)
            let endColumn = measure.origin.x
                + (measure.tickColumns[3 * Self.division] ?? 0)
            #expect(abs(segment.from - startColumn) < 0.001)
            #expect(abs(segment.to - endColumn) < 0.001)
        }

        @Test("Only hairpins snap — a pedal at the same tick is untouched")
        func pedalIsNotSnapped() {
            guard #available(macOS 15.0, *) else { return }
            // MuseScore's snapping chain is dynamics ↔ hairpins ↔
            // expressions only; a pedal sharing the tick keeps its
            // geometry (its own `dynamics × pedal` overlaps are a
            // separate, still-open issue).
            let doc = Self.layout(Self.score(
                startDynamic: "sfz", endDynamic: "f",
                spannerKind: .pedal,
            ))
            guard let system = doc.systems.first,
                  let measure = system.measures.first,
                  let segment = Self.segmentX(system)
            else {
                Issue.record("expected one system with a pedal segment")
                return
            }
            let startColumn = measure.origin.x
                + (measure.tickColumns[0] ?? 0)
            #expect(abs(segment.from - startColumn) < 0.001)
        }

        @Test("Dynamic extents carry the staff they belong to")
        func extentsAreTaggedPerStaff() {
            guard #available(macOS 15.0, *) else { return }
            let note = Note(pitch: 60, tpc: 14)
            func staff(_ dynamic: String) -> Staff {
                Staff(measures: [Measure(voices: [Voice(elements: [
                    .dynamic(Dynamic(subtype: dynamic, velocity: 80)),
                    .chord(Chord(duration: .whole, notes: [note])),
                ])])])
            }
            let score = Score(division: Self.division, parts: [
                Part(
                    id: "1", instrument: Instrument(id: "a"),
                    staves: [staff("p")],
                ),
                Part(
                    id: "2", instrument: Instrument(id: "b"),
                    staves: [staff("fff")],
                ),
            ])
            guard let measure = Self.layout(score)
                .systems.first?.measures.first
            else {
                Issue.record("expected one system with one measure")
                return
            }
            let byStaff = Dictionary(
                grouping: measure.dynamicExtents, by: \.staffIndex,
            )
            #expect(byStaff.count == 2)
            #expect(byStaff[0]?.count == 1)
            #expect(byStaff[1]?.count == 1)
            #expect(byStaff[0]?.first?.tick == 0)
            #expect(byStaff[1]?.first?.tick == 0)
            // `fff` is three glyphs, `p` one — the tags are not
            // interchangeable.
            let width0 = (byStaff[0]?.first).map { $0.maxX - $0.minX } ?? 0
            let width1 = (byStaff[1]?.first).map { $0.maxX - $0.minX } ?? 0
            #expect(width1 > width0)
        }

        /// Two measures: a `ppp` and a crescendo on the last beat of the
        /// first, and the `f` the wedge is heading for on the downbeat
        /// of the second — the shape a roll under a swell takes, and the
        /// one that breaks if the wedge has to stop at the bar line.
        private static func acrossBarline() -> Score {
            let note = Note(pitch: 60, tpc: 14)
            var first: [VoiceElement] = []
            for beat in 0 ..< 4 {
                if beat == 3 {
                    first.append(.dynamic(Dynamic(subtype: "ppp", velocity: 16)))
                    first.append(.spanner(Spanner(
                        kind: .hairpin, rawType: "HairPin",
                        nextMeasuresOffset: 1,
                        nextFractionsOffset: Fraction(
                            numerator: -3, denominator: 4,
                        ),
                        hairpin: .init(subtype: .crescendo),
                    )))
                }
                first.append(.chord(Chord(duration: .quarter, notes: [note])))
            }
            var second: [VoiceElement] = [
                .dynamic(Dynamic(subtype: "f", velocity: 96)),
            ]
            for _ in 0 ..< 4 {
                second.append(.chord(Chord(duration: .quarter, notes: [note])))
            }
            return Score(division: division, parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [
                    Measure(voices: [Voice(elements: first)]),
                    Measure(voices: [Voice(elements: second)]),
                ])],
            )])
        }

        @Test("A wedge ending on a bar line stops there, ahead of its dynamic")
        func endStopsAtTheBarline() {
            guard #available(macOS 15.0, *) else { return }
            let doc = Self.layout(Self.acrossBarline())
            guard let system = doc.systems.first,
                  system.measures.count >= 2,
                  let segment = Self.segmentX(system)
            else {
                Issue.record("expected one system with two measures")
                return
            }
            let next = system.measures[1]
            guard let extent = next.dynamicExtents.first(where: { $0.tick == 0 })
            else {
                Issue.record("expected the f's extent on the downbeat")
                return
            }
            // The mark the wedge is heading for is in the next measure,
            // so nothing trims the end and it keeps its bar-line inset.
            // MuseScore would reach across for a mark more than 3 sp
            // away (`manageHairpinSnapping`, EXTEND_THRESHOLD), but its
            // own rendering of this score leaves the wedge short — the
            // `f` sits just past the line. Only the shrink half is
            // ported, so this pins that the end is NOT pulled forward.
            #expect(segment.to < next.origin.x + extent.minX)
            #expect(segment.to > segment.from)
        }

        @Test("A crowded wedge keeps MuseScore's one-spatium minimum")
        func crowdedWedgeKeepsMinimumLength() {
            guard #available(macOS 15.0, *) else { return }
            // Wide marks one beat apart: the two trims cross, and what
            // is left is not a hairpin at all.
            let note = Note(pitch: 60, tpc: 14)
            var elements: [VoiceElement] = []
            for beat in 0 ..< 4 {
                if beat == 2 {
                    elements.append(.dynamic(Dynamic(subtype: "sfz", velocity: 96)))
                    elements.append(.spanner(Spanner(
                        kind: .hairpin, rawType: "HairPin",
                        nextMeasuresOffset: 0,
                        nextFractionsOffset: Fraction(
                            numerator: 1, denominator: 4,
                        ),
                        hairpin: .init(subtype: .crescendo),
                    )))
                }
                if beat == 3 {
                    elements.append(.dynamic(Dynamic(subtype: "fff", velocity: 112)))
                }
                elements.append(.chord(Chord(duration: .quarter, notes: [note])))
            }
            let doc = Self.layout(Score(division: Self.division, parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [
                    Measure(voices: [Voice(elements: elements)]),
                ])],
            )]), availableWidth: 200)
            guard let system = doc.systems.first,
                  let segment = Self.segmentX(system)
            else {
                Issue.record("expected one system with a hairpin segment")
                return
            }
            // `if (x < _spatium) { x = _spatium; }` — a wedge whose two
            // trims cross is clamped to a minimum length, never drawn
            // backwards. A reversed span mirrors the glyph: the apex
            // lands on the right and a crescendo reads as a diminuendo.
            #expect(segment.to - segment.from >= doc.metrics.sp - 0.001)
        }
    }
#endif
