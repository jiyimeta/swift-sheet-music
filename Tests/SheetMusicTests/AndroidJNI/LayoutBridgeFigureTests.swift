#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// A figure reaches the draw program with the opcodes it already has.
    @Suite("LayoutBridge figure")
    struct LayoutBridgeFigureTests {
        private let _installApple = TestSupport.installApple
        private static let mm = LayoutBridge.ptToMMScale

        private static func encode(_ primitives: [LayoutFigure.Primitive], color: ScoreColor? = nil) -> [DrawCommand] {
            var out: [DrawCommand] = []
            LayoutBridge.encodeFigure(LayoutFigure(primitives: primitives), color: color, into: &out)
            return out
        }

        @Test("a flat line is moveTo, lineTo, stroke; a round-capped one adds a filled disc at each end")
        func lines() {
            let flat = Self.encode([.line(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 11, y: 2), width: 0.5, cap: .flat)])
            #expect(flat == [
                .moveTo(x: 1 * Self.mm, y: 2 * Self.mm), .lineTo(x: 11 * Self.mm, y: 2 * Self.mm),
                .stroke(width: 0.5 * Self.mm),
            ])
            let across = [LayoutFigure.Primitive.line(
                from: CGPoint(x: 1, y: 2), to: CGPoint(x: 11, y: 2), width: 0.5, cap: .round,
            )]
            let round = Self.encode(across)
            #expect(round.filter { $0 == .fillPath }.count == 2)
            #expect(round.filter { if case .cubicTo = $0 { true } else { false } }.count == 8)
        }

        @Test("an ellipse is four curves, filled or stroked; an outline rect closes on its start")
        func ellipses() {
            let rect = CGRect(x: 0, y: 0, width: 4, height: 4)
            let filled = Self.encode([.ellipse(rect: rect, fill: true, width: 0)])
            #expect(filled.filter { if case .cubicTo = $0 { true } else { false } }.count == 4)
            #expect(filled.last == .fillPath)
            let stroked = Self.encode([.ellipse(rect: rect, fill: false, width: 0.3)])
            #expect(stroked.last == .stroke(width: 0.3 * Self.mm))
            let outline = Self.encode([.rectOutline(rect: rect, width: 0.2)])
            #expect(outline.first == .moveTo(x: 0, y: 0))
            #expect(outline.dropLast().last == .lineTo(x: 0, y: 0))
        }

        @Test("a turned glyph is bracketed by setRotation about its pivot; color is set and restored")
        func runsAndColor() throws {
            let run = LayoutRichTextPositionedRun(
                content: .symbol(codepoint: 0xE566), font: LayoutFont(face: SMuFLFamily.bravura, pointSize: 28),
                baseline: CGPoint(x: 10, y: 20),
            )
            let red = ScoreColor(red: 255, green: 0, blue: 0)
            let turned = [LayoutFigure.Primitive.run(run, rotation: 0.3, pivot: CGPoint(x: 12, y: 18))]
            let out = Self.encode(turned, color: red)
            let rotation = try #require(out.firstIndex { if case .setRotation = $0 { true } else { false } })
            let glyph = try #require(out.firstIndex { if case .glyph = $0 { true } else { false } })
            #expect(rotation < glyph)
            #expect(out[rotation] == .setRotation(radians: 0.3, pivotX: 12 * Self.mm, pivotY: 18 * Self.mm))
            #expect(out.contains(.setRotation(radians: 0, pivotX: 0, pivotY: 0)))
            #expect(out.first == .setColor(argb: 0xFFFF_0000))
            #expect(out.last == .setColor(argb: 0xFF00_0000))
        }
    }
#endif
