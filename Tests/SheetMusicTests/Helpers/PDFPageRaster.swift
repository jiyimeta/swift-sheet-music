#if os(macOS)
    import CoreGraphics
    import Foundation
    import Testing

    /// One PDF page rasterized to RGBA, for comparing two renderings byte for byte or asking where the ink is.
    ///
    /// Rows run top to bottom — a bitmap context stores its highest row first — so pixel `(x, y)` is the page point
    /// `(x / scale, y / scale)` measured from the TOP-left corner, the space `PDFPageView` lays a page out in.
    struct PDFPageRaster {
        let mediaBox: CGRect
        let scale: CGFloat
        let width: Int
        let height: Int
        let rgba: [UInt8]

        /// Every page of `pdf`, in order.
        static func pages(of pdf: Data, scale: CGFloat = 2) throws -> [PDFPageRaster] {
            let provider = try #require(CGDataProvider(data: pdf as CFData))
            let document = try #require(CGPDFDocument(provider))
            guard document.numberOfPages > 0 else { return [] }
            return try (1 ... document.numberOfPages).map { number in
                try PDFPageRaster(page: #require(document.page(at: number)), scale: scale)
            }
        }

        init(page: CGPDFPage, scale: CGFloat) throws {
            mediaBox = page.getBoxRect(.mediaBox)
            self.scale = scale
            width = Int((mediaBox.width * scale).rounded(.up))
            height = Int((mediaBox.height * scale).rounded(.up))
            let bytesPerRow = width * 4
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            // Opaque white ground, so "marked" means ink rather than transparency.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
            let raw = try #require(context.data)
            let count = bytesPerRow * height
            rgba = Array(UnsafeBufferPointer(start: raw.bindMemory(to: UInt8.self, capacity: count), count: count))
        }

        /// Anything but paper white — ink, a gray invisible element, an anti-aliased edge.
        func isMarked(x: Int, y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return rgba[offset] < 250 || rgba[offset + 1] < 250 || rgba[offset + 2] < 250
        }

        /// Marked pixels inside `rect`, given in page points from the top-left corner.
        func markedPixels(in rect: CGRect) -> Int {
            let xs = max(0, Int((rect.minX * scale).rounded(.down))) ..<
                min(width, Int((rect.maxX * scale).rounded(.up)))
            let ys = max(0, Int((rect.minY * scale).rounded(.down))) ..<
                min(height, Int((rect.maxY * scale).rounded(.up)))
            guard !xs.isEmpty, !ys.isEmpty else { return 0 }
            return ys.reduce(0) { total, y in total + xs.count { isMarked(x: $0, y: y) } }
        }

        /// The whole pixel rows whose page-point Y, from the top, lies in `ys`.
        func rows(_ ys: Range<CGFloat>) -> ArraySlice<UInt8> {
            let first = max(0, Int((ys.lowerBound * scale).rounded()))
            let last = min(height, Int((ys.upperBound * scale).rounded()))
            guard first < last else { return [] }
            return rgba[(first * width * 4) ..< (last * width * 4)]
        }

        /// Fraction of `rect`'s pixels that are marked.
        func markedFraction(in rect: CGRect) -> Double {
            let area = (rect.width * scale).rounded() * (rect.height * scale).rounded()
            return area > 0 ? Double(markedPixels(in: rect)) / Double(area) : 0
        }

        /// Every marked pixel, as `y * width + x`.
        var markedIndices: Set<Int> {
            Set((0 ..< width * height).filter { isMarked(x: $0 % width, y: $0 / width) })
        }
    }
#endif
