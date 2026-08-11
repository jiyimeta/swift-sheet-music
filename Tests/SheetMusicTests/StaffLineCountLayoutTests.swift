#if os(macOS)
    import CoreGraphics
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("Staff line count — layout")
    struct StaffLineCountLayoutTests {
        private let _installApple = TestSupport.installApple

        /// `tied` replaces the top staff's single quarter with two tied
        /// halves. That is not decoration: `attachTies` rebuilds every
        /// `LayoutSystem` through a copy initializer, and it early-returns
        /// on an empty pair list, so without a tie in the score that copy
        /// never runs and a `staffGeometries` dropped there would be
        /// invisible. Only the geometry test sets it — the spacing test's
        /// pinned delta is derived from the plain fixture, and extra ink
        /// on staff 0 would move the adaptive south pad it depends on.
        private func twoStaffScore(
            topLineCount: Int, tied: Bool = false,
        ) -> Score {
            let c4 = Note(pitch: 60, tpc: 14)
            let c3 = Note(pitch: 48, tpc: 14)
            let topVoice: [VoiceElement] = tied
                ? [
                    .chord(Chord(
                        duration: .half,
                        notes: [Note(pitch: 60, tpc: 14, tieForward: 1)],
                    )),
                    .chord(Chord(
                        duration: .half,
                        notes: [Note(pitch: 60, tpc: 14, tieBack: 1)],
                    )),
                ]
                : [.chord(Chord(duration: .quarter, notes: [c4]))]
            let top = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            ] + topVoice)])
            let bottom = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "F")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [c3])),
            ])])
            let part = Part(
                id: "P1",
                trackName: "Piano",
                instrument: Instrument(
                    id: "pno", longName: "Piano", shortName: "Pno.",
                ),
                staves: [
                    Staff(lineCount: topLineCount, measures: [top]),
                    Staff(measures: [bottom]),
                ],
            )
            return Score(division: 480, parts: [part])
        }

        @Test("A one-line top staff pulls the staff below it up by 1 sp")
        func aOneLineStaffTakesLessVerticalRoom() throws {
            guard #available(macOS 15.0, *) else { return }

            func gap(topLineCount: Int) throws -> (dy: CGFloat, sp: CGFloat) {
                let doc = LayoutEngine.layout(
                    score: twoStaffScore(topLineCount: topLineCount),
                    options: .init(wrapToViewWidth: false),
                    availableWidth: 900,
                )
                let system = try #require(doc.systems.first)
                #expect(system.staffOrigins.count == 2)
                return (
                    system.staffOrigins[1].y - system.staffOrigins[0].y,
                    system.sp,
                )
            }

            let five = try gap(topLineCount: 5)
            let one = try gap(topLineCount: 1)
            // The delta is exactly 1 sp, and it is NOT the 4 sp of staff
            // height that disappears. Two effects compose:
            //
            //   −4 sp  the `currentY` advance past staff 0 uses its own
            //          drawn height, which is 0 for a single line.
            //   +3 sp  `staffBottomLocals[0]` — the band the adaptive
            //          staff-distance padding is measured against — drops
            //          from `sp*6` to `sp*2` with it, so the C4 notehead
            //          now hangs below the band and inflates `measuredPad`.
            //
            // Pinned rather than bounded on purpose: an upper bound of
            // 4 sp also passes a score-global `staffBottomLocals` (delta
            // exactly 4 sp) and a `height` of `lineCount * sp` (delta
            // 2 sp), both of which are wrong. If a padding-constant change
            // breaks this, re-deriving the number is the right thing to be
            // forced into — the fixture is synthetic and owned by this
            // suite.
            #expect(one.dy < five.dy)
            #expect(abs((five.dy - one.dy) - five.sp) < 0.001)
        }

        /// Guards the copy initializers, not just `buildSystem`. Six
        /// places rebuild a `LayoutSystem` field-by-field, and
        /// `staffGeometries` is defaulted, so any of them can drop it with
        /// no compile error — the staff silently degrades to five-line.
        /// `LayoutEngine.shift` is unavoidable (`packSystems` builds every
        /// system at y = 0 and shifts it into place), `attachTies` is
        /// reached via the tie in the fixture, and `subdocument` — whose
        /// production caller is the Android `LayoutBridge`, not
        /// `LayoutEngine.layout` — is asserted separately below.
        @Test("Geometry reaches the laid-out system")
        func systemCarriesPerStaffGeometry() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = LayoutEngine.layout(
                score: twoStaffScore(topLineCount: 3, tied: true),
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let system = try #require(doc.systems.first)
            #expect(system.geometry(atFlatIndex: 0).lineCount == 3)
            #expect(system.geometry(atFlatIndex: 1).lineCount == 5)

            let sub = doc.subdocument(systems: 0 ..< 1, yOffset: 0)
            let subSystem = try #require(sub.systems.first)
            #expect(subSystem.geometry(atFlatIndex: 0).lineCount == 3)
            #expect(subSystem.geometry(atFlatIndex: 1).lineCount == 5)
        }

        /// One staff, one measure, one quarter note sitting ON the top
        /// staff line (F5 in treble clef, `step` 4). The top line's
        /// position is fixed for every line count, so this note draws no
        /// ledger line at either count — the staff lines are then the
        /// only stroke population that moves with `lineCount`, which is
        /// what makes an absolute stroke count meaningful here.
        private func oneStaffScore(lineCount: Int) -> Score {
            let f5 = Note(pitch: 77, tpc: 13)
            let measure = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [f5])),
            ])])
            let part = Part(
                id: "P1",
                trackName: "Percussion",
                instrument: Instrument(
                    id: "perc", longName: "Percussion", shortName: "Perc.",
                ),
                staves: [Staff(lineCount: lineCount, measures: [measure])],
            )
            return Score(division: 480, parts: [part])
        }

        private func bridgeStrokeCount(lineCount: Int) throws -> Int {
            let encoded = LayoutBridge.compute(
                score: oneStaffScore(lineCount: lineCount),
                pageWidthMM: 210,
                pageHeightMM: 297,
            )
            let pages = try DrawProgramCodec.decode(encoded)
            #expect(!pages.isEmpty)
            var strokes = 0
            for page in pages {
                for cmd in page.commands {
                    if case .stroke = cmd { strokes += 1 }
                }
            }
            return strokes
        }

        /// The Android bridge is the one renderer whose output is
        /// inspectable as data, so it stands in for all three here.
        ///
        /// Five-line baseline: 5 staff lines + 2 barlines (the left
        /// system line and the terminal barline) + 1 stem = 8 strokes.
        /// Nothing but the staff lines changes when `lineCount` drops
        /// to 3, so the three-line render must be exactly 2 fewer.
        /// Both absolutes are asserted, not just the delta: a renderer
        /// that still hardcodes five lines produces 8 in both cases, so
        /// the delta alone would pass on a fixture whose other strokes
        /// happened to differ by 2.
        @Test("The bridge strokes one line per drawn staff line")
        func bridgeStrokesEachDrawnStaffLine() throws {
            guard #available(macOS 15.0, *) else { return }
            #expect(try bridgeStrokeCount(lineCount: 5) == 8)
            #expect(try bridgeStrokeCount(lineCount: 3) == 6)
            #expect(try bridgeStrokeCount(lineCount: 1) == 4)
        }

        // MARK: - Barline span

        /// Every `.barLine` in the laid-out document, expressed as its
        /// stroke's top and bottom edge measured DOWN FROM the staff's
        /// top line (`staffOrigins[0].y`, where `StaffRenderer` starts
        /// drawing). Elements carry system-local Y, so subtracting the
        /// staff origin makes the numbers independent of where the
        /// system landed on the page — which matters, because shrinking
        /// a staff also moves the system.
        private func barLineSpans(
            lineCount: Int,
        ) throws -> (spans: [(top: CGFloat, bottom: CGFloat)], sp: CGFloat) {
            guard #available(macOS 15.0, *) else { return ([], 0) }
            let doc = LayoutEngine.layout(
                score: oneStaffScore(lineCount: lineCount),
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let system = try #require(doc.systems.first)
            let topLineY = try #require(system.staffOrigins.first).y
            var spans: [(top: CGFloat, bottom: CGFloat)] = []
            for measure in system.measures {
                for element in measure.elements {
                    guard case let .barLine(_, origin, halfHeight) = element
                    else { continue }
                    spans.append((
                        origin.y - halfHeight - topLineY,
                        origin.y + halfHeight - topLineY,
                    ))
                }
            }
            return (spans, system.sp)
        }

        /// The rule, from `dom/barline.cpp:253-266`: a barline spans its
        /// staff, top line to bottom line — except on a ONE-line staff,
        /// where MuseScore uses `BARLINE_SPAN_1LINESTAFF_FROM/TO`
        /// (±4 half-spaces = ±2 sp) about the single line rather than
        /// collapsing to that staff's zero height.
        ///
        /// Both edges are asserted, not just the height: before this
        /// change a one-line staff's barline was 4 sp tall too — it just
        /// hung entirely BELOW the line, from +0 to +4 sp, because the
        /// origin sat at the five-line reference center. A
        /// height-only assertion passes on that bug unchanged.
        @Test("A barline spans its own staff, with the one-line case")
        func barLinesSpanTheirOwnStaff() throws {
            guard #available(macOS 15.0, *) else { return }

            let five = try barLineSpans(lineCount: 5)
            #expect(!five.spans.isEmpty)
            for span in five.spans {
                #expect(abs(span.top) < 0.001)
                #expect(abs(span.bottom - five.sp * 4) < 0.001)
            }

            // Three lines: top line to bottom line, 2 sp tall.
            let three = try barLineSpans(lineCount: 3)
            #expect(three.spans.count == five.spans.count)
            for span in three.spans {
                #expect(abs(span.top) < 0.001)
                #expect(abs(span.bottom - three.sp * 2) < 0.001)
            }

            // One line: ±2 sp ABOUT the single line, which is at 0.
            let one = try barLineSpans(lineCount: 1)
            #expect(one.spans.count == five.spans.count)
            for span in one.spans {
                #expect(abs(span.top + one.sp * 2) < 0.001)
                #expect(abs(span.bottom - one.sp * 2) < 0.001)
            }
        }

        /// One line segment the Android bridge stroked, in mm.
        private struct BridgeSegment {
            let x0, y0, x1, y1: Double
            var isVertical: Bool {
                abs(x1 - x0) < 0.0001
            }

            var isHorizontal: Bool {
                abs(y1 - y0) < 0.0001
            }
        }

        /// Every stroked segment in `lineCount`'s bridge render.
        ///
        /// The engine owning the span is only half the fix — each
        /// renderer computes its own stroke from `origin` and had the
        /// ±2 sp written down separately, and none of them is reached by
        /// the layout assertion above. The bridge is the one renderer
        /// whose output is inspectable as data, so it stands in for the
        /// three the way `bridgeStrokesEachDrawnStaffLine` does.
        private func bridgeSegments(
            lineCount: Int,
        ) throws -> [BridgeSegment] {
            let encoded = LayoutBridge.compute(
                score: oneStaffScore(lineCount: lineCount),
                pageWidthMM: 210,
                pageHeightMM: 297,
            )
            let pages = try DrawProgramCodec.decode(encoded)
            var segments: [BridgeSegment] = []
            var from: (x: Double, y: Double)?
            var to: (x: Double, y: Double)?
            for page in pages {
                for cmd in page.commands {
                    switch cmd {
                    case let .moveTo(x, y):
                        from = (x, y)
                        to = nil
                    case let .lineTo(x, y):
                        to = (x, y)
                    case .stroke:
                        if let a = from, let b = to {
                            segments.append(BridgeSegment(
                                x0: a.x, y0: a.y, x1: b.x, y1: b.y,
                            ))
                        }
                        from = nil
                        to = nil
                    default:
                        continue
                    }
                }
            }
            return segments
        }

        /// The terminal barline's top and bottom edge measured down from
        /// the staff's TOP line, plus one sp — all in mm, all read back
        /// out of the bridge's own draw program.
        ///
        /// The staff lines are the horizontal segments, so their minimum
        /// Y is the top line and (on the five-line render) their spread
        /// over four spaces gives sp. The terminal barline is the
        /// RIGHTMOST vertical segment: the other two verticals in this
        /// fixture are the system's left-edge line and the note stem,
        /// both further left.
        private func bridgeBarLineSpan(
            lineCount: Int,
        ) throws -> (top: Double, bottom: Double) {
            let segments = try bridgeSegments(lineCount: lineCount)
            let horizontals = segments.filter(\.isHorizontal)
            #expect(horizontals.count == lineCount)
            let topLineY = try #require(horizontals.map(\.y0).min())
            let bar = try #require(
                segments.filter(\.isVertical).max { $0.x0 < $1.x0 },
            )
            return (
                min(bar.y0, bar.y1) - topLineY,
                max(bar.y0, bar.y1) - topLineY,
            )
        }

        @Test("The bridge strokes each barline over its own staff")
        func bridgeBarLineSpanFollowsLineCount() throws {
            guard #available(macOS 15.0, *) else { return }
            // Derive sp in mm from the five-line render itself: its five
            // staff lines span exactly four spaces.
            let fiveHorizontals = try bridgeSegments(lineCount: 5)
                .filter(\.isHorizontal).map(\.y0)
            let lowest = try #require(fiveHorizontals.max())
            let highest = try #require(fiveHorizontals.min())
            let spMM = (lowest - highest) / 4
            #expect(spMM > 0)

            let five = try bridgeBarLineSpan(lineCount: 5)
            #expect(abs(five.top) < 0.01)
            #expect(abs(five.bottom - spMM * 4) < 0.01)

            let three = try bridgeBarLineSpan(lineCount: 3)
            #expect(abs(three.top) < 0.01)
            #expect(abs(three.bottom - spMM * 2) < 0.01)

            // The one-line special case: still 4 sp tall, but centered
            // ON the line rather than hanging below it.
            let one = try bridgeBarLineSpan(lineCount: 1)
            #expect(abs(one.top + spMM * 2) < 0.01)
            #expect(abs(one.bottom - spMM * 2) < 0.01)
        }

        // MARK: - Ledger lines

        /// One-staff, one-note score. `pitch`/`tpc` select the note so the
        /// caller can pin a specific staff `step` (the mapping is clef-only,
        /// independent of `lineCount` — `StaffLineGeometry.topStep` is
        /// fixed at 4 for every line count; only where the *other* lines
        /// fall moves).
        private func ledgerScore(
            lineCount: Int, pitch: Int, tpc: Int,
        ) -> Score {
            let note = Note(pitch: pitch, tpc: tpc)
            let measure = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [note])),
            ])])
            let part = Part(
                id: "P1",
                trackName: "Percussion",
                instrument: Instrument(
                    id: "perc", longName: "Percussion", shortName: "Perc.",
                ),
                staves: [Staff(lineCount: lineCount, measures: [measure])],
            )
            return Score(division: 480, parts: [part])
        }

        /// Count of `.ledgerLine` elements among the VISIBLE elements of a
        /// `ledgerScore` layout — the call site reached when the chord (and
        /// its note) is ordinarily visible.
        private func ledgerLineCount(
            lineCount: Int, pitch: Int, tpc: Int,
        ) throws -> Int {
            guard #available(macOS 15.0, *) else { return -1 }
            let doc = LayoutEngine.layout(
                score: ledgerScore(lineCount: lineCount, pitch: pitch, tpc: tpc),
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let system = try #require(doc.systems.first)
            var count = 0
            for measure in system.measures {
                for element in measure.elements {
                    if case .ledgerLine = element { count += 1 }
                }
            }
            return count
        }

        /// On a 5-line staff (bottomStep −4, `firstLedgerStepBelow` −6)
        /// G4 (step −2) sits inside the staff (between the middle and
        /// bottom lines): 0 ledger lines.
        /// On a 3-line staff (bottomStep 0, `firstLedgerStepBelow` −2)
        /// the same G4 step −2 IS the first ledger position below the
        /// staff: exactly 1 ledger line. This is the case Task 13's brief
        /// got wrong — shrinking the staff raises its bottom line, so the
        /// same note gains a ledger line rather than losing one.
        /// On a 1-line staff (bottomStep 4, `firstLedgerStepBelow` +2) —
        /// the ONLY non-five line count that actually occurs in the
        /// rendered corpus, and the only one where `firstLedgerStepBelow`
        /// goes positive — D5 (step +2) IS that first ledger position:
        /// exactly 1 ledger line. The corpus itself cannot exercise this:
        /// every non-five-line staff in the library is a 1-line drumset
        /// track whose notes are pinned to steps {4, 5} by the drum
        /// definition's own `<line>`, never off it, so this parameterized
        /// case is the only evidence this task has for the shipping line
        /// count.
        @Test(
            "Ledger bounds follow the staff's own line count",
            arguments: [
                (lineCount: 5, pitch: 67, tpc: 15, expected: 0), // G4
                (lineCount: 3, pitch: 67, tpc: 15, expected: 1), // G4
                (lineCount: 1, pitch: 74, tpc: 16, expected: 1), // D5
            ],
        )
        func ledgerBoundsFollowLineCount(
            lineCount: Int, pitch: Int, tpc: Int, expected: Int,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            #expect(
                try ledgerLineCount(lineCount: lineCount, pitch: pitch, tpc: tpc)
                    == expected,
            )
        }

        /// Same G4/3-line boundary case, but routed through the
        /// hidden-notehead-inside-a-visible-chord call site (the third of
        /// the four `LedgerLinePass.insert` calls in
        /// `LayoutEngine+SystemBuild.swift`): the chord stays visible but
        /// its one note is marked `visible: false`, and layout runs with
        /// `showsInvisibleElements: true`. That call site is the only one
        /// of the four the OTHER three tests in this file never reach —
        /// the default fixture is a plain visible chord under
        /// `showsInvisibleElements: false`, so a literal `-6` left behind
        /// on any of the three invisible/hidden batches would still ship
        /// green without this case.
        @Test("Ledger bounds follow line count for a hidden notehead too")
        func ledgerBoundsFollowLineCountForHiddenNotehead() throws {
            guard #available(macOS 15.0, *) else { return }

            func hiddenLedgerCount(lineCount: Int) throws -> Int {
                let hidden = Note(pitch: 67, tpc: 15, visible: false)
                let measure = Measure(voices: [Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(Chord(duration: .quarter, notes: [hidden])),
                ])])
                let part = Part(
                    id: "P1",
                    trackName: "Percussion",
                    instrument: Instrument(
                        id: "perc", longName: "Percussion", shortName: "Perc.",
                    ),
                    staves: [Staff(lineCount: lineCount, measures: [measure])],
                )
                let score = Score(division: 480, parts: [part])
                let doc = LayoutEngine.layout(
                    score: score,
                    options: .init(
                        wrapToViewWidth: false,
                        showsInvisibleElements: true,
                    ),
                    availableWidth: 900,
                )
                let system = try #require(doc.systems.first)
                var count = 0
                for measure in system.measures {
                    for element in measure.invisibleElements {
                        if case .ledgerLine = element { count += 1 }
                    }
                }
                return count
            }

            #expect(try hiddenLedgerCount(lineCount: 5) == 0)
            #expect(try hiddenLedgerCount(lineCount: 3) == 1)
        }
    }
#endif
