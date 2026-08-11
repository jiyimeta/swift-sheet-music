#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// Exports a score to PDF and counts the ink on page 1.
    ///
    /// The point of routing through `PDFExporter` is that it draws via
    /// `ScoreCanvasDrawing.drawSystem` — the SwiftUI Canvas renderer,
    /// which also backs `PagedScoreView`. That path has no other
    /// coverage in this repository: the corpus pixel gate rasterizes the
    /// CALayer tree instead (`RenderPreviews` goes through
    /// `ScoreLayerBuilder.buildSystem`), so a Canvas-only regression is
    /// invisible to it. `CanvasGraceChordInkTests` exists because
    /// exactly that happened once — `.graceChord` was silently dropped
    /// for the whole life of the file.
    ///
    /// Ink counting keeps these tests presence-level rather than
    /// pixel-exact: no golden files to maintain, but a renderer that
    /// stops drawing something fails immediately.
    enum CanvasInkProbe {
        /// Dark pixels on page 1 of `score`'s PDF export, at 3× scale.
        @MainActor
        @available(macOS 15.0, *)
        static func ink(of score: Score) throws -> Int {
            let pdf = try PDFExporter.export(score: score)
            let provider = try #require(CGDataProvider(data: pdf as CFData))
            let document = try #require(CGPDFDocument(provider))
            let page = try #require(document.page(at: 1))
            return try darkPixels(of: page, scale: 3)
        }

        private static func darkPixels(
            of page: CGPDFPage, scale: CGFloat,
        ) throws -> Int {
            let box = page.getBoxRect(.mediaBox)
            let width = Int(box.width * scale)
            let height = Int(box.height * scale)
            let bytesPerRow = width * 4
            let context = try #require(CGContext(
                data: nil,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            // Opaque white ground so "dark" means ink, not transparency.
            context.setFillColor(
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            )
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
            let raw = try #require(context.data)
            let bytes = raw.bindMemory(
                to: UInt8.self, capacity: bytesPerRow * height,
            )
            var count = 0
            for offset in stride(from: 0, to: bytesPerRow * height, by: 4)
                where bytes[offset] < 128
                && bytes[offset + 1] < 128
                && bytes[offset + 2] < 128
            {
                count += 1
            }
            return count
        }
    }
#endif
