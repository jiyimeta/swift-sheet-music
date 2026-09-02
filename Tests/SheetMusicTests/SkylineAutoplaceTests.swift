#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// `SheetMusicCore` and `SheetMusicLayout` each declare a `CGPoint` stub
    /// where CoreGraphics is absent, so naming the type in a declaration is
    /// ambiguous. Anchor to Layout's, the one the geometry under test speaks —
    /// the same file-scoped disambiguation `LayoutBridge+*.swift` uses.
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

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
    static func harmonyMeasure(
        name: String = "C", offsetX: Double = 0,
    ) -> Measure {
        Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(
                TimeSignature(numerator: 4, denominator: 4),
            ),
            .harmony(Harmony(name: name, offsetX: offsetX)),
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

    /// Two quarter chords carrying two verses, where verse 0's
    /// syllable is held across both notes so a melisma rule is
    /// emitted at verse 0's underline level.
    static func twoVerseMelismaScore() -> Score {
        var held = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 71, tpc: 17)]),
        )
        held.lyrics = [
            Lyric(text: "aah", ticks: 960, verse: 0),
            Lyric(text: "two", verse: 1),
        ]
        var second = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 71, tpc: 17)]),
        )
        second.lyrics = [Lyric(text: "verse", verse: 1)]
        return score(measures: [Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(
                TimeSignature(numerator: 4, denominator: 4),
            ),
            .chord(held),
            .chord(second),
        ])])])
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
    private let _installFontMetrics = TestSupport.installFontMetrics

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
    private let _installFontMetrics = TestSupport.installFontMetrics

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
        // `-infinity` would mean the pair never shares a horizontal
        // band, which makes `d <= 0` vacuously true.
        #expect(d.isFinite, "no horizontal interaction to test")
        #expect(d <= 0, "overlap of \(d) pt")
    }

    /// Tempo × measure number.
    ///
    /// Tempo is emitted at the first chord's tick column — past the
    /// clef and time signature — while the measure number sits at
    /// `x = −0.5 sp`, so at their default X they never share a
    /// horizontal band and the assertion would be vacuous. The
    /// `offsetX` reproduces the author `<offset>` that puts a tempo
    /// mark back over the system head, which is how the pair
    /// actually collides in the corpus.
    @available(macOS 15.0, iOS 16.0, *)
    @Test func tempoClearsMeasureNumber() throws {
        let score = SkylineFixtures.score(
            measures: [SkylineFixtures.quarterMeasure()],
            systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(
                    position: .start,
                    element: .tempo(
                        Tempo(beatsPerSecond: 2, offsetX: -9),
                    ),
                ),
            ])],
        )
        let doc = SkylineFixtures.layout(score)
        let d = try #require(SkylineFixtures.overlap(
            .tempo, .measureNumber, in: doc,
        ))
        #expect(d.isFinite, "no horizontal interaction to test")
        #expect(d <= 0, "overlap of \(d) pt")
    }

    /// Harmony × rehearsal mark.
    ///
    /// Same reasoning as `tempoClearsMeasureNumber`: a chord symbol
    /// anchored on the first chord starts to the right of a
    /// measure-left rehearsal mark, so the `offsetX` reproduces the
    /// author offset that makes the two share a horizontal band.
    @available(macOS 15.0, iOS 16.0, *)
    @Test func harmonyClearsRehearsalMark() throws {
        let score = SkylineFixtures.score(
            measures: [
                SkylineFixtures.harmonyMeasure(offsetX: -5),
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
            .harmony, .rehearsalMark, in: doc,
        ))
        #expect(d.isFinite, "no horizontal interaction to test")
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
        #expect(d.isFinite, "no horizontal interaction to test")
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

    /// …and the dynamic must not shove the lyric row halfway down
    /// the page while doing it.
    ///
    /// Found by the Task-10 corpus scan: the dynamics shape was
    /// Bravura's em box (16.1 sp at the 4 sp dynamics size) instead
    /// of the 2.4 sp of `mf` ink, so every dynamic claimed 8 sp
    /// of skyline below its own origin and the lyric row — the
    /// next below-staff category — cleared all of it.
    @available(macOS 15.0, iOS 16.0, *)
    @Test func dynamicsDoNotShoveLyricsDownAnEmBox() throws {
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
        let doc = SkylineFixtures.layout(SkylineFixtures.score(
            measures: [Measure(voices: [voice])],
        ))
        let system = try #require(doc.systems.first)
        let staffBottom = try #require(system.staffOrigins.first).y
            + system.sp * 4
        let shapes = SkylineFixtures.autoplacedShapes(doc)
        let lyr = try #require(
            shapes.first { $0.kind == .lyrics }?.shape.bbox,
        )
        let dyn = try #require(
            shapes.first { $0.kind == .dynamics }?.shape.bbox,
        )
        // Assert the relation the pass actually guarantees — the
        // lyric row clears the dynamic by exactly its own
        // `minDistance` — rather than a measured constant with
        // sp-scale slack in it. A shape that over-claims skyline
        // (the em box did, by 13.7 sp) still satisfies the
        // clearance, so ALSO pin where the row lands: 5.1 sp below
        // the staff with the correct ink, 18.8 sp with the em box
        // (both measured on this fixture).
        let clearance = AutoplaceRules.minDistance(
            for: .lyrics, sp: system.sp,
        )
        #expect(
            abs((lyr.minY - dyn.maxY) - clearance) < 0.01,
            "gap \(lyr.minY - dyn.maxY) pt vs minDistance \(clearance)",
        )
        // Apple-only: where the row lands is measured off EDWIN's ascent and
        // descent, and `SMuFLMetricsTable` measures Bravura alone, so a text
        // face still answers from `StubFontMetricsProvider` and puts the row
        // 1.4 pt lower. The clearance above is the rule this test exists for
        // and holds on every platform; this pins the fixture's own number.
        #if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
            #expect(
                abs((lyr.maxY - staffBottom) - system.sp * 5.13) < 1.0,
                "lyric row \(lyr.maxY - staffBottom) pt below the staff",
            )
        #endif
    }

    /// A melisma rule belongs to the verse row it underlines, even
    /// in a multi-verse system where the row below is nearer in
    /// raw Y.
    ///
    /// The rule is emitted at `verse0Y + melismaLineYOffset`
    /// (0.9 sp), verse rows are 1.7 sp apart, and
    /// `setMelismaAbsoluteY` snaps EVERY melisma in the system to
    /// verse 0's underline. A nearest-row search on raw Y measures
    /// 0.9 sp to verse 0 but only 0.8 sp to verse 1, so it puts the
    /// rule in verse 1's group — the rule then takes verse 1's `dy`
    /// and detaches from the syllables it underlines. Verse 1 is
    /// pushed down here (its box collides with verse 0's), so the
    /// two `dy`s differ and the offset stays diagnostic — asserted
    /// explicitly below rather than left to the reader.
    @available(macOS 15.0, iOS 16.0, *)
    @Test func melismaStaysWithItsOwnVerseRow() throws {
        let doc = SkylineFixtures.layout(
            SkylineFixtures.twoVerseMelismaScore(),
        )
        let system = try #require(doc.systems.first)
        var rows: [CGFloat] = []
        var melismaY: CGFloat?
        for measure in system.measures {
            for el in measure.elements {
                switch el {
                case let .textMark(.lyrics, _, p):
                    let y = (p.y * 100).rounded() / 100
                    if !rows.contains(y) { rows.append(y) }
                case let .lyricsMelisma(from, _):
                    melismaY = from.y
                default:
                    break
                }
            }
        }
        rows.sort()
        #expect(rows.count == 2, "fixture emitted \(rows.count) rows")
        let verse0Y = try #require(rows.first)
        let verse1Y = try #require(rows.dropFirst().first)
        // Self-guard: the assertion below is only diagnostic while
        // the two verses take DIFFERENT `dy`s. Verse rows are
        // pitched 1.7 sp apart at emission, so verse 1 having been
        // pushed further than that is what proves the buckets are
        // distinct. Were a style change to shrink verse 0's box
        // below a collision, both `dy`s would be 0 and the test
        // would pass under either bucketing.
        #expect(
            verse1Y > verse0Y + system.sp * 1.7,
            "verse 1 not pushed: rows \(verse0Y) / \(verse1Y)",
        )
        let rule = try #require(
            melismaY, "fixture emitted no melisma rule",
        )
        // The rule must still sit exactly one underline offset
        // below verse 0's row after autoplace.
        #expect(
            abs(rule - (verse0Y + system.sp * 0.9)) < 0.01,
            "rule at \(rule), verse 0 row at \(verse0Y)",
        )
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
