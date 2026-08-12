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
        /// A rasterized page as a dark / not-dark grid, for probes that
        /// need WHERE the ink is rather than how much of it there is.
        ///
        /// A pure translation — a barline that keeps its length but
        /// moves — is invisible to an ink COUNT, so a count cannot see a
        /// mis-centered stroke at all. Restricting the scan to one
        /// column can: it measures the run's extent, not its area.
        ///
        /// Row 0 is whichever page edge the bitmap context put first;
        /// nothing here depends on which, so callers should phrase
        /// assertions as "symmetric about" rather than "above / below".
        struct InkRaster {
            let width: Int
            let height: Int
            /// Row-major, `y * width + x`.
            let dark: [Bool]

            /// Y of every dark pixel in column `x`.
            func darkYs(atX x: Int) -> [Int] {
                guard x >= 0, x < width else { return [] }
                return (0 ..< height).filter { dark[$0 * width + x] }
            }

            /// The row carrying the most ink. On a one-line staff that
            /// is the staff line itself — it is the only stroke that
            /// runs the width of the system.
            var busiestRow: Int? {
                var best: (row: Int, count: Int)?
                for y in 0 ..< height {
                    let count = (0 ..< width)
                        .reduce(0) { $0 + (dark[y * width + $1] ? 1 : 0) }
                    if count > (best?.count ?? 0) { best = (y, count) }
                }
                return best?.row
            }

            /// The largest X carrying any ink. The staff lines are
            /// clipped flush to the terminal barline's rightmost stroke
            /// (`BarLineGeometry.staffLineEndX`), so on a single-system
            /// page this is that barline — never the system's LEFT-edge
            /// line, and never a notehead or stem.
            var rightmostDarkColumn: Int? {
                (0 ..< width).last { x in
                    (0 ..< height).contains { dark[$0 * width + x] }
                }
            }
        }

        /// Dark pixels on page 1 of `score`'s PDF export, at 3× scale.
        @MainActor
        @available(macOS 15.0, *)
        static func ink(of score: Score) throws -> Int {
            try raster(of: score).dark.reduce(0) { $0 + ($1 ? 1 : 0) }
        }

        /// Page 1 of `score`'s PDF export as a dark / not-dark grid.
        @MainActor
        @available(macOS 15.0, *)
        static func raster(
            of score: Score, scale: CGFloat = 3,
        ) throws -> InkRaster {
            let pdf = try PDFExporter.export(score: score)
            let provider = try #require(CGDataProvider(data: pdf as CFData))
            let document = try #require(CGPDFDocument(provider))
            let page = try #require(document.page(at: 1))
            return try darkPixels(of: page, scale: scale)
        }

        private static func darkPixels(
            of page: CGPDFPage, scale: CGFloat,
        ) throws -> InkRaster {
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
            var dark = [Bool](repeating: false, count: width * height)
            for index in 0 ..< (width * height) {
                let offset = index * 4
                dark[index] = bytes[offset] < 128
                    && bytes[offset + 1] < 128
                    && bytes[offset + 2] < 128
            }
            return InkRaster(width: width, height: height, dark: dark)
        }
    }
#endif
