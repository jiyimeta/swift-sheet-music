#if os(macOS)
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// The Apple figure helper's paths: shared by the layer tree and the Canvas, so their agreement with layout is
    /// tested once, here.
    @Suite("Figure renderer")
    struct FigureRenderTests {
        private let _installApple = TestSupport.installApple

        @available(macOS 15.0, *)
        @Test("a filled ellipse is a fill path of its rect; a line is a stroke of its width")
        func shapes() throws {
            let figure = LayoutFigure(primitives: [
                .ellipse(rect: CGRect(x: 10, y: 20, width: 6, height: 6), fill: true, width: 0),
                .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 30, y: 0), width: 1.5, cap: .round),
            ])
            let parts = FigureRenderer.parts(for: figure)
            let fill = try #require(parts.fill)
            #expect(abs(fill.boundingBox.minX - 10) < 0.01 && abs(fill.boundingBox.width - 6) < 0.01)
            let stroke = try #require(parts.strokes.first)
            #expect(stroke.width == 1.5 && stroke.roundCaps)
            #expect(abs(stroke.path.boundingBox.width - 30) < 0.01)
        }

        @available(macOS 15.0, *)
        @Test("a glyph turned a quarter turn about its center swaps its extents")
        func rotatedGlyph() throws {
            let run = LayoutRichTextPositionedRun(
                content: .symbol(codepoint: SMuFLCodepoint.byName("ornamentTrill") ?? 0xE566),
                font: LayoutFont(face: SMuFLFamily.bravura, pointSize: 40), baseline: CGPoint(x: 50, y: 50),
            )
            let upright = LayoutFigure(primitives: [.run(run, rotation: 0, pivot: .zero)])
            let plain = try #require(FigureRenderer.parts(for: upright).fill)
            let center = CGPoint(x: plain.boundingBox.midX, y: plain.boundingBox.midY)
            let turned = try #require(FigureRenderer.parts(for: LayoutFigure(primitives: [
                .run(run, rotation: .pi / 2, pivot: center),
            ])).fill)
            #expect(abs(turned.boundingBox.width - plain.boundingBox.height) < 0.5)
            #expect(abs(turned.boundingBox.height - plain.boundingBox.width) < 0.5)
            #expect(abs(turned.boundingBox.midX - center.x) < 0.5)
        }

        /// The renderer turns the same way layout measures: clockwise on screen for a positive angle.
        @available(macOS 15.0, *)
        @Test("a positive rotation swings a glyph right of its pivot down, as layout's ink does")
        func rotationDirectionMatchesLayout() throws {
            let run = LayoutRichTextPositionedRun(
                content: .symbol(codepoint: SMuFLCodepoint.byName("ornamentTrill") ?? 0xE566),
                font: LayoutFont(face: SMuFLFamily.bravura, pointSize: 28), baseline: CGPoint(x: 100, y: 50),
            )
            let figure = LayoutFigure(primitives: [.run(run, rotation: 0.3, pivot: CGPoint(x: 0, y: 50))])
            let plain = try #require(FigureRenderer.parts(for: LayoutFigure(primitives: [
                .run(run, rotation: 0, pivot: .zero),
            ])).fill)
            let turned = try #require(FigureRenderer.parts(for: figure).fill)
            #expect(turned.boundingBox.midY > plain.boundingBox.midY + 20)
            #expect(abs(turned.boundingBox.midY - figure.ink.midY) < 1)
        }
    }
#endif
