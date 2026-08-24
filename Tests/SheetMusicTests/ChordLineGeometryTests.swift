#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// Geometry for the jazz/brass inflection lines, ported from
    /// `TLayout::layoutChordLine` + `TDraw::draw(const ChordLine*, …)`.
    @Suite("ChordLine geometry")
    struct ChordLineGeometryTests {
        static let sp: CGFloat = 10

        // MARK: - Default path

        /// C++: `x2 += isToTheLeft ? -horBaseLength : horBaseLength` with
        /// `horBaseLength = 1.2 * spatium * mag`, and
        /// `y2 += isBelow ? baseLength : -baseLength`.
        @Test("default path end point follows the side predicates")
        func defaultPathEndPoint() {
            let expected: [(ChordLine.Kind, CGPoint)] = [
                // fall: to the right, below.
                (.fall, CGPoint(x: 12, y: 10)),
                // doit: to the right, above.
                (.doit, CGPoint(x: 12, y: -10)),
                // plop: to the left, above.
                (.plop, CGPoint(x: -12, y: -10)),
                // scoop: to the left, below.
                (.scoop, CGPoint(x: -12, y: 10)),
            ]
            for (kind, end) in expected {
                let segments = ChordLineGeometry.defaultPath(
                    for: ChordLine(kind: kind), sp: Self.sp,
                )
                #expect(segments.first == .move(to: .zero))
                guard case let .curve(_, _, to) = segments.last else {
                    Issue.record("expected a curve for \(kind)")
                    continue
                }
                #expect(to == end)
            }
        }

        @Test("straight variants emit one line segment, not a curve")
        func straightPathIsALine() {
            let segments = ChordLineGeometry.defaultPath(
                for: ChordLine(kind: .fall, isStraight: true), sp: Self.sp,
            )
            #expect(segments == [
                .move(to: .zero),
                .line(to: CGPoint(x: 12, y: 10)),
            ])
        }

        /// Upstream picks different control points depending on the side:
        /// a right-going curve leaves the notehead horizontally, a
        /// left-going one arrives vertically.
        @Test("curved control points mirror the isToTheLeft branch")
        func curvedControlPoints() {
            let right = ChordLineGeometry.defaultPath(
                for: ChordLine(kind: .fall), sp: Self.sp,
            )
            #expect(right.last == .curve(
                control1: CGPoint(x: 6, y: 0),
                control2: CGPoint(x: 12, y: 5),
                to: CGPoint(x: 12, y: 10),
            ))

            let left = ChordLineGeometry.defaultPath(
                for: ChordLine(kind: .scoop), sp: Self.sp,
            )
            #expect(left.last == .curve(
                control1: CGPoint(x: 0, y: 5),
                control2: CGPoint(x: -6, y: 10),
                to: CGPoint(x: -12, y: 10),
            ))
        }

        @Test("mag scales the generated path")
        func magScalesPath() {
            let segments = ChordLineGeometry.defaultPath(
                for: ChordLine(kind: .doit), sp: Self.sp, mag: 0.5,
            )
            guard case let .curve(_, _, to) = segments.last else {
                Issue.record("expected a curve"); return
            }
            #expect(to == CGPoint(x: 6, y: -5))
        }

        /// `lengthX` / `lengthY` are drag-edit accumulators upstream
        /// (`ChordLine::dragGrip`); `layoutChordLine` never reads them, so
        /// the generated path must ignore them too.
        @Test("lengthX / lengthY do not affect the generated path")
        func lengthsDoNotAffectDefaultPath() {
            let plain = ChordLineGeometry.defaultPath(
                for: ChordLine(kind: .fall), sp: Self.sp,
            )
            let dragged = ChordLineGeometry.defaultPath(
                for: ChordLine(kind: .fall, lengthX: 3, lengthY: -4),
                sp: Self.sp,
            )
            #expect(plain == dragged)
        }

        // MARK: - User path

        /// The `<Path>` element stream is a state machine: a `curveTo`
        /// carries control point 1, and the two `curveToData` entries that
        /// follow carry control point 2 and the end point.
        @Test("user path reassembles cubic segments and scales by spatium")
        func userPathReassemblesCubics() {
            let elements: [ChordLine.PathElement] = [
                .init(kind: .moveTo, x: 0, y: 0),
                .init(kind: .curveTo, x: 0.6, y: 0),
                .init(kind: .curveToData, x: 1.2, y: 0.5),
                .init(kind: .curveToData, x: 1.2, y: 1),
            ]
            let segments = ChordLineGeometry.userPath(elements, sp: Self.sp)
            #expect(segments == [
                .move(to: .zero),
                .curve(
                    control1: CGPoint(x: 6, y: 0),
                    control2: CGPoint(x: 12, y: 5),
                    to: CGPoint(x: 12, y: 10),
                ),
            ])
        }

        @Test("user path handles a straight line element")
        func userPathLine() {
            let segments = ChordLineGeometry.userPath([
                .init(kind: .moveTo, x: 0, y: 0),
                .init(kind: .lineTo, x: -1.2, y: -1),
            ], sp: Self.sp)
            #expect(segments == [
                .move(to: .zero), .line(to: CGPoint(x: -12, y: -10)),
            ])
        }

        /// A cubic missing its final data element can't be drawn; dropping
        /// it beats emitting a curve to a guessed point.
        @Test("truncated trailing cubic is dropped")
        func userPathTruncatedCubic() {
            let segments = ChordLineGeometry.userPath([
                .init(kind: .moveTo, x: 0, y: 0),
                .init(kind: .curveTo, x: 0.6, y: 0),
                .init(kind: .curveToData, x: 1.2, y: 0.5),
            ], sp: Self.sp)
            #expect(segments == [.move(to: .zero)])
        }

        // MARK: - Wave glyph

        /// C++: `ChordLine::waveSym` — fall and plop get the rough fall,
        /// doit and scoop the lift.
        @Test("wave glyph and rotation match waveSym / TDraw")
        func waveGlyphMapping() {
            #expect(
                ChordLineGeometry.waveCodepoint(kind: .fall)
                    == SMuFLCodepoint.brassFallRoughShort,
            )
            #expect(
                ChordLineGeometry.waveCodepoint(kind: .plop)
                    == SMuFLCodepoint.brassFallRoughShort,
            )
            #expect(
                ChordLineGeometry.waveCodepoint(kind: .doit)
                    == SMuFLCodepoint.brassLiftShort,
            )
            #expect(
                ChordLineGeometry.waveCodepoint(kind: .scoop)
                    == SMuFLCodepoint.brassLiftShort,
            )

            #expect(ChordLineGeometry.waveRotationDegrees(kind: .fall) == 1)
            for kind in [ChordLine.Kind.doit, .plop, .scoop] {
                #expect(ChordLineGeometry.waveRotationDegrees(kind: kind) == -1)
            }
        }

        // MARK: - Bounding box

        @Test("bounding box spans the origin and every control point")
        func boundingBoxCoversPath() {
            let box = ChordLineGeometry.boundingBox(
                of: ChordLineGeometry
                    .defaultPath(for: ChordLine(kind: .fall), sp: Self.sp),
            )
            #expect(box.minX == 0)
            #expect(box.maxX == 12)
            #expect(box.minY == 0)
            #expect(box.maxY == 10)
        }

        @Test("thickness mirrors Sid::chordlineThickness")
        func thickness() {
            #expect(ChordLineGeometry.thickness(sp: Self.sp) == 1.6)
            #expect(ChordLineGeometry.thickness(sp: Self.sp, mag: 0.5) == 0.8)
        }
    }
#endif
