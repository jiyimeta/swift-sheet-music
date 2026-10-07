#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// A clef written in the middle of a bar stands before the note it governs, clear of it and of the note before —
    /// it used to be drawn at the next note's own x, on top of it, with no room made for it.
    ///
    /// Every assertion measures what the renderers DRAW: the clef glyph's own advance from its origin, the noteheads
    /// from `StemGeometry.attachDx`, the accidental from `AccidentalPlacement.leftEdgeX`.
    @Suite("Mid-measure clef spacing")
    struct MidMeasureClefSpacingTests {
        /// `LayoutEngine.layout` asserts a real FontMetrics provider.
        private let _installApple = TestSupport.installApple

        // MARK: - Fixtures

        private static func quarter(_ pitch: Int, _ tpc: Int, _ accidental: Accidental? = nil) -> VoiceElement {
            .chord(Chord(duration: .quarter, notes: ChordNotes([
                Note(pitch: pitch, tpc: tpc, accidental: accidental, accidentalRole: accidental == nil ? .auto : .user),
            ])))
        }

        /// One 4/4 bar: C5, D5, then a bass clef before the third quarter — spelled with a sharp when `sharpAfter`.
        private static func score(sharpAfter: Bool) -> Score {
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                quarter(72, 14), quarter(74, 16),
                .clef(Clef(concertClefType: "F")),
                sharpAfter ? quarter(54, 20, .sharp) : quarter(52, 18),
                quarter(53, 13),
            ])
            return Score(division: 480, parts: [
                Part(id: "P0", instrument: Instrument(id: "x"), staves: [Staff(measures: [Measure(voices: [voice])])]),
            ])
        }

        private static func layout(_ score: Score, stretch: CGFloat, wrap: Bool, width: CGFloat) -> LayoutDocument {
            var spacing = EngravingSpacing.standard
            spacing.systemStretch = stretch
            return LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(wrapToViewWidth: wrap, spacing: spacing),
                availableWidth: width,
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

        /// The mid-bar clef's ink, and the ink either side of it: the previous note's right edge, and the left edge
        /// of the next column — its accidental when it has one, else its notehead. Document x.
        private struct Neighbourhood {
            let previousRight: CGFloat
            let clefLeft: CGFloat
            let clefRight: CGFloat
            let nextLeft: CGFloat
        }

        private static func neighbourhood(_ doc: LayoutDocument) throws -> Neighbourhood {
            let sp = doc.metrics.sp
            let halfHead = StemGeometry.attachDx(sp: sp)
            let measure = try #require(doc.systems.first?.measures.first)
            var heads: [(x: CGFloat, left: CGFloat)] = []
            var clef: (x: CGFloat, width: CGFloat)?
            for element in measure.elements {
                switch element {
                case let .chord(notes, _, stem, _, _, _, _, _, _, _, _):
                    guard let note = notes.first else { continue }
                    let center = measure.origin.x + note.origin.x + note.mirrorDx(stem: stem, sp: sp)
                    var left = center - halfHead
                    if let accidental = note.accidental {
                        left = measure.origin.x + AccidentalPlacement.leftEdgeX(
                            noteheadLeftX: note.origin.x + note.mirrorDx(stem: stem, sp: sp) - halfHead,
                            advanceWidth: advance(AccidentalGlyph.codepoint(accidental), sp: sp),
                            sp: sp,
                        )
                    }
                    heads.append((center, left))
                case let .clef(rawType, origin, .explicit, mag):
                    // A clef's origin is its glyph's center, and `mag` the size it is drawn at.
                    let glyph = ClefGlyph.glyph(for: NotatedClef(rawType: rawType)).codepoint
                    clef = (measure.origin.x + origin.x, advance(glyph, sp: sp) * mag)
                default:
                    continue
                }
            }
            heads.sort { $0.x < $1.x }
            let drawn = try #require(clef)
            try #require(heads.count == 4)
            return Neighbourhood(
                previousRight: heads[1].x + halfHead,
                clefLeft: drawn.x - drawn.width / 2, clefRight: drawn.x + drawn.width / 2,
                nextLeft: heads[2].left,
            )
        }

        // MARK: - Tests

        @Test(
            "a mid-bar clef stands between the notes either side of it",
            arguments: [
                (stretch: 0.05, wrap: true, width: 240, sharpAfter: false),
                (stretch: 0.05, wrap: false, width: 240, sharpAfter: false),
                (stretch: 1.5, wrap: true, width: 900, sharpAfter: false),
                (stretch: 0.05, wrap: true, width: 240, sharpAfter: true),
                (stretch: 1.5, wrap: false, width: 900, sharpAfter: true),
            ] as [(stretch: CGFloat, wrap: Bool, width: CGFloat, sharpAfter: Bool)],
        )
        func clefStandsBetweenNotes(stretch: CGFloat, wrap: Bool, width: CGFloat, sharpAfter: Bool) throws {
            let doc = Self.layout(Self.score(sharpAfter: sharpAfter), stretch: stretch, wrap: wrap, width: width)
            let sp = doc.metrics.sp
            let around = try Self.neighbourhood(doc)

            let gap = sharpAfter ? LayoutEngine.midMeasureClefGapSp : LayoutEngine.midMeasureClefNoteGapSp
            #expect((around.nextLeft - around.clefRight) / sp >= gap - 0.01)
            #expect((around.clefLeft - around.previousRight) / sp >= 0.3)
        }

        @Test("a clef past a bar's first chord is drawn small, one at its head full size")
        func clefSizes() throws {
            let doc = Self.layout(Self.score(sharpAfter: false), stretch: 1, wrap: false, width: 600)
            let measure = try #require(doc.systems.first?.measures.first)
            let mags = measure.elements.compactMap { element -> CGFloat? in
                if case let .clef(_, _, .explicit, mag) = element { mag } else { nil }
            }
            #expect(mags == [LayoutEngine.smallClefMag])
            let opening = measure.elements.compactMap { element -> CGFloat? in
                if case let .clef(_, _, .staffDefault, mag) = element { mag } else { nil }
            }
            #expect(opening == [1])
        }

        // MARK: - A clef after the bar's last chord

        /// Two 4/4 bars of quarters; the first ends with a treble clef after its last quarter — how MuseScore spells a
        /// clef change at the next barline.
        private static func barEndScore() -> Score {
            let first = Voice(elements: [
                .clef(Clef(concertClefType: "F")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                quarter(48, 14), quarter(50, 16), quarter(52, 18), quarter(53, 13),
                .clef(Clef(concertClefType: "G")),
            ])
            let second = Voice(elements: [quarter(72, 14), quarter(74, 16), quarter(76, 18), quarter(77, 13)])
            return Score(division: 480, parts: [
                Part(id: "P0", instrument: Instrument(id: "x"), staves: [Staff(measures: [
                    Measure(voices: [first]), Measure(voices: [second]),
                ])]),
            ])
        }

        /// It used to be drawn where nothing was placed — at the start of the bar's content, over its first note.
        @Test(
            "a clef after a bar's last chord stands small before the barline, clear of the last note",
            arguments: [(stretch: 0.05, width: 240), (stretch: 1.5, width: 900)]
            as [(stretch: CGFloat, width: CGFloat)],
        )
        func barEndClefStandsBeforeTheBarline(stretch: CGFloat, width: CGFloat) throws {
            let doc = Self.layout(Self.barEndScore(), stretch: stretch, wrap: false, width: width)
            let sp = doc.metrics.sp
            let measure = try #require(doc.systems.first?.measures.first)
            var heads: [CGFloat] = []
            var clef: (x: CGFloat, mag: CGFloat, rawType: String)?
            for element in measure.elements {
                switch element {
                case let .chord(notes, _, stem, _, _, _, _, _, _, _, _):
                    guard let note = notes.first else { continue }
                    heads.append(note.origin.x + note.mirrorDx(stem: stem, sp: sp))
                case let .clef(rawType, origin, .explicit, mag):
                    clef = (origin.x, mag, rawType)
                default:
                    continue
                }
            }
            let drawn = try #require(clef)
            let lastHead = try #require(heads.max())
            let glyph = ClefGlyph.glyph(for: NotatedClef(rawType: drawn.rawType)).codepoint
            let halfWidth = Self.advance(glyph, sp: sp) * drawn.mag / 2
            let barline = measure.width - sp / 2

            #expect(drawn.mag == LayoutEngine.smallClefMag)
            #expect(abs((barline - (drawn.x + halfWidth)) / sp - LayoutEngine.clefBarlineDistanceSp) < 0.01)
            #expect((drawn.x - halfWidth - (lastHead + StemGeometry.attachDx(sp: sp))) / sp >= 0.3)
        }
    }
#endif
