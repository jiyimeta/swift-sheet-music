#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// A chord's leading grace notes stand clear of its accidentals, of each other and of the note before, and take
    /// room only when the gap before their chord was too narrow to hold them — MuseScore's grace-group layout
    /// (`LayoutEngine+GraceGroup.swift`). Reported 2026-10-11: graces drawn on top of the accidental of the note they
    /// lead into, and one acciaccatura spreading its beat several staff spaces wider than MuseScore does.
    ///
    /// Every assertion measures what the renderers DRAW: a grace chord at `staffSize × mag`, its head from
    /// `StemGeometry.attachDx` at that size, an accidental from `AccidentalPlacement.leftEdgeX`.
    @Suite("Grace group spacing")
    struct GraceGroupSpacingTests {
        /// `LayoutEngine.layout` asserts a real FontMetrics provider.
        private let _installApple = TestSupport.installApple

        // MARK: - Fixtures

        private static func note(_ pitch: Int, _ tpc: Int, _ accidental: Accidental? = nil) -> Note {
            Note(pitch: pitch, tpc: tpc, accidental: accidental, accidentalRole: accidental == nil ? .auto : .user)
        }

        private static func grace(_ pitch: Int, _ tpc: Int, _ accidental: Accidental? = nil) -> GraceChord {
            GraceChord(graceType: .acciaccatura, duration: .eighth, notes: ChordNotes([note(pitch, tpc, accidental)]))
        }

        private static func chord(
            _ duration: NoteDuration, _ pitch: Int, _ tpc: Int, _ accidental: Accidental? = nil,
            graces: [GraceChord] = [],
        ) -> VoiceElement {
            .chord(Chord(
                duration: duration, notes: ChordNotes([note(pitch, tpc, accidental)]), graceNotesBefore: graces,
            ))
        }

        /// One 4/4 bar per entry of `bars`, in treble clef.
        private static func score(_ bars: [[VoiceElement]]) -> Score {
            let measures = bars.enumerated().map { index, elements in
                Measure(voices: [Voice(elements: index == 0
                        ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))] + elements
                        : elements)])
            }
            return Score(division: 480, parts: [
                Part(id: "P0", instrument: Instrument(id: "x"), staves: [Staff(measures: measures)]),
            ])
        }

        private static func layout(_ score: Score, stretch: CGFloat = 1.5) -> LayoutDocument {
            var spacing = EngravingSpacing.standard
            spacing.systemStretch = stretch
            return LayoutEngine.layout(
                score: score, options: ScoreViewOptions(wrapToViewWidth: false, spacing: spacing),
                availableWidth: 10000,
            )
        }

        // MARK: - Readers

        private static func advance(_ codepoint: UInt32, sp: CGFloat) -> CGFloat {
            guard let scalar = UnicodeScalar(codepoint) else { return 0 }
            return FontMetrics.provider.typographicWidth(
                text: String(Character(scalar)),
                font: LayoutFont(face: SMuFLFamily.bravura, pointSize: StaffMetrics(staffSize: sp * 4).glyphFontSize),
            )
        }

        /// A head's drawn extent, and its accidental's left edge when it has one. Document x.
        private struct Ink {
            let headLeft: CGFloat
            let headRight: CGFloat
            let left: CGFloat
        }

        private static func ink(of note: LayoutChordNote, measureX: CGFloat, sp: CGFloat) -> Ink {
            let center = measureX + note.origin.x
            let halfHead = StemGeometry.attachDx(sp: sp)
            var left = center - halfHead
            if let accidental = note.accidental {
                left = measureX + AccidentalPlacement.leftEdgeX(
                    noteheadLeftX: note.origin.x - halfHead,
                    advanceWidth: advance(AccidentalGlyph.codepoint(accidental), sp: sp),
                    sp: sp,
                )
            }
            return Ink(headLeft: center - halfHead, headRight: center + halfHead, left: left)
        }

        /// The ink of measure `index`'s main chords and grace chords, each sorted left to right.
        private static func inks(_ doc: LayoutDocument, measure index: Int = 0) throws -> (main: [Ink], graces: [Ink]) {
            let sp = doc.metrics.sp
            let measures = doc.systems.flatMap(\.measures)
            try #require(index < measures.count)
            let measure = measures[index]
            var main: [Ink] = []
            var graces: [Ink] = []
            for element in measure.elements {
                switch element {
                case let .chord(notes, _, _, _, _, _, _, _, _, _, _):
                    guard let note = notes.first else { continue }
                    main.append(ink(of: note, measureX: measure.origin.x, sp: sp))
                case let .graceChord(notes, _, _, _, _, _, mag, _):
                    guard let note = notes.first else { continue }
                    graces.append(ink(of: note, measureX: measure.origin.x, sp: sp * mag))
                default:
                    continue
                }
            }
            return (main.sorted { $0.headLeft < $1.headLeft }, graces.sorted { $0.headLeft < $1.headLeft })
        }

        private static func barStarts(_ doc: LayoutDocument) -> [CGFloat] {
            doc.systems.flatMap(\.measures).map(\.origin.x)
        }

        // MARK: - Clear of the chord it leads into

        @Test(
            "a grace stands clear of the accidental of the note it leads into",
            arguments: [
                (pitch: 66, tpc: 20, accidental: Accidental.sharp, stretch: 1.5), (66, 8, .flat, 1.5),
                (65, 13, .natural, 1.5), (66, 20, .sharp, 0.05),
            ] as [(pitch: Int, tpc: Int, accidental: Accidental, stretch: CGFloat)],
        )
        func clearOfAccidental(pitch: Int, tpc: Int, accidental: Accidental, stretch: CGFloat) throws {
            let doc = Self.layout(Self.score([[
                Self.chord(.quarter, 69, 17),
                Self.chord(.quarter, pitch, tpc, accidental, graces: [Self.grace(67, 15)]),
                Self.chord(.half, 72, 14),
            ]]), stretch: stretch)
            let (main, graces) = try Self.inks(doc)
            let sp = doc.metrics.sp
            try #require(graces.count == 1 && main.count == 3)
            // MuseScore's note → accidental padding, scaled by the mean of the two sizes; 0.45 sp
            // (`graceToMainNoteDist`) is a grace's distance from a HEAD, not from an accidental.
            #expect(graces[0].headRight + Self.accidentalPadding(sp) <= main[1].left + 0.01)
            #expect(graces[0].headRight + LayoutEngine.graceToMainNoteDistSp * sp <= main[1].headLeft + 0.01)
        }

        private static func accidentalPadding(_ sp: CGFloat) -> CGFloat {
            LayoutEngine.graceAccidentalPaddingSp * (ScoreViewOptions().graceNoteMag + 1) / 2 * sp
        }

        @Test func `two graces keep apart and clear of the sharp they lead into`() throws {
            let doc = Self.layout(Self.score([[
                Self.chord(.quarter, 72, 14),
                Self.chord(.quarter, 73, 21, .sharp, graces: [Self.grace(67, 15), Self.grace(69, 17)]),
                Self.chord(.half, 72, 14, .natural),
            ]]))
            let (main, graces) = try Self.inks(doc)
            let sp = doc.metrics.sp
            try #require(graces.count == 2 && main.count == 3)
            #expect(graces[0].headRight + LayoutEngine.graceToGraceNoteDistSp * sp <= graces[1].left + 0.01)
            #expect(graces[1].headRight + Self.accidentalPadding(sp) <= main[1].left + 0.01)
        }

        @Test func `a grace with its own accidental keeps it clear of the note before`() throws {
            let doc = Self.layout(Self.score([[
                Self.chord(.sixteenth, 72, 14), Self.chord(.sixteenth, 72, 14),
                Self.chord(.sixteenth, 69, 17, graces: [Self.grace(68, 22, .sharp)]), Self.chord(.sixteenth, 72, 14),
                Self.chord(.quarter, 72, 14), Self.chord(.half, 72, 14),
            ]]), stretch: 0.05)
            let (main, graces) = try Self.inks(doc)
            try #require(graces.count == 1 && main.count == 6)
            #expect(main[1].headRight < graces[0].left)
        }

        // MARK: - Room only where it is needed

        /// A grace in a gap already wide enough for it — after a half note, at the default stretch — takes no width at
        /// all: MuseScore's shapes are a floor on the gap, not an addition to it. It used to add 1.5 sp to the gap's
        /// weight wherever it stood, which the stretch then multiplied.
        @Test func `a grace that fits its gap adds no width`() throws {
            let plain = Self.layout(Self.score([[
                Self.chord(.half, 72, 14), Self.chord(.quarter, 76, 18), Self.chord(.quarter, 77, 13),
            ]]))
            let graced = Self.layout(Self.score([[
                Self.chord(.half, 72, 14), Self.chord(.quarter, 76, 18, graces: [Self.grace(77, 13)]),
                Self.chord(.quarter, 77, 13),
            ]]))
            let before = try Self.inks(plain).main.map(\.headLeft)
            let after = try Self.inks(graced).main.map(\.headLeft)
            #expect(before == after)
        }

        @Test(
            "a grace between sixteenths stays clear of the note before it at any stretch",
            arguments: [0.05, 0.5, 1.5] as [CGFloat],
        )
        func clearOfPreviousNote(stretch: CGFloat) throws {
            let doc = Self.layout(Self.score([[
                Self.chord(.quarter, 69, 17, nil), Self.chord(.eighth, 69, 17),
                Self.chord(.sixteenth, 67, 15), Self.chord(.sixteenth, 67, 15, graces: [Self.grace(69, 17)]),
                Self.chord(.half, 66, 20, .sharp),
            ]]), stretch: stretch)
            let (main, graces) = try Self.inks(doc)
            let sp = doc.metrics.sp
            try #require(graces.count == 1 && main.count == 5)
            #expect(main[2].headRight + LayoutEngine.graceToMainNoteDistSp * sp <= graces[0].left + 0.01)
        }

        // MARK: - The bar's first chord

        /// A grace on a bar's first chord has no earlier column to be kept clear of, so the room comes from the bar's
        /// own lead-in. It used to come from nowhere: the group was drawn across the barline.
        @Test func `graces on a bar's first chord stay right of its barline`() throws {
            let doc = Self.layout(Self.score([
                [Self.chord(.whole, 72, 14)],
                [
                    Self.chord(.quarter, 73, 21, .sharp, graces: [Self.grace(67, 15), Self.grace(69, 17)]),
                    Self.chord(.quarter, 72, 14), Self.chord(.half, 72, 14),
                ],
            ]))
            let (_, graces) = try Self.inks(doc, measure: 1)
            let barline = try #require(Self.barStarts(doc).dropFirst().first)
            try #require(graces.count == 2)
            #expect(graces[0].left - barline >= doc.metrics.sp * 0.5)
        }
    }
#endif
