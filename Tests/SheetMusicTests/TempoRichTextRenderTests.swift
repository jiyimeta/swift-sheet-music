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

    /// Both Apple renderers draw a tempo marking from the runs layout typeset, where layout measured them.
    @Suite("Tempo text reaches the Apple renderers", .serialized)
    @MainActor
    struct TempoRichTextRenderTests {
        private let _installApple = TestSupport.installApple
        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        private static func score(_ tempo: Tempo) -> Score {
            var score = EditingFixtures.fourQuarterRests()
            score.systemMeasures = [SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(tempo), originalStaff: staff),
            ])]
            return score
        }

        @available(macOS 15.0, *)
        private static func tempoElement(_ score: Score) throws -> (element: LayoutElement, metrics: StaffMetrics) {
            _ = BravuraFont.register
            let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 1200)
            let tempos = document.systems.flatMap(\.measures).flatMap(\.elements).filter { element in
                if case .textMark(.tempo, _, _, .some) = element { true } else { false }
            }
            let element = try #require(tempos.first)
            return (element, document.metrics)
        }

        /// The three markings the ink test draws: derived quarter, derived dotted quarter, MuseScore 3 legacy text.
        @available(macOS 15.0, *)
        private static func marking(_ index: Int) throws -> (element: LayoutElement, metrics: StaffMetrics) {
            switch index {
            case 0:
                return try tempoElement(score(Tempo(beatsPerSecond: 2)))
            case 1:
                return try tempoElement(score(Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1)))
            default:
                return try tempoElement(MSCXParser.parse(MSCXFixtureLoader.mscxData("testVoltaTemp")))
            }
        }

        /// What `drawElement` puts on a layer for `element` at `base: .zero`, as the Y-down box of its filled layers.
        @available(macOS 15.0, *)
        private static func drawnBox(_ element: LayoutElement, metrics: StaffMetrics) throws -> CGRect {
            let height: CGFloat = 2000
            let parent = CALayer()
            var context = ScoreLayerBuilder.BuildContext()
            ScoreLayerBuilder.drawElement(
                element, base: .zero, metrics: metrics, height: height, context: &context, into: parent,
            )
            let box = (parent.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                .filter { $0.fillColor != nil }
                .compactMap { $0.path?.boundingBoxOfPath }
                .reduce(CGRect.null) { $0.union($1) }
            try #require(!box.isNull)
            return CGRect(x: box.minX, y: height - box.maxY, width: box.width, height: box.height)
        }

        @available(macOS 15.0, *)
        @Test("the CALayer marking is drawn where layout measured its ink", arguments: [0, 1, 2])
        func layerMatchesInk(index: Int) throws {
            let found = try Self.marking(index)
            let ink = try #require(TextInkGeometry.rects(for: found.element, metrics: found.metrics)?.first)
            let drawn = try Self.drawnBox(found.element, metrics: found.metrics)
            #expect(abs(drawn.minX - ink.minX) < 0.5)
            #expect(abs(drawn.minY - ink.minY) < 0.5)
            #expect(abs(drawn.width - ink.width) < 0.5)
            #expect(abs(drawn.height - ink.height) < 0.5)
        }

        @available(macOS 15.0, *)
        @Test("the Canvas marking draws the glyph and the number, as wide as layout measured them")
        func canvasDrawsRuns() throws {
            let found = try Self.tempoElement(Self.score(Tempo(beatsPerSecond: 2)))
            let ink = try #require(TextInkGeometry.rects(for: found.element, metrics: found.metrics)?.first)
            let metrics = found.metrics
            let element = found.element
            let view = Canvas { context, _ in
                ScoreCanvasDrawing.drawElement(element, base: CGPoint(x: 150, y: 180), metrics: metrics, into: &context)
            }
            .frame(width: 700, height: 320)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let width = try Self.inkWidth(#require(renderer.cgImage))
            #expect(abs(CGFloat(width) - ink.width) < 3)
        }

        /// The width of the non-white pixels of `image`, composited on white.
        private static func inkWidth(_ image: CGImage) throws -> Int {
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
            var minX = width
            var maxX = -1
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let offset = (y * width + x) * 4
                    guard bytes[offset] < 200 || bytes[offset + 1] < 200 || bytes[offset + 2] < 200 else { continue }
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
            return maxX >= minX ? maxX - minX + 1 : 0
        }
    }
#endif
