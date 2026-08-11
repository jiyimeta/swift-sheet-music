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
    }
#endif
