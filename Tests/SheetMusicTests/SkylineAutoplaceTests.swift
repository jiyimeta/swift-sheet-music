#if !os(Android)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// Shared fixtures for the skyline autoplace regressions.
    enum SkylineFixtures {
        static func score(
            measures: [Measure], systemMeasures: [SystemMeasure] = [],
        ) -> Score {
            Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "voice"),
                    staves: [Staff(measures: measures)],
                )],
                systemMeasures: systemMeasures,
            )
        }

        static func quarterMeasure(pitch: Int = 71) -> Measure {
            Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(
                    TimeSignature(numerator: 4, denominator: 4),
                ),
                .chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: pitch, tpc: 17)]),
                )),
            ])])
        }

        @available(macOS 15.0, iOS 16.0, *)
        static func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: 28),
                availableWidth: 800,
            )
        }

        /// Absolute (document-space) shapes of every autoplaced element
        /// in the first system, keyed by kind.
        @available(macOS 15.0, iOS 16.0, *)
        static func autoplacedShapes(
            _ doc: LayoutDocument,
        ) -> [(kind: ShapeItemKind, shape: LayoutShape)] {
            var result: [(ShapeItemKind, LayoutShape)] = []
            guard let system = doc.systems.first else { return [] }
            let metrics = StaffMetrics(staffSize: system.sp * 4)
            var id = 0
            for measure in system.measures {
                for el in measure.elements
                    + measure.markers + measure.jumps
                {
                    guard let kind = LayoutElementShape.kind(of: el),
                          AutoplaceRules.isAutoplaced(kind),
                          let shape = LayoutElementShape.shape(
                              for: el, id: id,
                              xOffset: measure.origin.x,
                              metrics: metrics,
                          )
                    else { continue }
                    id += 1
                    result.append((kind, shape))
                }
            }
            return result
        }

        /// Overlap (pt) between the first shape of kind `a` and the
        /// first of kind `b`; `nil` when either is absent.
        @available(macOS 15.0, iOS 16.0, *)
        static func overlap(
            _ a: ShapeItemKind, _ b: ShapeItemKind,
            in doc: LayoutDocument,
        ) -> CGFloat? {
            let shapes = autoplacedShapes(doc)
            guard let sa = shapes.first(where: { $0.kind == a })?.shape,
                  let sb = shapes.first(where: { $0.kind == b })?.shape
            else { return nil }
            return max(
                sa.minVerticalDistance(sb, minHorizontalClearance: 0),
                sb.minVerticalDistance(sa, minHorizontalClearance: 0),
            )
        }
    }

    @Suite("Measure numbers participate in the per-staff buffer")
    struct MeasureNumberEmissionTests {
        private let _installApple = TestSupport.installApple

        /// The measure number is emitted into `elements`, not `markers`,
        /// so the skyline pass can see and move it.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func measureNumberLandsInElements() throws {
            let score = SkylineFixtures.score(measures: [
                SkylineFixtures.quarterMeasure(),
                SkylineFixtures.quarterMeasure(),
            ])
            let doc = SkylineFixtures.layout(score)
            let system = try #require(doc.systems.first)
            let first = try #require(system.measures.first)
            let inElements = first.elements.contains {
                if case .measureNumber = $0 { true } else { false }
            }
            let inMarkers = first.markers.contains {
                if case .measureNumber = $0 { true } else { false }
            }
            #expect(inElements)
            #expect(!inMarkers)
        }

        /// Its absolute Y is unchanged by the relocation: still
        /// 1.5 sp above the top staff line of staff 0.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func measureNumberKeepsItsAbsoluteY() throws {
            let score = SkylineFixtures.score(measures: [
                SkylineFixtures.quarterMeasure(),
            ])
            let doc = SkylineFixtures.layout(score)
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            var found: CGPoint?
            for el in measure.elements {
                if case let .measureNumber(_, p) = el { found = p }
            }
            let p = try #require(found)
            let staffTop = try #require(system.staffOrigins.first).y
            #expect(abs(p.y - (staffTop - system.sp * 1.5)) < 0.01)
            #expect(abs(p.x - (-system.sp * 0.5)) < 0.01)
        }
    }
#endif
