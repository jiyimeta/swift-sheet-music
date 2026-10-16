#if os(macOS)
    import CoreGraphics
    import Foundation
    import ImageIO
    import PDFKit
    import QuartzCore
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicMSCX
    @testable import SheetMusicPDF
    @testable import SheetMusicUI
    import Testing

    /// The boxes after the title block and the pictures of every box, as the Apple screen draws them (the layer
    /// trees `ScoreView` mounts) and as the PDF export draws them.
    @MainActor
    @Suite("Frame rendering")
    struct FrameRenderTests {
        private let _installApple = TestSupport.installApple

        // MARK: - Fixtures

        private static func load(_ name: String) throws -> Score {
            try MSCXParser.parse(MSCXFixtureLoader.mscxData(name))
        }

        /// A PNG in the title block, a JPEG in the box before measure 2.
        private static func loadPictures() throws -> Score {
            try MSCZReader.parse(MSCXFixtureLoader.msczData("frames-pictures"))
        }

        /// `score` wrapped at 700 pt with the title block on: the mode frames exist in.
        private static func laidOut(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 700)
        }

        /// The export at MuseScore's A4 paper.
        @available(macOS 15.0, *)
        private static func a4() -> PDFExporter.Options {
            PDFExporter.Options(page: .explicit(EngravingPage.from(PageLayout.museScoreA4)))
        }

        /// Two whole-note bars under an "Opening" title, the second ending in a page break, then a text frame
        /// "Afterword" after the last bar: the break closes the last page, so the frame gets a page of its own.
        private static func scoreEndingInAPageBreakThenATextFrame() -> Score {
            let chord = Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])
            let bar = Measure(voices: [Voice(elements: [.chord(chord)])])
            let last = Measure(voices: [Voice(elements: [.chord(chord)])], pageBreak: true)
            let afterword = FrameText(style: .other, text: "Afterword", otherStyleName: "frame")
            return Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [bar, last])])],
                systemMeasures: [SystemMeasure(), SystemMeasure()],
                titleFrame: ScoreFrame(heightSp: 10, texts: [FrameText(style: .title, text: "Opening")]),
                blocks: [PositionedScoreBlock(beforeMeasureIndex: 2, block: .textFrame(TextFrame(text: afterword)))],
            )
        }

        /// The index of the batch holding the system that starts at `measure`: the page a frame before that measure
        /// belongs to.
        @available(macOS 15.0, *)
        private static func page(startingSystemAt measure: Int, in batches: [PDFExporter.PageBatch]) -> Int? {
            batches.firstIndex { batch in
                batch.systems.contains { $0.measures.first?.measureIndex == measure }
            }
        }

        // MARK: - Screen

        /// What the screen draws for `doc`: the layer trees `ScoreView` mounts with no visible rect, placed as its
        /// stack places them, in its order — the title block at the top with `titleImages`, each frame
        /// `mountedFrameIndices` picks at its `originY` with its own pictures, each system at its origin — then
        /// rasterized at 2×.
        @available(macOS 15.0, *)
        private static func screen(of doc: LayoutDocument) throws -> LayerRaster {
            let root = CALayer()
            root.frame = CGRect(origin: .zero, size: doc.size)
            /// AppKit's layers are Y-up: a block `top` points down the page and `height` tall sits at
            /// `size.height - top - height`.
            func place(_ layer: CALayer, x: CGFloat, top: CGFloat, height: CGFloat) {
                layer.frame.origin = CGPoint(x: x, y: doc.size.height - top - height)
                root.addSublayer(layer)
            }
            if let title = doc.titleFrame {
                let layer = TitleFrameLayerBuilder.build(
                    frame: title, images: doc.titleImages, width: doc.size.width, height: title.height,
                )
                place(layer, x: 0, top: 0, height: title.height)
            }
            for index in ScoreView.mountedFrameIndices(of: doc, in: nil) {
                let frame = doc.frames[index]
                let layer = TitleFrameLayerBuilder.build(
                    frame: frame.content, images: frame.images, width: doc.size.width, height: frame.height,
                )
                place(layer, x: 0, top: frame.originY, height: frame.height)
            }
            for system in doc.systems {
                let layer = ScoreLayerBuilder.buildSystem(system, metrics: doc.metrics)
                place(layer, x: system.origin.x, top: system.origin.y, height: system.size.height + 1)
            }
            let scale: CGFloat = 2
            return try LayerRaster(
                width: Int((doc.size.width * scale).rounded(.up)),
                height: Int((doc.size.height * scale).rounded(.up)),
                scale: scale,
            ) { context in
                root.render(in: context)
            }
        }

        /// The picture in `data` as ImageIO decodes it, one pixel per point, composited onto white in sRGB: the same
        /// decode and compositing the screen's layer goes through.
        private static func decoded(_ data: Data) throws -> LayerRaster {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return try LayerRaster(width: image.width, height: image.height, scale: 1) { context in
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
        }

        /// The title block's picture and the picture of the box after measure 2 are each painted into their rect in
        /// their own colors. The probe is the middle source pixel's center mapped into the rect (the rect's center to
        /// within half a source pixel), where an upside-down or shifted picture would put another pixel.
        @Test("a picture is painted into its rect in its own colors, the title's and a frame's")
        func imageRectIsPainted() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = try Self.laidOut(Self.loadPictures())
            let framed = try #require(doc.frames.first)
            let titlePicture = try #require(doc.titleImages.first)
            let framePicture = try #require(framed.images.first)
            let screen = try Self.screen(of: doc)
            // The title's pictures are in document coordinates; a frame's are relative to the frame's top.
            let placed = [
                (titlePicture, titlePicture.rect),
                (framePicture, framePicture.rect.offsetBy(dx: 0, dy: framed.originY)),
            ]
            for (picture, rect) in placed {
                let source = try Self.decoded(picture.data)
                let column = source.width / 2
                let row = source.height / 2
                let point = CGPoint(
                    x: rect.minX + (CGFloat(column) + 0.5) * rect.width / CGFloat(source.width),
                    y: rect.minY + (CGFloat(row) + 0.5) * rect.height / CGFloat(source.height),
                )
                let drawn = screen.rgb(at: point)
                let expected = source.rgb(x: column, y: row)
                let worst = zip(drawn, expected).map { abs($0 - $1) }.max() ?? 255
                #expect(drawn.contains { $0 < 250 }, "\(picture.format): nothing painted at \(point)")
                #expect(worst <= 8, "\(picture.format): drawn \(drawn), source \(expected), at \(point)")
            }
        }

        /// The TBox's "Interlude" is painted inside the frame's rect, and nothing is painted in the gap between the
        /// frame and the system below it.
        @Test("a text frame's text is painted inside the frame, and nothing between it and the system below")
        func textFrameTextIsPainted() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = try Self.laidOut(Self.load("frames-boxes"))
            let textFrameMatch = doc.frames.first { $0.kind == .text }
            let textFrame = try #require(textFrameMatch)
            let belowMatch = doc.systems.first { $0.origin.y >= textFrame.bottom }
            let below = try #require(belowMatch)
            let screen = try Self.screen(of: doc)
            let inside = CGRect(x: 0, y: textFrame.originY, width: doc.size.width, height: textFrame.height)
            #expect(screen.markedPixels(in: inside) > 0, "\"Interlude\" was not painted in its frame")
            // A point of slack at either end, for anti-aliasing.
            let gap = CGRect(
                x: 0, y: textFrame.bottom + 1, width: doc.size.width, height: below.origin.y - textFrame.bottom - 2,
            )
            try #require(gap.height > 0)
            #expect(screen.markedPixels(in: gap) == 0, "ink between the text frame and the system below it")
        }

        // MARK: - PDF

        /// Each frame's text is on the page that holds the system below the frame, and on no other. The title's text
        /// is the probe's control: it was drawn before frames were, so a page text that misses it means the
        /// extraction, not the drawing, failed.
        @Test("the PDF draws each frame's text on the page holding the system below it, and on no other")
        func pdfPageDrawsFrame() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = try Self.load("frames-boxes")
            let options = Self.a4()
            let paged = PDFExporter.pagedLayout(score: score, options: options)
            let data = try PDFExporter.export(score: score, options: options)
            let pdf = try #require(PDFDocument(data: data))
            try #require(pdf.pageCount == paged.batches.count)
            let texts = (0 ..< pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
            let first = try #require(texts.first)
            #expect(first.contains("Frames"), "the title is missing from page 1's text: \(first)")
            for (text, measure) in [("Part II", 4), ("Interlude", 8)] {
                let pageMatch = Self.page(startingSystemAt: measure, in: paged.batches)
                let page = try #require(pageMatch, "no page holds a system starting at measure \(measure)")
                let found = texts.indices.filter { texts[$0].contains(text) }
                #expect(found == [page], "\"\(text)\" belongs on page \(page + 1) alone, found on \(found)")
            }
        }

        /// A frame after the last system that gets a page with no systems is drawn on that page.
        @Test("the PDF draws a trailing frame on the page of its own it gets after a page break")
        func framesOnlyPageDrawsTrailingFrame() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.scoreEndingInAPageBreakThenATextFrame()
            let options = Self.a4()
            let paged = PDFExporter.pagedLayout(score: score, options: options)
            let lastBatch = try #require(paged.batches.last)
            try #require(paged.batches.count == 2)
            try #require(lastBatch.systems.isEmpty, "the trailing frame must get a batch with no systems")
            let data = try PDFExporter.export(score: score, options: options)
            let pdf = try #require(PDFDocument(data: data))
            try #require(pdf.pageCount == 2)
            let first = pdf.page(at: 0)?.string ?? ""
            let last = pdf.page(at: 1)?.string ?? ""
            #expect(first.contains("Opening"), "the title is missing from page 1's text: \(first)")
            #expect(last.contains("Afterword"), "the trailing frame is missing from its page: \(last)")
            #expect(!first.contains("Afterword"))
        }

        /// The title block's picture and a frame's picture are painted into their rects on their pages: the canvas
        /// maps document `(x, y)` to page `(margins.leading + x, margins.top + y − pageStartY)`.
        @Test("the PDF paints the title's picture and a frame's picture into their rects")
        func pdfPageDrawsPictures() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = try Self.loadPictures()
            let options = Self.a4()
            let paged = PDFExporter.pagedLayout(score: score, options: options)
            let framed = try #require(paged.document.frames.first)
            let titlePicture = try #require(paged.document.titleImages.first)
            let framePicture = try #require(framed.images.first)
            let framePageMatch = Self.page(startingSystemAt: framed.beforeMeasureIndex, in: paged.batches)
            let framePage = try #require(framePageMatch)
            let pages = try PDFPageRaster.pages(of: PDFExporter.export(score: score, options: options))
            try #require(pages.count == paged.batches.count)
            let placed = [
                (0, titlePicture.rect),
                (framePage, framePicture.rect.offsetBy(dx: 0, dy: framed.originY)),
            ]
            for (page, rect) in placed {
                let margins = paged.resolved.page.margins(forPageIndex: page)
                let center = CGPoint(
                    x: margins.leading + rect.midX,
                    y: margins.top + rect.midY - paged.batches[page].startY,
                )
                let probe = CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
                #expect(pages[page].markedFraction(in: probe) > 0.9, "no picture at \(center) on page \(page + 1)")
            }
        }
    }

    /// A layer tree or a picture rasterized onto white in sRGB. Rows run top to bottom, so pixel `(x, y)` is the
    /// point `(x / scale, y / scale)` from the top-left corner: document space, for a document's layer tree.
    private struct LayerRaster {
        let scale: CGFloat
        let width: Int
        let height: Int
        let rgba: [UInt8]

        init(width: Int, height: Int, scale: CGFloat, draw: (CGContext) -> Void) throws {
            self.scale = scale
            self.width = width
            self.height = height
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            draw(context)
            let raw = try #require(context.data)
            let count = width * 4 * height
            rgba = Array(UnsafeBufferPointer(start: raw.bindMemory(to: UInt8.self, capacity: count), count: count))
        }

        /// Red, green and blue of pixel `(x, y)`, clamped into the raster.
        func rgb(x: Int, y: Int) -> [Int] {
            let column = min(max(0, x), width - 1)
            let row = min(max(0, y), height - 1)
            let offset = (row * width + column) * 4
            return [Int(rgba[offset]), Int(rgba[offset + 1]), Int(rgba[offset + 2])]
        }

        /// `rgb(x:y:)` of the pixel holding `point`.
        func rgb(at point: CGPoint) -> [Int] {
            rgb(x: Int((point.x * scale).rounded(.down)), y: Int((point.y * scale).rounded(.down)))
        }

        /// Pixels inside `rect` (points from the top-left corner) that are not paper white.
        func markedPixels(in rect: CGRect) -> Int {
            let left = max(0, Int((rect.minX * scale).rounded(.down)))
            let right = min(width, Int((rect.maxX * scale).rounded(.up)))
            let top = max(0, Int((rect.minY * scale).rounded(.down)))
            let bottom = min(height, Int((rect.maxY * scale).rounded(.up)))
            guard left < right, top < bottom else { return 0 }
            let xs = left ..< right
            let ys = top ..< bottom
            return ys.reduce(0) { total, y in
                total + xs.count { x in rgb(x: x, y: y).contains { $0 < 250 } }
            }
        }
    }
#endif
