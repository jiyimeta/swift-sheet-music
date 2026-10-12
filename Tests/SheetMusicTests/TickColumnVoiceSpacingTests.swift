#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// How `LayoutEngine.tickColumns` spaces the columns of one staff whose voices move at different rates: a
    /// long note in one voice must not stretch or squeeze the other's, and a rest a voice holds for the whole bar
    /// still centers in it. Split from `MultiStaffAlignmentTests`, which keeps the cross-staff cases.
    @Suite("Tick columns across voices")
    struct TickColumnVoiceSpacingTests {
        private let _installApple = TestSupport.installApple

        @Test("Voice-1 whole rest centers in the measure, even alongside voice-0 melody")
        func multiVoiceWholeRestCentersInMeasure() throws {
            guard #available(macOS 15.0, *) else { return }
            let c4 = Note(pitch: 60, tpc: 14)
            let m = Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(Chord(duration: .quarter, notes: [c4])),
                    .chord(Chord(duration: .quarter, notes: [c4])),
                    .chord(Chord(duration: .quarter, notes: [c4])),
                    .chord(Chord(duration: .quarter, notes: [c4])),
                ]),
                Voice(elements: [
                    // `.measure` (not `.whole`) is the
                    // MuseScore-canonical spelling for a
                    // measure-filling rest in voice 1 alongside
                    // voice 0's melody. With `NoteDuration.measure`
                    // present in the model, the layout engine
                    // centers only `.measure`; typed `.whole`
                    // rests sit on their start beat. This
                    // fixture's intent is the centering case, so
                    // it should use `.measure`.
                    .rest(duration: .measure),
                ]),
            ])
            let staff = Staff(measures: [m])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "P1", trackName: nil,
                    instrument: Instrument(
                        id: "pno", longName: "Treble", shortName: "Tr.",
                    ),
                    staves: [staff],
                )],
            )
            let doc = LayoutEngine.layout(
                score: score,
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let measure = try #require(doc.systems.first?.measures.first)

            var v0Xs: [CGFloat] = []
            var measureRestX: CGFloat?
            for el in measure.elements {
                switch el {
                case let .chord(_, _, _, so, _, _, _, _, _, _, _):
                    v0Xs.append(so.x)
                case let .rest(dur, origin, _, _, _):
                    if case .measure = dur {
                        measureRestX = origin.x
                    }
                default:
                    break
                }
            }

            try #require(v0Xs.count == 4)
            let wr = try #require(
                measureRestX,
                "measure rest not found in emission list",
            )

            // The measure rest must NOT share x with voice 0's first chord
            // — it's centered in the measure body (MuseScore behavior),
            // distinct from tick 0 even when other voices carry content.
            // 3 pt is enough headroom to be unambiguous after we tightened
            // measure padding to match MuseScore's `Sid::measureSpacing`
            // defaults; the meaningful invariant is the upper-bound check
            // below.
            #expect(
                abs(wr - v0Xs[0]) > 3,
                "measure rest x=\(wr) should NOT match v0 tick-0 x=\(v0Xs[0])",
            )
            // And it should land somewhere inside the measure's chord
            // span — i.e. between the first and last v0 chord. The
            // exact x depends on `Sid::measureSpacing` and the
            // proportional chord-to-chord weights; we don't pin it
            // precisely so future spacing tuning doesn't churn this
            // test.
            #expect(wr > v0Xs[0] && wr < v0Xs[3])
        }

        @Test("Whole-note voice + quarter voice ⇒ quarters stay uniformly spaced")
        func wholeAgainstQuartersUniform() throws {
            guard #available(macOS 15.0, *) else { return }
            let c4 = Note(pitch: 60, tpc: 14)
            // Voice 0: whole note.  Voice 1: 4 quarter notes.
            // The whole's big duration-width used to dominate tick 0 and
            // push voice-1 quarters to uneven fractions.  Pro-rated gap
            // aggregation spreads the whole across all four gaps, so the
            // quarters end up uniformly spaced.
            let m = Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(Chord(duration: .whole, notes: [c4])),
                ]),
                Voice(elements: [
                    .chord(Chord(duration: .quarter, notes: [c4])),
                    .chord(Chord(duration: .quarter, notes: [c4])),
                    .chord(Chord(duration: .quarter, notes: [c4])),
                    .chord(Chord(duration: .quarter, notes: [c4])),
                ]),
            ])
            let staff = Staff(measures: [m])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "P", trackName: nil,
                    instrument: Instrument(
                        id: "x", longName: "T", shortName: "T",
                    ),
                    staves: [staff],
                )],
            )
            let doc = LayoutEngine.layout(
                score: score,
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let measure = try #require(doc.systems.first?.measures.first)

            // Voice 0 (whole) then voice 1 (4 quarters), in emission order.
            var xs: [CGFloat] = []
            for el in measure.elements {
                if case let .chord(_, _, _, so, _, _, _, _, _, _, _) = el {
                    xs.append(so.x)
                }
            }
            try #require(xs.count == 5)
            let whole = xs[0]
            let quarters = Array(xs.dropFirst())

            // Whole sits at tick 0 with quarter #1.
            #expect(abs(whole - quarters[0]) < 0.01)

            // Quarter-to-quarter gaps must all be ~equal.
            let g1 = quarters[1] - quarters[0]
            let g2 = quarters[2] - quarters[1]
            let g3 = quarters[3] - quarters[2]
            #expect(
                abs(g1 - g2) < 0.5,
                "gap 0-1 = \(g1), gap 1-2 = \(g2)",
            )
            #expect(
                abs(g2 - g3) < 0.5,
                "gap 1-2 = \(g2), gap 2-3 = \(g3)",
            )
        }

        @Test("tickColumns fraction matches the higher-pressure voice at each tick")
        func tickColumnsMaxFractionRule() {
            guard #available(macOS 15.0, *) else { return }

            // Single staff, single voice, four 8ths — a simpler shape
            // that anchors the numeric behavior of tickColumns.
            let c4 = Note(pitch: 60, tpc: 14)
            let voice = Voice(elements: [
                .chord(Chord(duration: .eighth, notes: [c4])),
                .chord(Chord(duration: .eighth, notes: [c4])),
                .chord(Chord(duration: .eighth, notes: [c4])),
                .chord(Chord(duration: .eighth, notes: [c4])),
            ])
            let staff = Staff(measures: [
                Measure(voices: [voice]),
            ])
            let metrics = StaffMetrics(staffSize: 28)
            let schedule = LayoutEngine.HeaderSchedule(
                clefX: 0, keySigX: 0, timeSigX: 0, startRepeatX: nil,
                contentStartX: 40,
            )
            let cols = LayoutEngine.tickColumns(
                staves: [staff],
                measureIdx: 0,
                metrics: metrics,
                headerSchedule: schedule,
                width: 400,
                division: 480,
                measureDuration: Fraction(numerator: 4, denominator: 4),
            )

            // Each 8th is 240 ticks at division 480, so ticks are
            // 0, 240, 480, 720. All four should be present.
            #expect(cols[0] != nil)
            #expect(cols[240] != nil)
            #expect(cols[480] != nil)
            #expect(cols[720] != nil)

            // Four uniform weights ⇒ fractions 0, 0.25, 0.5, 0.75 —
            // the inter-tick gap must be constant.
            let xs = [0, 240, 480, 720].compactMap { cols[$0] }
            let gap1 = xs[1] - xs[0]
            let gap2 = xs[2] - xs[1]
            let gap3 = xs[3] - xs[2]
            #expect(abs(gap1 - gap2) < 0.01)
            #expect(abs(gap2 - gap3) < 0.01)
        }
    }
#endif
