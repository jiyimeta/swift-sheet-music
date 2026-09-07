#if os(macOS)
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// The range-selection box's two HORIZONTAL edges, which measure the
    /// time the selection occupies rather than the ink it is drawn with.
    ///
    /// Both used to come straight off notehead origins: the box ended at
    /// the middle of its own last note, and a whole-measure rest — which
    /// placement centers in the bar — started the box halfway through a
    /// measure the selection covers whole. The vertical edges are
    /// asserted separately, in `StaffLineCountCursorTests`.
    @Suite("Range box — horizontal edges")
    struct RangeBoxHorizontalEdgesTests {
        private let _installApple = TestSupport.installApple

        /// Bar 1: four C4 quarters. Bar 2: one whole-measure rest — the
        /// `.measure` duration, which is what makes placement center it,
        /// not a `.whole` rest sitting on beat 1.
        private static func score() -> Score {
            let quarters = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            ])])
            let rested = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "piano"),
                    staves: [Staff(lineCount: 5, measures: [quarters, rested])],
                )],
            )
        }

        @available(macOS 15.0, *)
        private static func document() -> LayoutDocument {
            LayoutEngine.layout(
                score: score(),
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
        }

        /// The box `drawRangeBoxes` draws for `ids`, in system
        /// coordinates. `height: 0` makes the macOS Y-flip a plain
        /// negation, which leaves X — all this suite asserts — untouched.
        @available(macOS 15.0, *)
        private static func box(
            for ids: Set<ScoreItemID>, in doc: LayoutDocument,
        ) throws -> CGRect {
            let system = try #require(doc.systems.first)
            let parent = CALayer()
            ScoreLayerBuilder.drawRangeBoxes(
                system: system,
                selection: SelectionRenderState(
                    selectedIDs: ids, voiceColors: [:],
                    drawRangeBox: true,
                    rangeBoxColor: SelectionRenderState.defaultBoxColor,
                ),
                metrics: doc.metrics,
                height: 0,
                into: parent,
            )
            let shape = try #require(
                parent.sublayers?.compactMap { $0 as? CAShapeLayer }.first,
            )
            return try #require(shape.path?.boundingBox)
        }

        private static func note(elementIndex: Int) -> ScoreItemID {
            .note(NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0,
                elementIndex: elementIndex, noteIndexInChord: 0,
            ))
        }

        /// The rightmost barline drawn in `measure`, in system
        /// coordinates — read out of the layout here rather than borrowed
        /// from the code under test.
        private static func trailingBarLineX(_ measure: LayoutMeasure) -> CGFloat? {
            var localX: CGFloat?
            for case let .barLine(_, origin, _) in measure.elements {
                localX = max(localX ?? origin.x, origin.x)
            }
            return localX.map { measure.origin.x + $0 }
        }

        /// A selection that stops short of the barline runs to just before
        /// the next onset — the beat-2 column, less the same 1.4 sp pad the
        /// left edge has always used.
        @Test("The right edge reaches the next onset")
        func rightEdgeReachesNextOnset() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = Self.document()
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            let xPad = doc.metrics.sp * 1.4

            let box = try Self.box(for: [Self.note(elementIndex: 2)], in: doc)
            let beatTwo = try #require(measure.tickColumns[480])
            #expect(abs(box.maxX - (measure.origin.x + beatTwo - xPad)) < 0.001)

            // And it grew: the old ink-only edge was the notehead's own x
            // plus the pad, which is left of the beat-2 column.
            #expect(box.maxX > box.minX + xPad * 2)
        }

        /// The bar's last note has no onset after it, so the box runs to
        /// the closing barline instead of stopping at that note.
        @Test("The right edge reaches the barline on the bar's last note")
        func rightEdgeReachesBarLine() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = Self.document()
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            let xPad = doc.metrics.sp * 1.4

            let box = try Self.box(for: [Self.note(elementIndex: 5)], in: doc)
            let barLineX = try #require(Self.trailingBarLineX(measure))
            #expect(abs(box.maxX - (barLineX - xPad)) < 0.001)
        }

        /// A whole-measure rest is drawn centered in its bar, but it
        /// occupies the bar from beat 1, so that is where its box starts —
        /// and it ends at the barline, not at the centered glyph.
        @Test("A measure rest's box spans the whole bar, not its glyph")
        func measureRestSpansTheBar() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = Self.document()
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.last)
            #expect(measure.measureIndex == 1)
            let xPad = doc.metrics.sp * 1.4

            let restID = RestID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 1, voiceIndex: 0, elementIndex: 0,
            )
            let box = try Self.box(for: [.rest(restID)], in: doc)

            let firstBeat = try #require(measure.tickColumns[0])
            #expect(abs(box.minX - (measure.origin.x + firstBeat - xPad)) < 0.001)
            let barLineX = try #require(Self.trailingBarLineX(measure))
            #expect(abs(box.maxX - (barLineX - xPad)) < 0.001)

            // The glyph itself is centered, so the box's left edge has to
            // sit well left of it — that gap is the whole point.
            let restX = try #require(
                measure.elements.compactMap { element -> CGFloat? in
                    guard case let .rest(_, origin, _, _, _) = element else { return nil }
                    return measure.origin.x + origin.x
                }.first,
            )
            #expect(box.minX < restX - doc.metrics.sp * 4)
        }
    }
#endif
