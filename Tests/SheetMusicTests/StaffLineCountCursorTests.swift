#if os(macOS)
    import CoreGraphics
    import QuartzCore
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// Everything that answers "how far down does this staff go" for a
    /// reader rather than for the engraver: the playback cursor, the loop
    /// highlight band, tap-to-staff snapping, and the vertical stroke at
    /// a system's left edge.
    ///
    /// All four used to derive that from `StaffMetrics.staffHeight`,
    /// which is the FIVE-LINE reference height `step` is expressed in —
    /// not any staff's drawn extent. Over a one-line percussion staff
    /// each of them overshot by 4 sp.
    @Suite("Staff line count — cursor, highlight, hit test, system bar")
    struct StaffLineCountCursorTests {
        private let _installApple = TestSupport.installApple

        /// One staff of `lineCount` lines, one measure, one F5 quarter.
        /// F5 is the treble staff's top line (`step` 4), which is fixed
        /// for every line count, so no ledger line appears at any count.
        static func score(lineCount: Int) -> Score {
            let measure = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(
                    duration: .quarter,
                    notes: [Note(pitch: 77, tpc: 13)],
                )),
            ])])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "perc"),
                    staves: [Staff(lineCount: lineCount, measures: [measure])],
                )],
            )
        }

        @available(macOS 15.0, *)
        private static func document(lineCount: Int) -> LayoutDocument {
            LayoutEngine.layout(
                score: score(lineCount: lineCount),
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
        }

        // MARK: - Playback cursor

        /// The cursor rect spans the staves it covers, so on a single
        /// staff its height IS that staff's drawn height: 4 sp at five
        /// lines, 2 sp at three, and zero at one — where the top and
        /// bottom line are the same line.
        ///
        /// Asserted at all three counts rather than as a 5-vs-1 delta:
        /// a renderer that halved the height, or one that subtracted a
        /// fixed 4 sp, reproduces the delta but not the middle case.
        @Test(
            "The playback cursor is as tall as the staff's drawn height",
            arguments: [(lineCount: 5, spans: 4.0), (3, 2.0), (1, 0.0)],
        )
        func cursorHeightFollowsLineCount(
            lineCount: Int, spans: Double,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = Self.document(lineCount: lineCount)
            let sp = try #require(doc.systems.first).sp
            let rect = try #require(doc.cursorFrame(
                for: .beat(measureIndex: 0, tickInMeasure: 0),
                in: Self.score(lineCount: lineCount),
            ))
            #expect(abs(rect.height - CGFloat(spans) * sp) < 0.001)
        }

        /// `.item` and `.beat` cursors are two separate rect builders in
        /// `CursorFrame`, each with its own copy of the bottom-edge
        /// expression, so a fix applied to one leaves the other on the
        /// reference height with no compile error.
        @Test("The item cursor is sized the same way as the beat cursor")
        func itemCursorHeightMatchesTheBeatCursor() throws {
            guard #available(macOS 15.0, *) else { return }
            for lineCount in [5, 3, 1] {
                let score = Self.score(lineCount: lineCount)
                let doc = Self.document(lineCount: lineCount)
                let system = try #require(doc.systems.first)
                let noteID = try #require(
                    system.eventColumns.compactMap { column -> NoteID? in
                        if case let .note(id) = column.id { return id }
                        return nil
                    }.first,
                )
                let byItem = try #require(doc.cursorFrame(
                    for: .item(.note(noteID)), in: score,
                ))
                let byBeat = try #require(doc.cursorFrame(
                    for: .beat(measureIndex: 0, tickInMeasure: 0), in: score,
                ))
                #expect(abs(byItem.height - byBeat.height) < 0.001)
                let expected = system.geometry(atFlatIndex: 0)
                    .height(sp: system.sp)
                #expect(abs(byItem.height - expected) < 0.001)
            }
        }

        // MARK: - Loop highlight

        @Test(
            "The loop highlight band is as tall as the drawn staff",
            arguments: [(lineCount: 5, spans: 4.0), (3, 2.0), (1, 0.0)],
        )
        func loopHighlightHeightFollowsLineCount(
            lineCount: Int, spans: Double,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = Self.document(lineCount: lineCount)
            let sp = try #require(doc.systems.first).sp
            let rect = try #require(doc.loopHighlightRects(
                fromMeasureIndex: 0, toMeasureExclusive: 1,
            ).first)
            #expect(abs(rect.height - CGFloat(spans) * sp) < 0.001)
        }

        // MARK: - Tap → staff

        /// Two staves, the upper one drawing a single line. `chooseStaffIndex`
        /// picks the staff whose CENTERLINE is nearest the tap, and the
        /// one-line staff's centerline is its own single line — not the
        /// point 2 sp below it where a five-line staff's would be.
        ///
        /// The probe Y is placed inside the 1 sp window where the two
        /// rules disagree: below the true midpoint between the staves'
        /// real centers (so the tap belongs to the LOWER staff) but above
        /// the midpoint the fixed-2 sp rule computes (so that rule hands
        /// it to the upper one). Deriving both midpoints from the laid-out
        /// origins keeps the fixture independent of the padding the
        /// engine chose.
        @Test("A tap snaps to the staff by its own centerline")
        func tapSnapsByTheStaffsOwnCenterline() throws {
            guard #available(macOS 15.0, *) else { return }
            let measure = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .chord(Chord(
                    duration: .whole, notes: [Note(pitch: 60, tpc: 14)],
                )),
            ])])
            let score = Score(division: 480, parts: [Part(
                id: "P1",
                instrument: Instrument(id: "perc"),
                staves: [
                    Staff(lineCount: 1, measures: [measure]),
                    Staff(lineCount: 5, measures: [measure]),
                ],
            )])
            let doc = LayoutEngine.layout(
                score: score,
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let system = try #require(doc.systems.first)
            let sp = system.sp
            let upper = system.origin.y + system.staffOrigins[0].y
            let lower = system.origin.y + system.staffOrigins[1].y
            // Upper staff's real center is its single line; the lower
            // one's is 2 sp down. The retired rule put BOTH at + 2 sp.
            let trueMid = (upper + (lower + 2 * sp)) / 2
            let legacyMid = ((upper + 2 * sp) + (lower + 2 * sp)) / 2
            #expect(trueMid < legacyMid)
            let probe = CGPoint(
                x: system.origin.x + system.staffOrigins[0].x + sp * 12,
                y: (trueMid + legacyMid) / 2,
            )
            let cursor = try #require(nearestCursor(at: probe, in: doc))
            guard case let .item(.note(noteID)) = cursor else {
                Issue.record("expected a note cursor, got \(cursor)")
                return
            }
            #expect(noteID.staff.staffIndexInPart == 1)
        }

        // MARK: - System-start bar line

        /// MuseScore builds the system's left-edge vertical out of
        /// ordinary per-staff `BarLine`s, so its two ends obey the same
        /// rule `LayoutElement.barLine` does: top staff's top line to
        /// bottom staff's bottom line, replaced by ±2 sp about the single
        /// line on a one-line staff. Both edges are asserted — a
        /// height-only check passes on a stroke that is the right length
        /// but hangs entirely below a one-line staff, which is exactly
        /// what deriving the bottom from `staffHeight` produced.
        @Test(
            "The system's left-edge vertical spans the end staves",
            arguments: [
                (lineCount: 5, top: 0.0, bottom: 4.0),
                (3, 0.0, 2.0),
                (1, -2.0, 2.0),
            ],
        )
        func systemStartBarLineSpansTheEndStaves(
            lineCount: Int, top: Double, bottom: Double,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let system = try #require(
                Self.document(lineCount: lineCount).systems.first,
            )
            let origin = try #require(system.staffOrigins.first).y
            let span = try #require(system.systemStartBarLine)
            #expect(abs((span.top - origin) - CGFloat(top) * system.sp) < 0.001)
            #expect(
                abs((span.bottom - origin) - CGFloat(bottom) * system.sp)
                    < 0.001,
            )
        }

        /// The CALayer renderer takes the span as geometry it computes
        /// itself, so nothing in the layout assertion above reaches it.
        @Test("The CALayer system bar strokes the geometry's span")
        func layerSystemBarFollowsTheSpan() throws {
            guard #available(macOS 15.0, *) else { return }
            for (lineCount, expected) in [(5, 4.0), (3, 2.0), (1, 4.0)] {
                let system = try #require(
                    Self.document(lineCount: lineCount).systems.first,
                )
                let parent = CALayer()
                ScoreLayerBuilder.drawSystemBar(
                    system: system,
                    metrics: StaffMetrics(staffSize: system.sp * 4),
                    height: 0,
                    into: parent,
                )
                let shape = try #require(
                    parent.sublayers?.compactMap { $0 as? CAShapeLayer }.first,
                )
                let box = try #require(shape.path?.boundingBox)
                #expect(
                    abs(box.height - CGFloat(expected) * system.sp) < 0.001,
                    "line count \(lineCount) stroked \(box.height / system.sp) sp",
                )
            }
        }

        private struct BridgeSegment {
            let x0, y0, x1, y1: Double
            var isVertical: Bool {
                abs(x1 - x0) < 0.0001
            }

            var isHorizontal: Bool {
                abs(y1 - y0) < 0.0001
            }
        }

        /// Every stroked segment in `lineCount`'s Android bridge render.
        private func bridgeSegments(
            lineCount: Int,
        ) throws -> [BridgeSegment] {
            let pages = try DrawProgramCodec.decode(LayoutBridge.compute(
                score: Self.score(lineCount: lineCount),
                pageWidthMM: 210, pageHeightMM: 297,
            ))
            var out: [BridgeSegment] = []
            var from: (x: Double, y: Double)?
            var to: (x: Double, y: Double)?
            for page in pages {
                for cmd in page.commands {
                    switch cmd {
                    case let .moveTo(x, y): from = (x, y); to = nil
                    case let .lineTo(x, y): to = (x, y)
                    case .stroke:
                        if let a = from, let b = to {
                            out.append(BridgeSegment(
                                x0: a.x, y0: a.y, x1: b.x, y1: b.y,
                            ))
                        }
                        from = nil
                        to = nil
                    default: continue
                    }
                }
            }
            return out
        }

        /// The third renderer. The bridge is the one whose output is
        /// inspectable as data, so it stands in for the SwiftUI Canvas
        /// twin the way `bridgeStrokesEachDrawnStaffLine` does.
        ///
        /// The system's vertical is the LEFTMOST vertical segment: the
        /// note stem and the terminal barline are both further right.
        /// Both edges are measured down from the staff's TOP line — the
        /// topmost horizontal segment — so the one-line case pins the
        /// centering, not just the length.
        @Test(
            "The bridge strokes the system bar over the end staves",
            arguments: [
                (lineCount: 5, top: 0.0, bottom: 4.0),
                (3, 0.0, 2.0),
                (1, -2.0, 2.0),
            ],
        )
        func bridgeSystemBarFollowsLineCount(
            lineCount: Int, top: Double, bottom: Double,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            // Calibrate sp in mm from the five-line render, whose staff
            // lines span exactly four spaces.
            let fiveHorizontals = try bridgeSegments(lineCount: 5)
                .filter(\.isHorizontal).map(\.y0)
            let lowest = try #require(fiveHorizontals.max())
            let highest = try #require(fiveHorizontals.min())
            let spMM = (lowest - highest) / 4
            #expect(spMM > 0)

            let segments = try bridgeSegments(lineCount: lineCount)
            let topLineY = try #require(
                segments.filter(\.isHorizontal).map(\.y0).min(),
            )
            let bar = try #require(
                segments.filter(\.isVertical).min { $0.x0 < $1.x0 },
            )
            #expect(abs(min(bar.y0, bar.y1) - topLineY - top * spMM) < 0.01)
            #expect(
                abs(max(bar.y0, bar.y1) - topLineY - bottom * spMM) < 0.01,
            )
        }

        /// The SwiftUI Canvas twin, which backs PDF export and
        /// `PagedScoreView` and is reached by no other assertion here.
        /// The system's vertical sits at the staff lines' own left edge,
        /// so the LEFTMOST inked column carries it (the fixture's
        /// instrument has no name, so no part label competes for that
        /// column); the vertical run in that column is the stroke.
        ///
        /// Three lines is the discriminating count: the correct span is
        /// 2 sp where the retired `metrics.staffHeight` draws 4 sp. On
        /// ONE line the correct span is 4 sp as well, so that count pins
        /// the centering instead — asserted separately below.
        @MainActor
        @Test("The Canvas system bar is half as tall on a 3-line staff")
        func canvasSystemBarHeightFollowsLineCount() throws {
            guard #available(macOS 15.0, *) else { return }
            let five = try Self.canvasSystemBarRun(lineCount: 5)
            let three = try Self.canvasSystemBarRun(lineCount: 3)
            #expect(five.height > 20, "five-line bar measured \(five.height) px")
            #expect(
                abs(three.height * 2 - five.height) <= 3,
                """
                a three-line staff's system bar should be half the \
                five-line one, but measured \(three.height) px against \
                \(five.height) px.
                """,
            )
        }

        @MainActor
        @Test("The Canvas system bar straddles a one-line staff's line")
        func canvasSystemBarIsCenteredOnTheSingleLine() throws {
            guard #available(macOS 15.0, *) else { return }
            let run = try Self.canvasSystemBarRun(lineCount: 1)
            #expect(
                min(run.above, run.below) > 10,
                """
                the system bar should straddle the single staff line, \
                but one side is \(run.above) px and the other \(run.below).
                """,
            )
            #expect(
                abs(run.above - run.below) <= 5,
                """
                the system bar is not centered on the single staff line: \
                \(run.above) px against \(run.below) px.
                """,
            )
        }

        /// Vertical extent of the leftmost inked column, split about the
        /// busiest row (the staff line that runs the system's width).
        @MainActor
        @available(macOS 15.0, *)
        private static func canvasSystemBarRun(
            lineCount: Int,
        ) throws -> (height: Int, above: Int, below: Int) {
            let raster = try CanvasInkProbe.raster(of: score(lineCount: lineCount))
            let staffLineY = try #require(raster.busiestRow)
            // The staff lines begin at exactly the system bar's X, so
            // the leftmost ink ON the staff-line row is that column —
            // measure numbers and other left-margin glyphs sit on other
            // rows and cannot claim it.
            let edge = try #require(
                (0 ..< raster.width).first { x in
                    raster.darkYs(atX: x).contains(staffLineY)
                },
            )
            // One column in from the extreme edge, so an antialiased
            // half-covered pixel cannot shorten the measured run. Only
            // the run CONNECTED to the staff line is the bar: a clef's
            // ink can reach into the same column further down without
            // being part of the stroke.
            let ys = Set(raster.darkYs(atX: edge + 1))
            var near = staffLineY
            while ys.contains(near - 1) {
                near -= 1
            }
            var far = staffLineY
            while ys.contains(far + 1) {
                far += 1
            }
            return (far - near, staffLineY - near, far - staffLineY)
        }
    }
#endif
