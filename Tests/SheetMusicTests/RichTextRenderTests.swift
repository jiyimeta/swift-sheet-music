#if os(macOS)
    import CoreGraphics
    import QuartzCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import SwiftUI
    import Testing

    /// Both Apple renderers draw a formatted text from the runs layout placed, so a symbol inside a staff text is a
    /// glyph on the page and the drawn ink is where layout measured it.
    @Suite("Rich text reaches the Apple renderers", .serialized)
    @MainActor
    struct RichTextRenderTests {
        private let _installApple = TestSupport.installApple

        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        /// "senza " and the keyboard-pedal glyph — what a plain renderer cannot draw at all.
        private static let senzaPed = StaffText(
            text: "senza ",
            preservedTextMarkup: PreservedTextMarkup(
                content: [
                    .characters("senza "),
                    .element(.init(name: "sym", content: [.characters("keyboardPedalPed")])),
                ],
                derivedText: "senza ",
            ),
        )

        private static func score(_ text: StaffText) -> Score {
            let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
            return Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
            )], systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .staffText(text), originalStaff: staff),
            ])])
        }

        @available(macOS 15.0, *)
        private static func document(_ text: StaffText) -> LayoutDocument {
            _ = BravuraFont.register
            return LayoutEngine.layout(score: score(text), options: ScoreViewOptions(), availableWidth: 800)
        }

        private static func staffText(in document: LayoutDocument) throws -> LayoutElement {
            try #require(document.systems.flatMap(\.measures).flatMap(\.elements).first { element in
                if case .staffText = element { true } else { false }
            })
        }

        @available(macOS 15.0, *)
        private static func layerWidth(_ document: LayoutDocument) throws -> CGFloat {
            let system = try #require(document.systems.first)
            let item = try #require(staffText(in: document).textItemID)
            let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: document.metrics)
            let layers = try #require(built.items[item])
            return layers.compactMap { $0.path?.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }.width
        }

        @available(macOS 15.0, *)
        @Test("the CALayer staff text draws the symbol run, where layout measured the ink")
        func layerDrawsRuns() throws {
            let rich = Self.document(Self.senzaPed)
            let richWidth = try Self.layerWidth(rich)
            #expect(try richWidth > Self.layerWidth(Self.document(StaffText(text: "senza "))) + 4)
            let ink = try #require(TextInkGeometry.rects(for: Self.staffText(in: rich), metrics: rich.metrics)?.first)
            #expect(abs(richWidth - ink.width) < 0.5)
        }

        @available(macOS 15.0, *)
        private static func canvasInkWidth(_ document: LayoutDocument) throws -> Int {
            let element = try staffText(in: document)
            let metrics = document.metrics
            let view = Canvas { context, _ in
                ScoreCanvasDrawing.drawElement(element, base: CGPoint(x: 150, y: 180), metrics: metrics, into: &context)
            }
            .frame(width: 700, height: 320)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return try inkWidth(#require(renderer.cgImage))
        }

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

        @available(macOS 15.0, *)
        @Test("the Canvas staff text draws the symbol run too")
        func canvasDrawsRuns() throws {
            let rich = try Self.canvasInkWidth(Self.document(Self.senzaPed))
            let plain = try Self.canvasInkWidth(Self.document(StaffText(text: "senza ")))
            #expect(rich > plain + 4)
        }

        @available(macOS 15.0, *)
        @Test("a decoration is a filled bar exactly where layout put it")
        func decorationBar() throws {
            let bar = LayoutRichTextDecoration(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 20), thickness: 2)
            let path = try #require(ScoreLayerBuilder.richTextPath(runs: [], decorations: [bar]))
            #expect(path.boundingBoxOfPath == CGRect(x: 10, y: 19, width: 30, height: 2))
        }
    }
#endif
