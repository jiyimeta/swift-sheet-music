#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicLayout
    import Testing

    /// `LayoutBridge.encodeLegacyBend` feeds the Android painter, so the
    /// Mac example can't see it. Two things it does are invisible until a
    /// device draws them wrong: the outline is ONE stroked path (a
    /// `moveTo` only where the pieces stop being contiguous), and the
    /// arrowheads — filled polygons in `TDraw::draw(const Bend*)` — have
    /// to come out as closed stroked triangles because `DrawCommand` has
    /// no fill-polygon opcode. Pin both, plus the label text command.
    struct LayoutBridgeLegacyBendTests {
        /// Points → document mm, the same factor `LayoutBridge` applies.
        private static let mm = 25.4 / 72.0

        private static let sp = 8.0

        private static func commands(
            _ pieces: [LegacyBendShape.Piece],
        ) -> [DrawCommand] {
            var out: [DrawCommand] = []
            LayoutBridge.encodeLegacyBend(
                shape: LegacyBendShape(pieces: pieces),
                spPt: sp,
                into: &out,
            )
            return out
        }

        private static func isClose(_ lhs: Double, _ rhs: Double) -> Bool {
            abs(lhs - rhs) < 1e-9
        }

        private static var lineWidthMM: Double {
            sp * Double(LegacyBendGeometry.lineThicknessSp) * mm
        }

        private static var arrowWidth: Double {
            sp * Double(LegacyBendGeometry.arrowWidthSp)
        }

        @Test("line, up-arrow and label lower to path + triangle + text")
        func lineArrowAndLabelLower() throws {
            let out = Self.commands([
                .line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 10, y: -4)),
                .arrow(tip: CGPoint(x: 10, y: -4), up: true),
                .label(text: "full", anchor: CGPoint(x: 10, y: -4)),
            ])
            try #require(out.count == 9)
            // Outline: one subpath, one stroke at the bend line width.
            #expect(out[0] == .moveTo(x: 10 * Self.mm, y: 20 * Self.mm))
            #expect(out[1] == .lineTo(x: 10 * Self.mm, y: -4 * Self.mm))
            guard case let .stroke(outlineWidth) = out[2] else {
                Issue.record("expected a stroke after the outline")
                return
            }
            #expect(Self.isClose(outlineWidth, Self.lineWidthMM))

            // Arrowhead: CLOSED stroked triangle (tip → base → base → tip).
            let aw = Self.arrowWidth
            #expect(out[3] == .moveTo(x: 10 * Self.mm, y: -4 * Self.mm))
            #expect(out[4] == .lineTo(
                x: (10 + aw / 2) * Self.mm, y: (-4 + aw) * Self.mm,
            ))
            #expect(out[5] == .lineTo(
                x: (10 - aw / 2) * Self.mm, y: (-4 + aw) * Self.mm,
            ))
            #expect(out[6] == .lineTo(x: 10 * Self.mm, y: -4 * Self.mm))
            guard case let .stroke(arrowWidthMM) = out[7] else {
                Issue.record("expected a stroke closing the arrowhead")
                return
            }
            #expect(Self.isClose(arrowWidthMM, Self.lineWidthMM))

            // Label: Edwin 8 pt, centered on the tip with its bottom on it.
            let fontSize = TextRoleStyle.fontSize(
                for: .bend, sp: CGFloat(Self.sp),
            )
            let font = LayoutFont(face: "Edwin", pointSize: fontSize)
            let width = FontMetrics.provider.typographicWidth(
                text: "full", font: font,
            )
            let descent = FontMetrics.provider.descent(font: font)
            #expect(out[8] == .text(
                text: "full",
                x: Double(10 - width / 2) * Self.mm,
                y: Double(-4 - descent) * Self.mm,
                size: Double(fontSize) * Self.mm,
                fontId: .textRoman,
            ))
        }

        @Test("down-arrow base sits above the tip")
        func downArrowBaseAboveTip() throws {
            let out = Self.commands([
                .arrow(tip: CGPoint(x: 4, y: 6), up: false),
            ])
            try #require(out.count == 5)
            let aw = Self.arrowWidth
            #expect(out[0] == .moveTo(x: 4 * Self.mm, y: 6 * Self.mm))
            #expect(out[1] == .lineTo(
                x: (4 + aw / 2) * Self.mm, y: (6 - aw) * Self.mm,
            ))
            #expect(out[2] == .lineTo(
                x: (4 - aw / 2) * Self.mm, y: (6 - aw) * Self.mm,
            ))
            #expect(out[3] == .lineTo(x: 4 * Self.mm, y: 6 * Self.mm))
        }

        /// The geometry emits legs contiguously, so the running path must
        /// NOT restate a `moveTo` between them — that would draw a
        /// phantom connector on Apple and, worse, throw the leg away on
        /// Android. A piece that genuinely starts elsewhere does need one,
        /// and it has to be preceded by its own `stroke`: the Compose
        /// painter resets the open path on every `moveTo`
        /// (`ScoreCanvas.kt`: `if (strokeStarted) path.reset()`), so an
        /// unflushed first subpath would vanish instead of being drawn.
        @Test("a discontinuity strokes the open subpath before moving")
        func outlineIsOneRunningPath() throws {
            let out = Self.commands([
                .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 4, y: 0)),
                .curve(
                    from: CGPoint(x: 4, y: 0),
                    control1: CGPoint(x: 6, y: 0),
                    control2: CGPoint(x: 8, y: -2),
                    to: CGPoint(x: 8, y: -8),
                ),
                // Detached: starts nowhere near the previous end point.
                .line(from: CGPoint(x: 20, y: -8), to: CGPoint(x: 24, y: -8)),
            ])
            try #require(out.count == 7)
            #expect(out[0] == .moveTo(x: 0, y: 0))
            #expect(out[1] == .lineTo(x: 4 * Self.mm, y: 0))
            #expect(out[2] == .cubicTo(
                cx1: 6 * Self.mm, cy1: 0,
                cx2: 8 * Self.mm, cy2: -2 * Self.mm,
                x: 8 * Self.mm, y: -8 * Self.mm,
            ))
            // The break flushes the first subpath BEFORE moving away.
            guard case let .stroke(firstWidth) = out[3] else {
                Issue.record("the open subpath is stroked before the moveTo")
                return
            }
            #expect(Self.isClose(firstWidth, Self.lineWidthMM))
            #expect(out[4] == .moveTo(x: 20 * Self.mm, y: -8 * Self.mm))
            #expect(out[5] == .lineTo(x: 24 * Self.mm, y: -8 * Self.mm))
            guard case .stroke = out[6] else {
                Issue.record("the trailing subpath takes its own stroke")
                return
            }
        }

        /// The contract the real geometry relies on: contiguous pieces
        /// stay ONE `moveTo` and ONE `stroke`, so the flush added for
        /// discontinuities cannot leak an extra stroke into normal bends.
        @Test("contiguous legs stay a single moveTo and a single stroke")
        func contiguousOutlineTakesOneStroke() throws {
            let out = Self.commands([
                .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 4, y: 0)),
                .curve(
                    from: CGPoint(x: 4, y: 0),
                    control1: CGPoint(x: 6, y: 0),
                    control2: CGPoint(x: 8, y: -2),
                    to: CGPoint(x: 8, y: -8),
                ),
                .line(from: CGPoint(x: 8, y: -8), to: CGPoint(x: 12, y: -8)),
            ])
            try #require(out.count == 5)
            let moveCount = out.filter { if case .moveTo = $0 { true } else { false } }
            let strokeCount = out.filter { if case .stroke = $0 { true } else { false } }
            #expect(moveCount.count == 1)
            #expect(strokeCount.count == 1)
            guard case .stroke = out[4] else {
                Issue.record("the single stroke comes last")
                return
            }
        }

        @Test("an empty label emits no text command")
        func emptyLabelIsSkipped() {
            let out = Self.commands([
                .label(text: "", anchor: CGPoint(x: 1, y: 2)),
            ])
            #expect(out.isEmpty)
        }
    }
#endif
