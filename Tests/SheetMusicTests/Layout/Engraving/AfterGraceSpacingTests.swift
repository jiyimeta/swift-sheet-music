#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// A chord's trailing grace notes stand before whatever follows it on the staff — the next chord or rest, in any
    /// voice, or the barline — as MuseScore appends them to the next segment (`LayoutEngine+GraceGroup.swift`). They
    /// used to stand a fixed 1.5 sp per grace right of their own chord, with that much added to its column's weight
    /// (reported 2026-10-12). Also here: a grace's flag keeps clear of an accidental it would cross, on either side.
    ///
    /// Every assertion measures what the renderers DRAW: a grace chord at `staffSize × mag`, its head from
    /// `StemGeometry.attachDx` at that size, an accidental from `AccidentalPlacement.leftEdgeX`.
    @Suite("After-grace spacing")
    struct AfterGraceSpacingTests {
        /// `LayoutEngine.layout` asserts a real FontMetrics provider.
        private let _installApple = TestSupport.installApple

        // MARK: - Fixtures

        private static func note(_ pitch: Int, _ tpc: Int, _ accidental: Accidental? = nil) -> Note {
            Note(pitch: pitch, tpc: tpc, accidental: accidental, accidentalRole: accidental == nil ? .auto : .user)
        }

        private static func grace(
            _ pitch: Int, _ tpc: Int, _ duration: NoteDuration = .eighth, type: GraceType = .grace8after,
        ) -> GraceChord {
            GraceChord(graceType: type, duration: duration, notes: ChordNotes([note(pitch, tpc)]))
        }

        private static func chord(
            _ duration: NoteDuration, _ pitch: Int, _ tpc: Int, _ accidental: Accidental? = nil,
            before: [GraceChord] = [], after: [GraceChord] = [],
        ) -> VoiceElement {
            .chord(Chord(
                duration: duration, notes: ChordNotes([note(pitch, tpc, accidental)]),
                graceNotesBefore: before, graceNotesAfter: after,
            ))
        }

        private static func rest(_ duration: NoteDuration) -> VoiceElement {
            .chord(Chord(duration: duration, notes: ChordNotes([])))
        }

        /// One 4/4 bar per entry of `bars`, each entry one voice per array, in treble clef.
        private static func score(_ bars: [[[VoiceElement]]]) -> Score {
            let measures = bars.enumerated().map { index, voices in
                Measure(voices: voices.enumerated().map { voiceIndex, elements in
                    Voice(elements: index == 0 && voiceIndex == 0
                        ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))] + elements
                        : elements)
                })
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

        /// A head's drawn extent, its accidental's left edge when it has one, and — for a grace — its flag's right
        /// edge. Document x.
        private struct Ink {
            let headLeft: CGFloat
            let headRight: CGFloat
            let left: CGFloat
            var flagRight: CGFloat
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
            return Ink(
                headLeft: center - halfHead, headRight: center + halfHead, left: left, flagRight: center + halfHead,
            )
        }

        private struct Inks {
            var main: [Ink] = []
            var graces: [Ink] = []
            var rests: [CGFloat] = []
            var barline: CGFloat?
        }

        /// Measure `index`'s main chords, grace chords (each with its flag), rests (their x) and trailing barline.
        private static func inks(_ doc: LayoutDocument, measure index: Int = 0) throws -> Inks {
            let sp = doc.metrics.sp
            let measures = doc.systems.flatMap(\.measures)
            try #require(index < measures.count)
            let measure = measures[index]
            let x0 = measure.origin.x
            var out = Inks()
            for element in measure.elements {
                switch element {
                case let .chord(notes, _, _, _, _, _, _, _, _, _, _):
                    guard let note = notes.first else { continue }
                    out.main.append(ink(of: note, measureX: x0, sp: sp))
                case let .graceChord(notes, duration, stem, _, _, _, mag, _):
                    guard let note = notes.first else { continue }
                    var grace = ink(of: note, measureX: x0, sp: sp * mag)
                    let model = GraceChord(graceType: .grace8after, duration: duration, notes: ChordNotes([Note(
                        pitch: 60, tpc: 14,
                    )]))
                    let shape = LayoutEngine.graceInk(of: model, stem: stem, mag: mag, metrics: doc.metrics)
                    grace.flagRight = x0 + note.origin.x + shape.flagRight
                    out.graces.append(grace)
                case let .rest(_, origin, _, _, _):
                    out.rests.append(x0 + origin.x)
                case let .barLine(_, origin, _, _, role) where role == .trailing:
                    out.barline = x0 + origin.x
                default:
                    continue
                }
            }
            out.main.sort { $0.headLeft < $1.headLeft }
            out.graces.sort { $0.headLeft < $1.headLeft }
            return out
        }

        // MARK: - Before what follows

        /// MuseScore 4's rendering of this bar puts the grace 1.04 sp before the E, nowhere near the C it follows.
        @Test(
            "a trailing grace stands right before the next note, not after its own",
            arguments: [0.5, 1.5] as [CGFloat],
        )
        func beforeNextNote(stretch: CGFloat) throws {
            let doc = Self.layout(Self.score([[[
                Self.chord(.quarter, 72, 14, after: [Self.grace(74, 16)]),
                Self.chord(.quarter, 76, 18), Self.chord(.half, 79, 15),
            ]]]), stretch: stretch)
            let inks = try Self.inks(doc)
            let sp = doc.metrics.sp
            try #require(inks.graces.count == 1 && inks.main.count == 3)
            let grace = inks.graces[0]
            #expect(grace.headRight + LayoutEngine.graceToMainNoteDistSp * sp <= inks.main[1].headLeft + 0.01)
            #expect(inks.main[1].headLeft - grace.headRight <= 1.2 * sp)
            // Nearer the note it leads into than the one it follows.
            #expect(grace.headLeft - inks.main[0].headRight > inks.main[1].headLeft - grace.headRight)
        }

        @Test func `trailing graces at a bar's end stand before its barline`() throws {
            let doc = Self.layout(Self.score([
                [[
                    Self.chord(.quarter, 72, 14), Self.chord(.quarter, 72, 14),
                    Self.chord(.half, 65, 13, after: [Self.grace(67, 15, .sixteenth), Self.grace(69, 17, .sixteenth)]),
                ]],
                [[Self.chord(.whole, 72, 14)]],
            ]))
            let inks = try Self.inks(doc)
            let sp = doc.metrics.sp
            let barline = try #require(inks.barline)
            try #require(inks.graces.count == 2 && inks.main.count == 3)
            let mag = ScoreViewOptions().graceNoteMag
            let last = inks.graces[1]
            // MuseScore's note → barline padding, scaled by the mean of the two sizes; the barline's thin stroke is
            // drawn across its x.
            #expect(last.headRight + LayoutEngine.graceBarlinePaddingSp * (mag + 1) / 2 * sp <= barline + 0.01)
            #expect(last.flagRight + LayoutEngine.graceFlagBarlinePaddingSp * (mag + 1) / 2 * sp <= barline + 0.01)
            #expect(barline - last.headRight <= 2.5 * sp)
            #expect(inks.graces[0].headRight + LayoutEngine.graceToGraceNoteDistSp * sp <= last.headLeft + 0.01)
            #expect(inks.main[2].headRight + LayoutEngine.graceToMainNoteDistSp * sp <= inks.graces[0].left + 0.01)
        }

        @Test func `a trailing grace stands before a rest that follows`() throws {
            let doc = Self.layout(Self.score([[[
                Self.chord(.quarter, 69, 17, after: [Self.grace(71, 19)]), Self.rest(.quarter),
                Self.chord(.half, 72, 14),
            ]]]))
            let inks = try Self.inks(doc)
            let sp = doc.metrics.sp
            try #require(inks.graces.count == 1 && inks.rests.count == 1 && inks.main.count == 2)
            let restLeft = inks.rests[0] - Self.advance(RestGlyph.codepoint(duration: .quarter), sp: sp) / 2
            let grace = inks.graces[0]
            // MuseScore 4 draws this grace 1.04 sp before the rest: its flag 0.3 sp short of it.
            #expect(grace.headRight + LayoutEngine.graceToMainNoteDistSp * sp <= restLeft + 0.01)
            #expect(restLeft - grace.headRight <= 1.2 * sp)
        }

        /// MuseScore appends a trailing group to the next segment that holds anything on the STAFF, so a note in
        /// another voice that comes before the chord's own next note is what the graces stand before.
        @Test func `a trailing grace stands before the next column in any voice`() throws {
            let doc = Self.layout(Self.score([[
                [Self.chord(.half, 72, 14, after: [Self.grace(74, 16)]), Self.chord(.half, 72, 14)],
                [Self.chord(.quarter, 65, 13), Self.chord(.quarter, 65, 13), Self.chord(.half, 65, 13)],
            ]]))
            let inks = try Self.inks(doc)
            let sp = doc.metrics.sp
            try #require(inks.graces.count == 1 && inks.main.count == 5)
            let columns = inks.main.map(\.headLeft).reduce(into: [CGFloat]()) { xs, x in
                if xs.last.map({ abs($0 - x) > 0.5 }) ?? true { xs.append(x) }
            }
            try #require(columns.count == 3)
            let grace = inks.graces[0]
            #expect(grace.headRight + LayoutEngine.graceToMainNoteDistSp * sp <= columns[1] + 0.01)
            #expect(grace.headLeft > columns[0])
        }

        @Test func `a trailing grace stands left of the next chord's own leading graces`() throws {
            let doc = Self.layout(Self.score([[[
                Self.chord(.half, 72, 14, after: [Self.grace(74, 16)]),
                Self.chord(.half, 76, 18, before: [Self.grace(77, 13, type: .acciaccatura)]),
            ]]]))
            let inks = try Self.inks(doc)
            let sp = doc.metrics.sp
            try #require(inks.graces.count == 2 && inks.main.count == 2)
            #expect(inks.graces[0].headRight + LayoutEngine.graceToGraceNoteDistSp * sp <= inks.graces[1].left + 0.01)
            #expect(inks.graces[1].headRight + LayoutEngine.graceToMainNoteDistSp * sp <= inks.main[1].left + 0.01)
        }

        // MARK: - Room only where it is needed

        /// A trailing grace in a gap already wide enough for it takes no width: it is a floor on the gap, as
        /// MuseScore's shapes are. It used to add 1.5 sp to its chord's weight wherever it stood, which the stretch
        /// then multiplied.
        @Test func `a trailing grace that fits its gap adds no width`() throws {
            let plain = Self.layout(Self.score([[[
                Self.chord(.half, 72, 14), Self.chord(.quarter, 76, 18), Self.chord(.quarter, 77, 13),
            ]]]))
            let graced = Self.layout(Self.score([[[
                Self.chord(.half, 72, 14, after: [Self.grace(74, 16)]), Self.chord(.quarter, 76, 18),
                Self.chord(.quarter, 77, 13),
            ]]]))
            #expect(try Self.inks(plain).main.map(\.headLeft) == Self.inks(graced).main.map(\.headLeft))
        }

        @Test(
            "a trailing grace between sixteenths stays clear of both its neighbours at any stretch",
            arguments: [0.05, 0.5, 1.5] as [CGFloat],
        )
        func clearOfBothNeighbours(stretch: CGFloat) throws {
            let doc = Self.layout(Self.score([[[
                Self.chord(.sixteenth, 72, 14), Self.chord(.sixteenth, 72, 14, after: [Self.grace(74, 16)]),
                Self.chord(.sixteenth, 66, 20, .sharp), Self.chord(.sixteenth, 72, 14),
                Self.chord(.quarter, 72, 14), Self.chord(.half, 72, 14),
            ]]]), stretch: stretch)
            let inks = try Self.inks(doc)
            let sp = doc.metrics.sp
            try #require(inks.graces.count == 1 && inks.main.count == 6)
            let grace = inks.graces[0]
            #expect(inks.main[1].headRight + LayoutEngine.graceToMainNoteDistSp * sp <= grace.left + 0.01)
            #expect(grace.headRight < inks.main[2].left)
        }

        // MARK: - A flag and an accidental

        /// MuseScore 4 keeps an acciaccatura's flag 0.3 sp short of the sharp of the note it leads into when the two
        /// would cross; the flag used to ride over every accidental. The same rule holds on both sides of a chord.
        @Test(
            "a grace's flag keeps clear of a sharp it would cross",
            arguments: [GraceType.acciaccatura, .grace8after],
        )
        func flagClearOfCrossedSharp(type: GraceType) throws {
            let grace = Self.grace(67, 15, type: type)
            let doc = Self.layout(Self.score([[[
                Self.chord(.half, 72, 14, after: type.isAfter ? [grace] : []),
                Self.chord(.half, 70, 24, .sharp, before: type.isAfter ? [] : [grace]),
            ]]]))
            let inks = try Self.inks(doc)
            let sp = doc.metrics.sp
            try #require(inks.graces.count == 1 && inks.main.count == 2)
            let mag = ScoreViewOptions().graceNoteMag
            #expect(inks.graces[0].flagRight > inks.graces[0].headRight)
            #expect(
                inks.graces[0].flagRight + LayoutEngine.graceFlagPaddingSp * (mag + 1) / 2 * sp
                    <= inks.main[1].left + 0.01,
            )
        }

        /// A sharp a sixth above the grace lies wholly above its flag, so the flag passes under it and only the head
        /// keeps its distance — MuseScore's shapes are two-dimensional there.
        @Test func `a grace's flag rides past a sharp it does not cross`() throws {
            let doc = Self.layout(Self.score([[[
                Self.chord(.half, 72, 14),
                Self.chord(.half, 78, 20, .sharp, before: [Self.grace(64, 18, type: .acciaccatura)]),
            ]]]))
            let inks = try Self.inks(doc)
            let sp = doc.metrics.sp
            try #require(inks.graces.count == 1 && inks.main.count == 2)
            let mag = ScoreViewOptions().graceNoteMag
            let grace = inks.graces[0]
            let padding = LayoutEngine.graceAccidentalPaddingSp * (mag + 1) / 2 * sp
            #expect(abs(grace.headRight + padding - inks.main[1].left) < 0.01)
            #expect(grace.flagRight > inks.main[1].left)
        }
    }
#endif
