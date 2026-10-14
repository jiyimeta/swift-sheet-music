#if os(macOS)
    import CoreGraphics
    import QuartzCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import SwiftUI
    import Testing

    /// Both Apple renderers paint a marker or jump in its author `<color>` — the fixture's D.S. al Coda is r 200, g 0,
    /// b 0.
    @Suite("Navigation colors reach the Apple renderers", .serialized)
    @MainActor
    struct NavigationColorRenderTests {
        private let _installApple = TestSupport.installApple
        private static let red = ScoreColor(red: 200, green: 0, blue: 0)

        @available(macOS 15.0, *)
        private static func coloredJump() throws -> (element: LayoutElement, metrics: StaffMetrics) {
            _ = BravuraFont.register
            let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("marker-properties"))
            let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 2000)
            let jump = try #require(document.systems.flatMap(\.measures).flatMap(\.jumps).first)
            return (jump, document.metrics)
        }

        @available(macOS 15.0, *)
        @Test("the CALayer paints a jump in its author color")
        func layerTakesTheColor() throws {
            let found = try Self.coloredJump()
            let parent = CALayer()
            var context = ScoreLayerBuilder.BuildContext()
            ScoreLayerBuilder.drawElement(
                found.element, base: .zero, metrics: found.metrics, height: 400, context: &context, into: parent,
            )
            let layer = try #require(parent.sublayers?.last as? CAShapeLayer)
            #expect(layer.fillColor == ScoreLayerBuilder.scoreColorToCGColor(Self.red))
        }

        @available(macOS 15.0, *)
        @Test("the Canvas paints a jump in its author color")
        func canvasTakesTheColor() throws {
            let found = try Self.coloredJump()
            let view = Canvas { context, _ in
                ScoreCanvasDrawing.drawElement(
                    found.element, base: CGPoint(x: 150, y: 180), metrics: found.metrics, into: &context,
                )
            }
            .frame(width: 900, height: 400)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(try Self.redPixels(image) > 0)
        }

        /// Pixels clearly red — the author color, not black ink or its antialiased grey.
        private static func redPixels(_ image: CGImage) throws -> Int {
            let width = image.width
            let height = image.height
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
            var count = 0
            for index in 0 ..< width * height
                where bytes[index * 4] > 150 && bytes[index * 4 + 1] < 90 && bytes[index * 4 + 2] < 90
            {
                count += 1
            }
            return count
        }
    }
#endif
