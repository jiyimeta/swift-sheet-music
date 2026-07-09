#if !os(Android)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// Regression coverage for `LayoutDocument.cursorFrame` on an
    /// `.item(.rest(...))` cursor that lands on a *measure-fill* rest
    /// (`NoteDuration.measure`). Such a rest renders centered in the bar
    /// (`LayoutEngine+Placement`'s `isMeasureRest` branch), so drawing the
    /// playback cursor on its glyph column parks the cursor at the measure
    /// midpoint — even though the rest's onset (and the tick the engine
    /// seeks to) is beat 1. The audio-driven cursor already skips measure
    /// rests in `PlaybackTimeline` / `beatXInMeasure`; this covers the
    /// remaining gap on the `.item` frame path (a tap on the rest glyph).
    @Suite("cursorFrame measure-rest item resolves to beat 1, not center")
    struct PlaybackCursorMeasureRestFrameTests {
        private let _installApple = TestSupport.installApple

        /// One part, two staves. Staff 0 carries four quarter notes;
        /// staff 1 is a single measure-fill rest (an empty bar). The
        /// measure rest renders centered on staff 1, well to the right of
        /// staff 0's beat-1 note.
        private static func twoStaffScore(division: Int = 480) -> Score {
            let melody = Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)])),
            ])
            let emptyBar = Voice(elements: [.rest(duration: .measure)])
            let staff0 = Staff(measures: [Measure(voices: [melody])])
            let staff1 = Staff(measures: [Measure(voices: [emptyBar])])
            return Score(
                division: division,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [staff0, staff1],
                )],
            )
        }

        @available(macOS 15.0, iOS 16.0, *)
        private static func laidOut(_ s: Score) -> LayoutDocument {
            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false,
            )
            let natW = LayoutEngine.naturalContentWidth(score: s, options: opts)
            return LayoutEngine.layout(score: s, options: opts, availableWidth: natW)
        }

        @Test("tapping a measure-fill rest parks the cursor on beat one column")
        func measureRestCursorSitsOnBeatOne() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.twoStaffScore()
            let doc = Self.laidOut(score)

            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)

            // The measure-fill rest's ID + its (centered) layout column.
            var measureRestID: RestID?
            var centeredRestX: CGFloat?
            // Beat-1 note column on staff 0 = the leftmost chord note X.
            var beatOneNoteX: CGFloat?
            for el in measure.elements {
                switch el {
                case let .rest(duration, origin, _, restID, _):
                    if duration == .measure {
                        measureRestID = restID
                        centeredRestX = origin.x
                    }
                case let .chord(notes, _, _, _, _, _, _, _, _, _, _):
                    if let first = notes.first {
                        beatOneNoteX = min(
                            beatOneNoteX ?? .greatestFiniteMagnitude,
                            first.origin.x,
                        )
                    }
                default:
                    break
                }
            }
            let restID = try #require(measureRestID)
            let centeredX = try #require(centeredRestX)
            let beatOneX = try #require(beatOneNoteX)

            let base = system.origin.x + measure.origin.x
            let frame = try #require(
                doc.cursorFrame(for: .item(.rest(restID)), in: score),
            )
            let halfW = doc.metrics.sp * 0.4
            let cursorCenterX = frame.minX + halfW

            // The cursor must land on beat 1's column (staff 0's first
            // note), NOT on the centered measure-rest glyph.
            #expect(abs(cursorCenterX - (base + beatOneX)) < 0.5)
            #expect(abs(cursorCenterX - (base + centeredX)) > doc.metrics.sp)
        }
    }
#endif
