#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// The glyphs and bands MuseScore measures against the staff's OWN
    /// height rather than against the five-line reference frame `step`
    /// lives in — and, just as important, the ones it deliberately does
    /// not.
    @Suite("Staff line count — centered glyphs and bands")
    struct StaffLineCountGlyphTests {
        private let _installApple = TestSupport.installApple

        /// One staff of `lineCount` lines carrying a clef, a time
        /// signature, a quarter rest, and a G4 quarter with a staccato.
        private static func score(
            lineCount: Int, clef: String,
        ) -> Score {
            let measure = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: clef)),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [])),
                .chord(Chord(
                    duration: .quarter,
                    notes: [Note(pitch: 67, tpc: 15)],
                    articulations: [ChordArticulation(kind: .staccato)],
                )),
            ])])
            return Score(division: 480, parts: [Part(
                id: "P1",
                instrument: Instrument(id: "perc"),
                staves: [Staff(lineCount: lineCount, measures: [measure])],
            )])
        }

        /// Every measure element's Y expressed in staff spaces below the
        /// staff's own TOP line, which is where `StaffRenderer` starts
        /// drawing and is fixed for every line count.
        private static func placed(
            lineCount: Int, clef: String = "PERC",
        ) throws -> [(element: LayoutElement, dy: CGFloat)] {
            guard #available(macOS 15.0, *) else { return [] }
            let doc = LayoutEngine.layout(
                score: score(lineCount: lineCount, clef: clef),
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let system = try #require(doc.systems.first)
            let origin = try #require(system.staffOrigins.first).y
            var out: [(LayoutElement, CGFloat)] = []
            for measure in system.measures {
                for element in measure.elements {
                    let ys = LayoutEngine.elementYPoints(element)
                    guard let y = ys.first else { continue }
                    out.append((element, (y - origin) / system.sp))
                }
            }
            return out
        }

        private static func dy(
            lineCount: Int, clef: String = "PERC",
            where match: (LayoutElement) -> Bool,
        ) throws -> CGFloat {
            let hit = try #require(
                placed(lineCount: lineCount, clef: clef).first {
                    match($0.element)
                },
            )
            return hit.dy
        }

        // MARK: - Percussion clef

        /// `TLayout` (`tlayout.cpp:1706-1710`) centers a percussion clef
        /// on the staff: `yoff = lineDist * (lines - 1) * 0.5`, measured
        /// from the top line. So 5 lines → 2 sp (the middle line), 3 → 1,
        /// 1 → 0, i.e. ON the single drawn line rather than stranded
        /// 2 sp below it.
        @Test(
            "A percussion clef centers on the staff's own height",
            arguments: [(lineCount: 5, dy: 2.0), (3, 1.0), (1, 0.0)],
        )
        func percussionClefCentersOnTheStaff(
            lineCount: Int, dy expected: Double,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let dy = try Self.dy(lineCount: lineCount) {
                if case .clef = $0 { return true }
                return false
            }
            #expect(abs(dy - CGFloat(expected)) < 0.001)
        }

        /// The other half of the rule, and the one a blanket "center the
        /// clef" change would break: `tlayout.cpp:1687` computes a
        /// pitched clef's `yoff` from a hardcoded 5 and never consults
        /// `lines()`, so a G clef stays exactly where a five-line staff
        /// would put it — anchored to the same reference frame the
        /// noteheads it governs are.
        @Test("A pitched clef does NOT move with the line count")
        func pitchedClefIgnoresTheLineCount() throws {
            guard #available(macOS 15.0, *) else { return }
            for lineCount in [5, 3, 1] {
                let dy = try Self.dy(lineCount: lineCount, clef: "G") {
                    if case .clef = $0 { return true }
                    return false
                }
                // The G clef's own +1 sp glyph offset is applied by the
                // renderers, so the emitted origin is the reference
                // middle line: 2 sp below the top line at every count.
                #expect(
                    abs(dy - 2) < 0.001,
                    "line count \(lineCount) put the G clef at \(dy) sp",
                )
            }
        }

        // MARK: - Time signature

        /// Not covered by the task brief, which had not checked it.
        /// `TLayout` (`tlayout.cpp:6095`) derives the time signature's
        /// `yoff` as `spatium * (numOfLines - 1) * .5 * lineDist` — the
        /// same centering the percussion clef gets, so it is line-count
        /// DEPENDENT and had to move.
        @Test(
            "A time signature centers on the staff's own height",
            arguments: [(lineCount: 5, dy: 2.0), (3, 1.0), (1, 0.0)],
        )
        func timeSignatureCentersOnTheStaff(
            lineCount: Int, dy expected: Double,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let dy = try Self.dy(lineCount: lineCount) {
                if case .timeSignature = $0 { return true }
                return false
            }
            #expect(abs(dy - CGFloat(expected)) < 0.001)
        }

        // MARK: - Rests

        /// `RestLayout::computeNaturalLine` (`restlayout.cpp:688-692`)
        /// puts a rest on line `lines / 2` counted down from the top
        /// line, then adds the voice and whole-rest offsets. A quarter
        /// rest takes neither, so it lands on the natural line itself.
        @Test(
            "A rest centers on the staff's natural line",
            arguments: [(lineCount: 5, dy: 2.0), (3, 1.0), (1, 0.0)],
        )
        func restCentersOnTheNaturalLine(
            lineCount: Int, dy expected: Double,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let dy = try Self.dy(lineCount: lineCount) {
                if case .rest = $0 { return true }
                return false
            }
            #expect(abs(dy - CGFloat(expected)) < 0.001)
        }

        /// A WHOLE rest normally hangs one line above the natural line,
        /// but `RestLayout::computeWholeOrBreveRestOffset`
        /// (`restlayout.cpp:766-780`) reads `lines`, and on a one-line
        /// staff with no voice offset the predicate is false — the rest
        /// stays ON the single line.
        ///
        /// The Y is only half of it. `Rest::getSymbol`
        /// (`dom/rest.cpp:258-259`) picks the leger-line variant from
        /// `line < 0 || line >= lines`, so a rest hung a line too high
        /// on a one-line staff is also drawn as `restWholeLegerLine`
        /// instead of `restWhole` — visible in the corpus render as a
        /// wide stroke through every empty drumset bar. Both are
        /// asserted: a Y-only check passes on a fixture whose glyph is
        /// still wrong, and the glyph flag is what a reader actually
        /// notices.
        @Test(
            "A whole rest takes MuseScore's line move, glyph included",
            arguments: [
                (lineCount: 5, dy: 1.0, leger: false),
                (3, 0.0, false),
                (1, 0.0, false),
            ],
        )
        func wholeRestFollowsTheLineCountRule(
            lineCount: Int, dy expected: Double, leger: Bool,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let measure = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "PERC")),
                .chord(Chord(duration: .whole, notes: [])),
            ])])
            let score = Score(division: 480, parts: [Part(
                id: "P1",
                instrument: Instrument(id: "perc"),
                staves: [Staff(lineCount: lineCount, measures: [measure])],
            )])
            let doc = LayoutEngine.layout(
                score: score,
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let system = try #require(doc.systems.first)
            let origin = try #require(system.staffOrigins.first).y
            func probe(_ element: LayoutElement) -> (y: CGFloat, leger: Bool)? {
                if case let .rest(_, p, _, _, hasLeger) = element {
                    return (p.y, hasLeger)
                }
                return nil
            }
            let rest = try #require(
                system.measures.flatMap(\.elements).compactMap(probe).first,
            )
            #expect(
                abs((rest.y - origin) / system.sp - CGFloat(expected))
                    < 0.001,
            )
            #expect(rest.leger == leger)
        }

        // MARK: - Articulations

        /// `articulationElements`'s `lastStaffLine` is the half-space
        /// index of the staff's BOTTOM drawn line — 8 for five lines, 4
        /// for three, 0 for one — and it decides whether a close-to-note
        /// glyph is nudged into the next space (inside the staff) or set
        /// a flat 1 sp off the notehead (at or past the outer line).
        ///
        /// G4 is `step` −2, half-space line 6: inside a five-line staff,
        /// but two lines BELOW a three-line staff's bottom. Hardcoding 8
        /// treats it as inside at both counts and puts the staccato
        /// 0.5 sp too far out on the shorter staff.
        @Test("A staccato reads the staff's own bottom line")
        func articulationBoundReadsTheDrawnBottomLine() throws {
            guard #available(macOS 15.0, *) else { return }
            let five = try Self.dy(lineCount: 5) {
                if case .articulation = $0 { return true }
                return false
            }
            let three = try Self.dy(lineCount: 3) {
                if case .articulation = $0 { return true }
                return false
            }
            #expect(
                abs((five - three) - 0.5) < 0.001,
                "five-line \(five) sp vs three-line \(three) sp",
            )
        }

        // MARK: - Sticky header

        /// `stickyHeaderSystem` re-emits the clef / key / time column
        /// into a frozen pane, and it does so from its own copy of the
        /// placement math — the score body's centering does not reach
        /// it. The pane is a runtime overlay, so the corpus pixel gate
        /// cannot reach it either, and the only other test that touches
        /// `stickyHeaderSystem` asserts `anchor == nil` and nothing
        /// about Y. Delete both offsets in `LayoutEngine+Contexts` and
        /// every other assertion in the suite stays green while a
        /// drumset score's sticky header shows an uncentered clef and
        /// time signature over a body that centers them.
        @Test(
            "The sticky header centers the same glyphs the body does",
            arguments: [(lineCount: 5, dy: 2.0), (3, 1.0), (1, 0.0)],
        )
        func stickyHeaderCentersTheSameGlyphs(
            lineCount: Int, dy expected: Double,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.score(lineCount: lineCount, clef: "PERC")
            let doc = LayoutEngine.layout(
                score: score,
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let template = try #require(doc.systems.first)
            let context = try #require(
                LayoutEngine.measureContexts(for: score).first,
            )
            let sticky = LayoutEngine.stickyHeaderSystem(
                for: context,
                templateSystem: template,
                metrics: doc.metrics,
            )
            let measure = try #require(sticky.measures.first)
            let origin = try #require(sticky.staffOrigins.first).y
            let sp = doc.metrics.sp
            var clefY: CGFloat?
            var timeSigY: CGFloat?
            for element in measure.elements {
                switch element {
                case let .clef(_, p, _): clefY = clefY ?? p.y
                case let .timeSignature(_, _, p): timeSigY = timeSigY ?? p.y
                default: continue
                }
            }
            let clef = try #require(clefY)
            let timeSig = try #require(timeSigY)
            #expect(abs((clef - origin) / sp - CGFloat(expected)) < 0.001)
            #expect(abs((timeSig - origin) / sp - CGFloat(expected)) < 0.001)
        }

        // MARK: - Jump text

        /// Jump text hangs 1 sp below staff 0 and has to clear its INK.
        /// Noteheads keep occupying the five-line reference band at every
        /// line count, so unlike the cursor or the barline this distance
        /// must NOT shrink with the drawn height — on a one-line staff it
        /// would otherwise land 1 sp ABOVE `step` 0, inside the notes.
        @Test("Jump text keeps clearing the reference band")
        func jumpTextDoesNotFollowTheDrawnHeight() throws {
            guard #available(macOS 15.0, *) else { return }
            func jumpDy(lineCount: Int) throws -> CGFloat {
                let measure = Measure(
                    voices: [Voice(elements: [
                        .clef(Clef(concertClefType: "G")),
                        .chord(Chord(
                            duration: .whole,
                            notes: [Note(pitch: 77, tpc: 13)],
                        )),
                    ])],
                    jumps: [Jump(
                        jumpTo: "start", playUntil: "end", text: "D.C.",
                    )],
                )
                let score = Score(division: 480, parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "perc"),
                    staves: [Staff(
                        lineCount: lineCount, measures: [measure],
                    )],
                )])
                let doc = LayoutEngine.layout(
                    score: score,
                    options: .init(wrapToViewWidth: false),
                    availableWidth: 900,
                )
                let system = try #require(doc.systems.first)
                let origin = try #require(system.staffOrigins.first).y
                let y = try #require(
                    system.measures.flatMap(\.jumps).compactMap {
                        if case let .jump(_, p) = $0 { return p.y }
                        return nil
                    }.first,
                )
                return (y - origin) / system.sp
            }
            #expect(try abs(jumpDy(lineCount: 1) - jumpDy(lineCount: 5)) < 0.001)
        }
    }

    /// The skyline's own half of the change: the band `Skyline` measures
    /// "pokes outside the staff" against.
    @Suite("Staff line count — skyline band")
    struct StaffLineCountSkylineTests {
        private let _installApple = TestSupport.installApple

        /// Run one autoplaced tempo mark through the pass with the three
        /// candidate bands and report where it lands.
        ///
        /// The tempo starts 1.5 sp above the top line. Against the staff
        /// as DRAWN — five lines `[2, 6]` sp or one line `[2, 2]` sp — it
        /// clears the staff and keeps (almost) its emitted Y. Against the
        /// phantom `staffMidY ∓ 2 sp` band a one-line staff used to get,
        /// `[0, 4]` sp, it collides with a staff top 2 sp higher than any
        /// ink and is shoved a further 2 sp up.
        @available(macOS 15.0, *)
        private static func tempoY(
            staffTop: CGFloat, staffBottom: CGFloat, metrics: StaffMetrics,
        ) -> CGFloat {
            var measures: [[LayoutElement]] = [[.textMark(
                kind: .tempo, text: "Allegro",
                origin: CGPoint(x: 20, y: metrics.sp * 0.5),
            )]]
            SkylineAutoplacePass.run(
                measures: &measures, xOffsets: [0], systemRightX: 400,
                staffTop: staffTop, staffBottom: staffBottom,
                metrics: metrics,
            )
            guard case let .textMark(_, _, p) = measures[0][0] else { return .nan }
            return p.y / metrics.sp
        }

        @Test("The skyline band is the staff as drawn, not a phantom one")
        func skylineBandIsTheDrawnStaff() {
            guard #available(macOS 15.0, *) else { return }
            let metrics = StaffMetrics(staffSize: 28)
            let sp = metrics.sp
            let fiveLine = Self.tempoY(
                staffTop: 2 * sp, staffBottom: 6 * sp, metrics: metrics,
            )
            let oneLine = Self.tempoY(
                staffTop: 2 * sp, staffBottom: 2 * sp, metrics: metrics,
            )
            let phantom = Self.tempoY(
                staffTop: 0, staffBottom: 4 * sp, metrics: metrics,
            )
            // A one-line staff's top line is the SAME line a five-line
            // staff's is, so the north edge — and the tempo — must not
            // move between them.
            #expect(abs(oneLine - fiveLine) < 0.001)
            // The phantom band starts 2 sp higher than any drawn line
            // and pushes the mark the same 2 sp further away.
            #expect(abs((fiveLine - phantom) - 2) < 0.001)
        }

        /// End-to-end wiring: `buildSystem` has to hand the pass the
        /// staff's drawn band, and `defaultBandOffsetY` has to measure
        /// the below-staff band from the staff's own bottom line. A
        /// rest-only measure keeps the south skyline free of stems and
        /// noteheads, so the phantom staff rect is the only thing that
        /// could push the hairpin — and with the band correct, nothing
        /// does: the segment stays at exactly the styled default.
        ///
        /// Measured: 7 sp at five lines, 5 sp at three, 3 sp at one.
        /// With `defaultBandOffsetY` back on `metrics.staffHeight` the
        /// three-line case reads 7 sp; with the pass back on
        /// `staffMidY ∓ 2 sp` the one-line case reads 3.2 sp.
        @Test(
            "A below-staff spanner hangs off the staff's own bottom line",
            arguments: [(lineCount: 5, dy: 7.0), (3, 5.0), (1, 3.0)],
        )
        func belowStaffBandFollowsTheDrawnBottomLine(
            lineCount: Int, dy expected: Double,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.20">
              <Score>
                <Division>480</Division>
                <Part>
                  <Staff id="1"><StaffType group="pitched">
                    <lines>\(lineCount)</lines>
                  </StaffType></Staff>
                  <trackName>P</trackName>
                  <Instrument id="piano">
                    <instrumentId>keyboard.piano</instrumentId>
                  </Instrument>
                </Part>
                <Staff id="1">
                  <Measure>
                    <voice>
                      <Spanner type="HairPin"><HairPin><subtype>0</subtype></HairPin>
                      <next><location><measures>1</measures></location></next>
                      </Spanner>
                      <Rest><durationType>whole</durationType></Rest>
                    </voice>
                  </Measure>
                  <Measure><voice>
                    <Rest><durationType>whole</durationType></Rest>
                  </voice></Measure>
                </Staff>
              </Score>
            </museScore>
            """
            let doc = try LayoutEngine.layout(
                score: MSCXParser.parse(Data(mscx.utf8)),
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let system = try #require(doc.systems.first)
            let origin = try #require(system.staffOrigins.first).y
            let y = try #require(system.spanners.compactMap {
                if case let .spannerSegment(_, from, _, _, _, _) = $0 {
                    return from.y
                }
                return nil
            }.first)
            #expect(abs((y - origin) / system.sp - CGFloat(expected)) < 0.001)
        }
    }
#endif
