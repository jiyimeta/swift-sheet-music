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

        /// `quarterMeasure` plus a chord symbol on the downbeat.
        /// `Harmony` is a `VoiceElement`, not a `Measure` property.
        static func harmonyMeasure(name: String = "C") -> Measure {
            Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(
                    TimeSignature(numerator: 4, denominator: 4),
                ),
                .harmony(Harmony(name: name)),
                .chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: 71, tpc: 17)]),
                )),
            ])])
        }

        /// A measure whose only event is a quarter REST, so nothing
        /// in the base skyline pokes above the staff.
        static func restMeasure() -> Measure {
            Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(
                    TimeSignature(numerator: 4, denominator: 4),
                ),
                .chord(Chord(
                    duration: .quarter, notes: ChordNotes([]),
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

        /// Y of the first `.staffText` in the first system.
        @available(macOS 15.0, iOS 16.0, *)
        static func staffTextY(in doc: LayoutDocument) -> CGFloat? {
            guard let system = doc.systems.first else { return nil }
            for measure in system.measures {
                for el in measure.elements {
                    if case let .staffText(_, p, _, _) = el { return p.y }
                }
            }
            return nil
        }

        /// Vertical overlap (pt) between the first shape of kind `a`
        /// and the first of kind `b`; `nil` when either is absent.
        /// Positive = the two inks share vertical band while also
        /// sharing horizontal band; negative = that much clearance;
        /// `-infinity` = they never meet horizontally.
        ///
        /// `LayoutShape.minVerticalDistance` is deliberately NOT used:
        /// it is directional ("how far must the receiver move down to
        /// clear the argument"), so combining both directions with
        /// `max` returns `lower.maxY - upper.minY`, which stays large
        /// and positive however far apart the two shapes are pushed.
        /// Collision detection needs the shared band instead — the
        /// same reasoning as `CollisionReport.overlapDepth`.
        @available(macOS 15.0, iOS 16.0, *)
        static func overlap(
            _ a: ShapeItemKind, _ b: ShapeItemKind,
            in doc: LayoutDocument,
        ) -> CGFloat? {
            let shapes = autoplacedShapes(doc)
            guard let sa = shapes.first(where: { $0.kind == a })?.shape,
                  let sb = shapes.first(where: { $0.kind == b })?.shape
            else { return nil }
            var deepest = -CGFloat.infinity
            for ra in sa.rects {
                for rb in sb.rects {
                    guard min(ra.rect.maxX, rb.rect.maxX)
                        > max(ra.rect.minX, rb.rect.minX)
                    else { continue }
                    deepest = max(
                        deepest,
                        min(ra.rect.maxY, rb.rect.maxY)
                            - max(ra.rect.minY, rb.rect.minY),
                    )
                }
            }
            return deepest
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

    @Suite("Skyline autoplace removes annotation collisions")
    struct SkylineAutoplaceRegressionTests {
        private let _installApple = TestSupport.installApple

        /// Rehearsal mark × measure number: both default to the same
        /// band at the head of a system.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func rehearsalMarkClearsMeasureNumber() throws {
            let score = SkylineFixtures.score(
                measures: [
                    SkylineFixtures.quarterMeasure(),
                    SkylineFixtures.quarterMeasure(),
                ],
                systemMeasures: [SystemMeasure(elements: [
                    PositionedSystemElement(
                        position: .start,
                        element: .rehearsalMark(
                            RehearsalMark(text: "A"),
                        ),
                    ),
                ])],
            )
            let doc = SkylineFixtures.layout(score)
            let d = try #require(SkylineFixtures.overlap(
                .rehearsalMark, .measureNumber, in: doc,
            ))
            #expect(d <= 0, "overlap of \(d) pt")
        }

        /// Tempo × measure number.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func tempoClearsMeasureNumber() throws {
            let score = SkylineFixtures.score(
                measures: [SkylineFixtures.quarterMeasure()],
                systemMeasures: [SystemMeasure(elements: [
                    PositionedSystemElement(
                        position: .start,
                        element: .tempo(Tempo(beatsPerSecond: 2)),
                    ),
                ])],
            )
            let doc = SkylineFixtures.layout(score)
            let d = try #require(SkylineFixtures.overlap(
                .tempo, .measureNumber, in: doc,
            ))
            #expect(d <= 0, "overlap of \(d) pt")
        }

        /// Harmony × rehearsal mark.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func harmonyClearsRehearsalMark() throws {
            let score = SkylineFixtures.score(
                measures: [SkylineFixtures.harmonyMeasure()],
                systemMeasures: [SystemMeasure(elements: [
                    PositionedSystemElement(
                        position: .start,
                        element: .rehearsalMark(
                            RehearsalMark(text: "A"),
                        ),
                    ),
                ])],
            )
            let doc = SkylineFixtures.layout(score)
            let d = try #require(SkylineFixtures.overlap(
                .harmony, .rehearsalMark, in: doc,
            ))
            #expect(d <= 0, "overlap of \(d) pt")
        }

        /// Lyrics × dynamics — the pair that motivated the port. Both
        /// default to `staffMidY + 4 sp`; after the change dynamics sit
        /// CLOSER to the staff and lyrics are pushed below them.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func lyricsClearDynamics() throws {
            let note = Note(pitch: 71, tpc: 17)
            var chord = Chord(
                duration: .quarter, notes: ChordNotes([note]),
            )
            chord.lyrics = [Lyric(text: "sing", verse: 0)]
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(
                    TimeSignature(numerator: 4, denominator: 4),
                ),
                .dynamic(Dynamic(subtype: "mf", velocity: 80)),
                .chord(chord),
            ])
            let score = SkylineFixtures.score(
                measures: [Measure(voices: [voice])],
            )
            let doc = SkylineFixtures.layout(score)
            let d = try #require(SkylineFixtures.overlap(
                .lyrics, .dynamics, in: doc,
            ))
            #expect(d <= 0, "overlap of \(d) pt")
            // MuseScore's ordering: dynamics closer to the staff.
            let shapes = SkylineFixtures.autoplacedShapes(doc)
            let dyn = try #require(
                shapes.first { $0.kind == .dynamics }?.shape.bbox,
            )
            let lyr = try #require(
                shapes.first { $0.kind == .lyrics }?.shape.bbox,
            )
            #expect(dyn.midY < lyr.midY)
        }

        /// The pass only ever pushes AWAY from the staff: with nothing
        /// to collide with, an element keeps its emitted Y.
        ///
        /// The measure holds a REST rather than a note: a quarter rest
        /// stays between the outer staff lines, so `Skyline.add`'s
        /// staff-line filter keeps the north skyline empty apart from
        /// the clef, which the text clears horizontally. With a note
        /// the fixture would not be isolated — see
        /// `stemTipLiftsStaffTextByMinDistance`.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func isolatedElementIsNotMoved() throws {
            let score = SkylineFixtures.score(
                measures: [SkylineFixtures.restMeasure()],
                systemMeasures: [SystemMeasure(elements: [
                    PositionedSystemElement(
                        position: .start,
                        element: .staffText(StaffText(text: "dolce")),
                    ),
                ])],
            )
            let doc = SkylineFixtures.layout(score)
            let system = try #require(doc.systems.first)
            let staffTop = try #require(system.staffOrigins.first).y
            let y = try #require(SkylineFixtures.staffTextY(in: doc))
            // Default emission: staffMidY − 3 sp, i.e. staffTop − 1 sp.
            #expect(abs(y - (staffTop - system.sp)) < 0.01)
        }

        /// …and when it DOES collide, it moves away from the staff by
        /// exactly `Sid::minVerticalDistance` (0.5 sp) and never toward
        /// it. The default emission puts staff text at `staffMidY − 3
        /// sp`, whose baseline lands exactly on the tip of the quarter
        /// note's up-stem, so the required clearance is the bare
        /// minimum distance.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func stemTipLiftsStaffTextByMinDistance() throws {
            let score = SkylineFixtures.score(
                measures: [SkylineFixtures.quarterMeasure()],
                systemMeasures: [SystemMeasure(elements: [
                    PositionedSystemElement(
                        position: .start,
                        element: .staffText(StaffText(text: "dolce")),
                    ),
                ])],
            )
            let doc = SkylineFixtures.layout(score)
            let system = try #require(doc.systems.first)
            let staffTop = try #require(system.staffOrigins.first).y
            let y = try #require(SkylineFixtures.staffTextY(in: doc))
            let emitted = staffTop - system.sp
            // Away from the staff = up = smaller Y. Never toward it.
            #expect(y <= emitted + 0.01)
            #expect(abs(y - (emitted - system.sp * 0.5)) < 0.01)
        }
    }
#endif
