#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    @testable import SheetMusicBridgeCore
    import SheetMusicLayout
    import Testing

    /// `LayoutBridge.encodeGuitarBend` feeds the Android painter, so no
    /// Apple-side visual check can see it. Its one subtlety — that a
    /// slight bend's FIRST cubic control point is the start anchor, not
    /// the vertex (`GuitarBendLayout::layoutSlightBend`'s
    /// `path.cubicTo(PointF(0, 0), curve, pos2())`,
    /// `rendering/score/guitarbendlayout.cpp:379-381`) — stays invisible
    /// until the hook curves the wrong way on a device. Pin it directly.
    ///
    /// `GuitarBendRenderer` and `ScoreLayerBuilder.drawGuitarBend` build
    /// the same two shapes on Apple and are verified visually on the Mac
    /// example.
    struct LayoutBridgeGuitarBendTests {
        /// Points → document mm, the same factor `LayoutBridge` applies.
        private static let mm = 25.4 / 72.0

        private static let sp = 8.0

        private static func commands(slight: Bool) -> [DrawCommand] {
            var out: [DrawCommand] = []
            LayoutBridge.encodeGuitarBend(
                fromXPt: 10, fromYPt: 20,
                vertexXPt: 15, vertexYPt: 12,
                toXPt: 20, toYPt: 16,
                slight: slight,
                spPt: sp,
                into: &out,
            )
            return out
        }

        private static func isClose(_ lhs: Double, _ rhs: Double) -> Bool {
            abs(lhs - rhs) < 1e-9
        }

        private static func strokeWidth(_ command: DrawCommand) -> Double? {
            if case let .stroke(width) = command { return width }
            return nil
        }

        @Test("angular bend is a two-segment polyline from → vertex → to")
        func angularBendEmitsPolyline() throws {
            let out = Self.commands(slight: false)
            try #require(out.count == 4)
            #expect(out[0] == .moveTo(x: 10 * Self.mm, y: 20 * Self.mm))
            #expect(out[1] == .lineTo(x: 15 * Self.mm, y: 12 * Self.mm))
            #expect(out[2] == .lineTo(x: 20 * Self.mm, y: 16 * Self.mm))
            let width = try #require(Self.strokeWidth(out[3]))
            let expected = Self.sp
                * Double(GuitarBendGeometry.lineThicknessSp) * Self.mm
            #expect(Self.isClose(width, expected))
        }

        @Test("slight bend's first cubic control point is the start anchor")
        func slightBendEmitsCubicAnchoredAtStart() throws {
            let out = Self.commands(slight: true)
            try #require(out.count == 3)
            #expect(out[0] == .moveTo(x: 10 * Self.mm, y: 20 * Self.mm))
            #expect(out[1] == .cubicTo(
                cx1: 10 * Self.mm, cy1: 20 * Self.mm,
                cx2: 15 * Self.mm, cy2: 12 * Self.mm,
                x: 20 * Self.mm, y: 16 * Self.mm,
            ))
            #expect(Self.strokeWidth(out[2]) != nil)
        }
    }
#endif
