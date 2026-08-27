#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// Geometry and the collect → resolve → attach pass that turns
    /// `Note.legacyBend` into `LayoutElement.legacyBend` spanners.
    /// Ported from MuseScore's `TDraw::draw(const Bend*)`
    /// (`rendering/score/tdraw.cpp:939`).
    @Suite("Legacy MS3 bend layout")
    struct LegacyBendLayoutTests {
        private let _installApple = TestSupport.installApple

        // MARK: - Pipeline

        /// The canonical MS3 fixture produces one legacyBend element per
        /// bend-carrying measure, attached to the system's spanners.
        ///
        /// SIX, not five: the fixture's sixth measure carries a hand-drawn
        /// 13-point curve on top of the five canonical table curves (see
        /// `LegacyBendDecodeTests.decodesCanonicalCurves`). All six sit on
        /// principal single-note chords with ≥ 2 points, so all six lay out.
        @Test("the canonical fixture emits one element per bend")
        func canonicalFixtureEmitsElements() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = try MSCXParser.parse(
                MSCXFixtureLoader.mscxData("legacybend_ms3_canonical"),
            )
            let document = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 1200,
            )
            #expect(Self.shapes(in: document).count == 6)
        }

        @Test("a one-point curve draws nothing")
        func fewerThanTwoPointsProducesNothing() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let document = Self.singleBendDocument(
                points: [.init(time: 0, pitch: 100)],
            )
            #expect(Self.shapes(in: document).isEmpty)
        }

        @Test("a note without a legacy bend emits nothing")
        func plainScoreEmitsNothing() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let document = Self.singleBendDocument(points: nil)
            #expect(Self.shapes(in: document).isEmpty)
        }

        /// The attach pass converts from the geometry's note-local frame
        /// (origin = notehead LEFT edge, notehead-centre y) to system-local
        /// coords: every point shifts by
        /// `(noteCentre.x - 0.59 sp, noteCentre.y)`.
        @Test("pieces land in system-local coords off the notehead's left edge")
        func attachTranslatesToNoteheadLeftEdge() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let document = Self.singleBendDocument(
                points: [
                    .init(time: 0, pitch: 0),
                    .init(time: 15, pitch: 100),
                    .init(time: 60, pitch: 100),
                ],
            )
            let found = Self.shapes(in: document)
            #expect(found.count == 1)
            guard let shape = found.first,
                  case let .curve(from, _, _, _) = shape.pieces.first,
                  let note = Self.firstNoteOrigin(in: document)
            else { return }
            let sp = document.metrics.sp
            let leftEdge = note.x - sp * 1.18 / 2
            // Geometry's own start x is `noteWidth + 0.2 sp` past the left
            // edge; y is `-0.8 sp` off the notehead centre.
            #expect(abs(from.x - (leftEdge + sp * (1.18 + 0.2))) < 0.01)
            #expect(abs(from.y - (note.y - sp * 0.8)) < 0.01)
        }

        // MARK: - Geometry

        /// Plain bend {(0,0),(15,100),(60,100)}: one up-curve with arrow and
        /// "full" label; the final flat segment is elided — MuseScore breaks
        /// at `pt == n - 2` when the last two pitches are equal.
        @Test("a plain bend rises once, with an arrow and a label")
        func plainBendShape() {
            let shape = LegacyBendGeometry.shape(
                points: [
                    .init(time: 0, pitch: 0),
                    .init(time: 15, pitch: 100),
                    .init(time: 60, pitch: 100),
                ],
                noteWidth: 11.8, notePosY: 20, sp: 10,
            )
            let labels = shape.pieces.compactMap { piece -> String? in
                if case let .label(text, _) = piece { return text }
                return nil
            }
            #expect(labels == ["full"])
            #expect(shape.pieces.contains {
                if case .arrow(_, up: true) = $0 { true } else { false }
            })
            // Start anchor: x = noteWidth + 0.2 sp, y = -0.8 sp
            // (`TDraw::draw(const Bend*)`, `tdraw.cpp:957-959`).
            guard case let .curve(from, _, _, to) = shape.pieces.first else {
                Issue.record("first piece should be the up-curve")
                return
            }
            #expect(from == CGPoint(x: 11.8 + 2, y: -8))
            // Peak: x + 0.5 sp, y = -notePosY - 2 sp.
            #expect(to == CGPoint(x: 11.8 + 2 + 5, y: -40))
        }

        /// Prebend {(0,100),(60,100)}: a vertical riser with arrow + label,
        /// no curve.
        @Test("a prebend rises vertically before the note sounds")
        func prebendShape() {
            let shape = LegacyBendGeometry.shape(
                points: [
                    .init(time: 0, pitch: 100),
                    .init(time: 60, pitch: 100),
                ],
                noteWidth: 11.8, notePosY: 20, sp: 10,
            )
            guard case let .line(from, to) = shape.pieces.first else {
                Issue.record("first piece should be the riser")
                return
            }
            #expect(from.x == to.x)
            #expect(to.y == -40)
            #expect(shape.pieces.contains {
                if case .label("full", _) = $0 { true } else { false }
            })
            #expect(!shape.pieces.contains {
                if case .curve = $0 { true } else { false }
            })
        }

        /// Release {…,(30,0),(60,0)} inside bend-release: the down leg is a
        /// curve dropping 3 sp with a DOWN arrow and no label.
        @Test("a release drops with a down arrow and no label")
        func releaseHasDownArrowNoLabel() {
            let shape = LegacyBendGeometry.shape(
                points: [
                    .init(time: 0, pitch: 0),
                    .init(time: 10, pitch: 100),
                    .init(time: 20, pitch: 100),
                    .init(time: 30, pitch: 0),
                    .init(time: 60, pitch: 0),
                ],
                noteWidth: 11.8, notePosY: 20, sp: 10,
            )
            let downArrows = shape.pieces.filter {
                if case .arrow(_, up: false) = $0 { true } else { false }
            }.count
            let labels = shape.pieces.filter {
                if case .label = $0 { true } else { false }
            }.count
            #expect(downArrows == 1)
            #expect(labels == 1) // only the up leg labels
            // The held plateau between the two legs is a flat line, and the
            // down leg lands 3 sp below the peak.
            let flats = shape.pieces.filter {
                if case let .line(from, to) = $0 { from.y == to.y } else { false }
            }.count
            #expect(flats == 1)
            // The down leg is the LAST curve; its own arrow trails it.
            let downLeg = shape.pieces.last {
                if case .curve = $0 { true } else { false }
            }
            guard case let .curve(_, _, _, to) = downLeg else {
                Issue.record("there should be a down-curve")
                return
            }
            // Bound to a typed constant: an inline `-40 + 30` inside
            // `#expect` gets its literals defaulted to `Int`, which then
            // never compares equal to the `CGFloat`.
            let expectedDownY: CGFloat = -40 + 30
            #expect(to.y == expectedDownY)
        }

        @Test("the label table is indexed by (pitch + 12) / 25, clamped")
        func labelTable() {
            #expect(LegacyBendGeometry.label(forPitch: 25) == "1/4")
            #expect(LegacyBendGeometry.label(forPitch: 50) == "1/2")
            #expect(LegacyBendGeometry.label(forPitch: 100) == "full")
            #expect(LegacyBendGeometry.label(forPitch: 300) == "3")
            // Past the end of the table (the custom curve reaches 275, but
            // a hand-edited file can go further) yields no label rather
            // than trapping.
            #expect(LegacyBendGeometry.label(forPitch: 10000).isEmpty)
        }

        @Test("style constants are the MuseScore defaults")
        func styleConstants() {
            #expect(abs(LegacyBendGeometry.lineThicknessSp - 0.15) < 0.0001)
            #expect(abs(LegacyBendGeometry.arrowWidthSp - 0.5) < 0.0001)
        }

        @Test("translating a shape moves every point of every piece")
        func translateShiftsEveryPoint() {
            let shape = LegacyBendGeometry.shape(
                points: [
                    .init(time: 0, pitch: 100),
                    .init(time: 30, pitch: 0),
                    .init(time: 60, pitch: 0),
                ],
                noteWidth: 11.8, notePosY: 20, sp: 10,
            )
            let delta = CGPoint(x: 7, y: -3)
            let moved = shape.translated(by: delta)
            #expect(moved.pieces.count == shape.pieces.count)
            for (before, after) in zip(shape.pieces, moved.pieces) {
                #expect(Self.points(of: after)
                    == Self.points(of: before).map {
                        CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
                    })
            }
        }

        /// The `bend` text style is Edwin 8 normal (`styledef.cpp:1512-1516`)
        /// — the glissando row's size, without its italic.
        @Test("the bend text style is Edwin 8 normal")
        func bendTextStyle() {
            let defaults = TextStyleType.bend.museScoreDefault
            #expect(defaults.face == "Edwin")
            #expect(defaults.size == 8)
            #expect(defaults.style.isEmpty)
        }

        // MARK: - Helpers

        /// Every `.legacyBend` shape across all systems, in system order.
        private static func shapes(
            in document: LayoutDocument,
        ) -> [LegacyBendShape] {
            document.systems.flatMap { system in
                system.spanners.compactMap { element in
                    guard case let .legacyBend(shape) = element else {
                        return nil
                    }
                    return shape
                }
            }
        }

        private static func points(
            of piece: LegacyBendShape.Piece,
        ) -> [CGPoint] {
            switch piece {
            case let .line(from, to):
                return [from, to]
            case let .curve(from, c1, c2, to):
                return [from, c1, c2, to]
            case let .arrow(tip, _):
                return [tip]
            case let .label(_, anchor):
                return [anchor]
            }
        }

        /// SYSTEM-local origin of the first laid-out note, matching the
        /// frame spanners use.
        private static func firstNoteOrigin(
            in document: LayoutDocument,
        ) -> CGPoint? {
            guard let system = document.systems.first else { return nil }
            for measure in system.measures {
                for element in measure.elements {
                    guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _)
                        = element, let note = notes.first
                    else { continue }
                    return CGPoint(
                        x: measure.origin.x + note.origin.x,
                        y: measure.origin.y + note.origin.y,
                    )
                }
            }
            return nil
        }

        /// One whole-note chord carrying `points` as its legacy bend
        /// (or no bend at all when `points` is nil).
        private static func singleBendDocument(
            points: [LegacyBend.Point]?,
        ) -> LayoutDocument {
            let note = Note(
                pitch: 62, tpc: 16,
                legacyBend: points.map { LegacyBend(points: $0) },
            )
            let measure = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [note])),
            ])])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [measure])],
                )],
            )
            return LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
        }
    }
#endif
