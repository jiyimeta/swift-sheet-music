#if os(macOS)
    import CoreGraphics
    import QuartzCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import SwiftUI
    import Testing

    /// Both Apple renderers draw a gradual tempo line: the label's runs, then a dashed line at MuseScore's pattern from
    /// just after it.
    @Suite("Gradual tempo line reaches the Apple renderers", .serialized)
    @MainActor
    struct GradualTempoLineRenderTests {
        private let _installApple = TestSupport.installApple
        private static let metrics = StaffMetrics(staffSize: 20)
        private static let from = CGPoint(x: 20, y: 50)
        private static let to = CGPoint(x: 220, y: 50)

        private static func segment() throws -> (element: LayoutElement, label: LayoutRichText) {
            let label = try #require(LayoutRichText.gradualTempoChangeLabel("rit.", metrics: metrics))
            let element = LayoutElement.spannerSegment(
                kind: .gradualTempoChange, fromOrigin: from, toOrigin: to, continuesLeft: false,
                continuesRight: false, text: "rit.", anchor: nil, richText: label,
            )
            return (element, label)
        }

        @available(macOS 15.0, *)
        @Test("the CALayer line is dashed at MuseScore's pattern, after a filled label")
        func layerDrawsDashedLineAndLabel() throws {
            let (element, label) = try Self.segment()
            let parent = CALayer()
            var context = ScoreLayerBuilder.BuildContext()
            ScoreLayerBuilder.drawElement(
                element, base: .zero, metrics: Self.metrics, height: 400, context: &context, into: parent,
            )
            let shapes = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
            let line = try #require(shapes.first { $0.lineDashPattern != nil })
            #expect(line.lineDashPattern?.map(\.doubleValue)
                == [Double(Self.metrics.sp * 0.9), Double(Self.metrics.sp * 1.35)])
            #expect(abs(line.lineWidth - Self.metrics.sp * 0.15) < 1e-9)
            let lineBox = try #require(line.path?.boundingBoxOfPath)
            let parts = SpannerGeometry.gradualTempoChange(
                from: Self.from, to: Self.to, label: label, sp: Self.metrics.sp,
            )
            #expect(abs(lineBox.minX - parts.lineStart.x) < 0.01)
            #expect(shapes.contains { $0.fillColor != nil })
        }

        @available(macOS 15.0, *)
        @Test("the Canvas draws the label and the line across the whole span")
        func canvasDrawsLabelAndLine() throws {
            let (element, _) = try Self.segment()
            let metrics = Self.metrics
            let view = Canvas { context, _ in
                ScoreCanvasDrawing.drawElement(element, base: .zero, metrics: metrics, into: &context)
            }
            .frame(width: 300, height: 120)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let context = try #require(CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
            var inked: [Int] = []
            for y in 0 ..< image.height {
                for x in 0 ..< image.width where bytes[(y * image.width + x) * 4] < 200 {
                    inked.append(x)
                }
            }
            let minX = try #require(inked.min())
            let maxX = try #require(inked.max())
            #expect(minX <= 22)
            #expect(maxX >= 210)
        }
    }
#endif
