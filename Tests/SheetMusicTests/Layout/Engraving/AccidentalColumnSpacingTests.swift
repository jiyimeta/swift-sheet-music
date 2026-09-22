#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// An accidental is drawn left of its notehead, inside the gap before its column, so it collides with the
    /// previous note whenever that gap is squeezed toward its spacing weight — at a system's minimum width, and
    /// whenever a host asks for dense music through `EngravingSpacing.systemStretch`.
    ///
    /// MuseScore places each segment at `max(natural, shape distance)`
    /// (`HorizontalSpacing::spaceAgainstPreviousSegments`); spacing density divides only the natural part, so no
    /// density puts an accidental on the previous note. Its padding between a note (or dot) and a following
    /// accidental is 0.35 sp (`paddingtable.cpp`), which is what these tests hold the engraved ink to.
    ///
    /// Every assertion measures what the renderers DRAW — `AccidentalPlacement.leftEdgeX` from the glyph's own
    /// advance, `DotGeometry` for dots — not the engine's own collision table.
    @Suite("Accidental column spacing")
    struct AccidentalColumnSpacingTests {
        /// `LayoutEngine.layout` asserts a real FontMetrics provider.
        private let _installApple = TestSupport.installApple

        private static let notePadSp: CGFloat = 0.35

        // MARK: - Fixtures

        /// `(pitch, tpc, accidental)`.
        typealias Pitch = (Int, Int, Accidental?)

        private static let c4: Pitch = (60, 14, nil)
        private static let cSharp4: Pitch = (61, 21, .sharp)
        private static let d4: Pitch = (62, 16, nil)
        private static let eFlat4: Pitch = (63, 11, .flat)
        private static let e4: Pitch = (64, 18, nil)
        private static let f4: Pitch = (65, 13, nil)
        private static let fSharp4: Pitch = (66, 20, .sharp)
        private static let g4: Pitch = (67, 15, nil)
        private static let eDoubleFlat4: Pitch = (62, 4, .doubleFlat)

        private static func chord(
            _ duration: NoteDuration, _ pitches: [Pitch],
        ) -> VoiceElement {
            .chord(Chord(
                duration: duration,
                // USER, so the layout's redundant-accidental pass never
                // hides one and every fixture draws what it spells.
                notes: ChordNotes(pitches.map {
                    Note(
                        pitch: $0.0, tpc: $0.1, accidental: $0.2,
                        accidentalRole: $0.2 == nil ? .auto : .user,
                    )
                }),
            ))
        }

        private static func part(_ id: String, _ measures: [[VoiceElement]]) -> Part {
            let staff = Staff(measures: measures.enumerated().map { index, elements in
                let head: [VoiceElement] = index == 0
                    ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                    : []
                return Measure(voices: [Voice(elements: head + elements)])
            })
            return Part(id: id, instrument: Instrument(id: "\(id)-voice"), staves: [staff])
        }

        /// Chromatic eighths, then sixteenths, then a dotted rhythm — accidentals after plain notes, after a dot
        /// and after a rest.
        private static func chromaticScore() -> Score {
            let eighths = [c4, cSharp4, d4, eFlat4, e4, f4, fSharp4, g4].map { chord(.eighth, [$0]) }
            let sixteenths = [g4, fSharp4, f4, e4, eFlat4, d4, cSharp4, c4, d4, eFlat4, e4, f4, fSharp4, g4, e4, c4]
                .map { chord(.sixteenth, [$0]) }
            let dotted: [VoiceElement] = [
                chord(.fraction(Fraction(numerator: 3, denominator: 16)), [f4]),
                chord(.sixteenth, [fSharp4]),
                .chord(Chord(duration: .eighth, notes: ChordNotes([]))),
                chord(.eighth, [eFlat4]),
                chord(.quarter, [d4]),
                chord(.quarter, [eDoubleFlat4]),
            ]
            return Score(division: 480, parts: [part("P0", [eighths, sixteenths, dotted])])
        }

        private static func layout(
            _ score: Score, stretch: CGFloat, wrap: Bool, width: CGFloat,
        ) -> LayoutDocument {
            var spacing = EngravingSpacing.standard
            spacing.systemStretch = stretch
            return LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(wrapToViewWidth: wrap, spacing: spacing),
                availableWidth: width,
            )
        }

        // MARK: - Readers

        private struct Column {
            let x: CGFloat
            let partIndex: Int
            /// Left edge of the accidental group the renderers draw, if any.
            let accidentalLeft: CGFloat?
            /// Right edge of the rightmost notehead / dot / rest ink.
            let inkRight: CGFloat
        }

        private static func advance(_ codepoint: UInt32, sp: CGFloat) -> CGFloat {
            guard let scalar = UnicodeScalar(codepoint) else { return 0 }
            return FontMetrics.provider.typographicWidth(
                text: String(Character(scalar)),
                font: LayoutFont(face: SMuFLFamily.bravura, pointSize: StaffMetrics(staffSize: sp * 4).glyphFontSize),
            )
        }

        /// Every chord and rest of `measure`, in document x, left to right.
        private static func columns(_ measure: LayoutMeasure, sp: CGFloat) -> [Column] {
            var out: [Column] = []
            let halfHead = StemGeometry.attachDx(sp: sp)
            for element in measure.elements {
                switch element {
                case let .chord(notes, duration, stem, _, _, _, _, _, _, _, _):
                    guard let first = notes.first else { continue }
                    let dots = DurationInterpretation.split(duration).dots
                    var left: CGFloat?
                    var right: CGFloat = -.infinity
                    for note in notes {
                        let center = note.origin.x + note.mirrorDx(stem: stem, sp: sp)
                        right = max(right, center + halfHead)
                        if let lastDot = DotGeometry.centers(
                            after: CGPoint(x: center, y: note.origin.y), count: dots,
                            onStaffLine: false, sp: sp,
                        ).last {
                            right = max(right, lastDot.x + DotGeometry.radiusSp * sp)
                        }
                        if let accidental = note.accidental {
                            let edge = AccidentalPlacement.leftEdgeX(
                                noteheadLeftX: center - halfHead,
                                advanceWidth: advance(AccidentalGlyph.codepoint(accidental), sp: sp),
                                sp: sp,
                            )
                            left = min(left ?? edge, edge)
                        }
                    }
                    out.append(Column(
                        x: measure.origin.x + first.origin.x,
                        partIndex: first.noteID.staff.partIndex,
                        accidentalLeft: left.map { measure.origin.x + $0 },
                        inkRight: measure.origin.x + right,
                    ))
                case let .rest(duration, origin, _, rid, _):
                    let half = advance(RestGlyph.codepoint(duration: duration), sp: sp) / 2
                    out.append(Column(
                        x: measure.origin.x + origin.x,
                        partIndex: rid.staff.partIndex,
                        accidentalLeft: nil,
                        inkRight: measure.origin.x + origin.x + half,
                    ))
                default:
                    continue
                }
            }
            return out.sorted { $0.x < $1.x }
        }

        /// The clearance from each accidental to the ink of the previous column in the same part, in sp.
        private static func accidentalClearances(_ doc: LayoutDocument) -> [CGFloat] {
            let sp = doc.metrics.sp
            var clearances: [CGFloat] = []
            for system in doc.systems {
                for measure in system.measures {
                    let byPart = Dictionary(grouping: columns(measure, sp: sp), by: \.partIndex)
                    for columns in byPart.values {
                        for (previous, column) in zip(columns, columns.dropFirst()) {
                            guard let left = column.accidentalLeft else { continue }
                            clearances.append((left - previous.inkRight) / sp)
                        }
                    }
                }
            }
            return clearances
        }

        // MARK: - Tests

        /// The three ways a layout reaches a tight measure: a wrapped system packed to its minimum width, a
        /// horizontal strip at a stretch under 1, and the defaults.
        @Test(
            "an accidental keeps MuseScore's padding from the previous note",
            arguments: [
                (stretch: 0.05, wrap: true, width: 240),
                (stretch: 0.05, wrap: false, width: 240),
                (stretch: 1.5, wrap: true, width: 900),
                (stretch: 1.5, wrap: false, width: 900),
            ] as [(stretch: CGFloat, wrap: Bool, width: CGFloat)],
        )
        func accidentalClearsPreviousNote(stretch: CGFloat, wrap: Bool, width: CGFloat) {
            let doc = Self.layout(Self.chromaticScore(), stretch: stretch, wrap: wrap, width: width)
            let clearances = Self.accidentalClearances(doc)
            #expect(clearances.count == 11)
            for clearance in clearances {
                #expect(
                    clearance >= Self.notePadSp - 0.001,
                    "an accidental sits \(clearance) sp from the previous note's ink",
                )
            }
        }

        /// A column of another part between the two keeps spanning the distance, but the gap before the
        /// accidental still has to make up whatever the span falls short by. Two eighths against four
        /// sixteenths: at the minimum each sixteenth gap is 1.5 sp, and a double flat after a plain note needs
        /// more than the two of them together.
        @Test("a column of another staff in between does not hide the collision")
        func interveningColumnOfAnotherStaff() {
            let upper = Self.part("P0", [[
                Self.chord(.eighth, [Self.c4]), Self.chord(.eighth, [Self.eDoubleFlat4]),
                Self.chord(.eighth, [Self.c4]), Self.chord(.eighth, [Self.eDoubleFlat4]),
                Self.chord(.half, [Self.c4]),
            ]])
            let lower = Self.part("P1", [
                Array(repeating: Self.chord(.sixteenth, [Self.g4]), count: 8)
                    + [Self.chord(.half, [Self.g4])],
            ])
            let doc = Self.layout(
                Score(division: 480, parts: [upper, lower]), stretch: 0.05, wrap: true, width: 120,
            )
            let clearances = Self.accidentalClearances(doc)
            #expect(clearances.count == 2)
            for clearance in clearances {
                #expect(clearance >= Self.notePadSp - 0.001, "\(clearance) sp")
            }
        }

        /// Below a stretch of 1 a horizontal strip used to scale each measure's MINIMUM width down with it, so
        /// every measure was drawn narrower than its own notes and the next measure started on top of them.
        @Test("a horizontal strip never draws a measure narrower than its notes")
        func horizontalStripKeepsMeasuresApart() {
            let doc = Self.layout(Self.chromaticScore(), stretch: 0.05, wrap: false, width: 240)
            let sp = doc.metrics.sp
            let measures = doc.systems.flatMap(\.measures)
            #expect(measures.count == 3)
            for measure in measures {
                for column in Self.columns(measure, sp: sp) {
                    #expect(column.inkRight < measure.origin.x + measure.width)
                }
            }
            for (a, b) in zip(measures, measures.dropFirst()) {
                #expect(a.origin.x + a.width <= b.origin.x + 0.001)
            }
        }

        /// A stretch at or above 1 still widens the strip exactly as before — the floor only ever holds a
        /// measure up, it does not change a measure no accidental is squeezed in.
        @Test("a horizontal strip without accidentals is spaced as before")
        func horizontalStripWithoutAccidentals() {
            let plain = Self.part("P0", [[Self.c4, Self.d4, Self.e4, Self.f4].map { Self.chord(.quarter, [$0]) }])
            let score = Score(division: 480, parts: [plain])
            let tight = Self.layout(score, stretch: 1, wrap: false, width: 240)
            let loose = Self.layout(score, stretch: 1.5, wrap: false, width: 240)
            let tightWidth = tight.systems[0].measures[0].width
            let looseWidth = loose.systems[0].measures[0].width
            #expect(abs(looseWidth - tightWidth * 1.5) < 0.001)
        }
    }

    @Suite("Collision-floored gap filling")
    struct FilledGapsTests {
        @Test("without a binding floor the gaps are the weights, scaled")
        func proportionalWhenNoFloorBinds() {
            let gaps = LayoutEngine.filledGaps(weights: [1, 2, 3], floors: [0, 1, 0], content: 12)
            #expect(gaps == [2, 4, 6])
        }

        @Test("a floored gap stays at its floor and the rest share what is left")
        func flooredGapTakesNoMore() {
            let gaps = LayoutEngine.filledGaps(weights: [1, 1, 1, 1], floors: [0, 5, 0, 0], content: 11)
            #expect(gaps == [2, 5, 2, 2])
        }

        @Test("a floor released by enough room stretches with the others")
        func floorReleasedAtLargeContent() {
            let gaps = LayoutEngine.filledGaps(weights: [1, 1], floors: [3, 0], content: 8)
            #expect(gaps == [4, 4])
        }

        /// 9.5 is the minimum `Σ max(floor, weight)` — the least room a caller ever offers.
        @Test("floors that bind in turn as the room shrinks", arguments: [9.5, 10.0, 14.0, 30.0] as [CGFloat])
        func cascadingFloors(content: CGFloat) {
            let weights: [CGFloat] = [1, 1, 1, 2]
            let floors: [CGFloat] = [4, 2.5, 0, 0]
            let gaps = LayoutEngine.filledGaps(weights: weights, floors: floors, content: content)
            #expect(abs(gaps.reduce(0, +) - content) < 0.0001)
            for i in gaps.indices {
                #expect(gaps[i] >= floors[i] - 0.0001)
                #expect(gaps[i] >= weights[i] - 0.0001)
            }
            // The unfloored gaps keep their proportion to each other.
            #expect(abs(gaps[3] - 2 * gaps[2]) < 0.0001)
        }
    }
#endif
