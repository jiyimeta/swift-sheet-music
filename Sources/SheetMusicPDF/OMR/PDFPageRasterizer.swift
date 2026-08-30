import CoreGraphics
import Foundation
import SheetMusicCore

/// A PDF page as 8-bit grayscale, for the raster front-end.
///
/// `GrayBitmap`'s own doc comment defers this decision ("how a page becomes
/// pixels is a later decision"); this is the resolution of it.
enum PDFPageRasterizer {
    /// The pool is owned HERE, not at the call site, precisely so it cannot be
    /// forgotten there: a sweep in this repo that left it to the caller
    /// consumed 24GB and took the machine down. Peak is set by the LARGEST
    /// SINGLE PAGE (~18MB for A4 at 400dpi), so a caller that rasterizes one
    /// page at a time has a flat ceiling however long the document is.
    static func bitmap(page: CGPDFPage, dpi: Double) throws -> GrayBitmap {
        try autoreleasepool {
            let box = page.getBoxRect(.mediaBox)
            let scale = dpi / 72.0
            let width = max(1, Int((box.width * CGFloat(scale)).rounded()))
            let height = max(1, Int((box.height * CGFloat(scale)).rounded()))
            // Deliberately zeroed, matching what CGContext would start with if
            // it owned the allocation itself (data: nil): the white fill just
            // below is what turns this into a blank PAGE, and leaving this at
            // 0 keeps that fill genuinely load-bearing rather than a no-op
            // over an already-white buffer.
            var pixels = [UInt8](repeating: 0, count: width * height)
            let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue,
                ) else { return false }
                // A CGContext starts ZEROED, and 0 is INK in GrayBitmap. Without
                // this fill every page rasterizes solid black.
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.interpolationQuality = .none
                // A freshly created CGBitmapContext's own native space is
                // ALREADY the flip we need: row 0 of the buffer is the
                // context's top (native y = height), row (height - 1) is the
                // bottom (native y ≈ 0) — exactly GrayBitmap's y-down-from-
                // top-left convention. So PDF page space (y-up,
                // bottom-left origin) only needs scaling to pixels and
                // translating the mediaBox origin to (0, 0); adding a
                // second flip on top of that would cancel the one the
                // context already gives us and mirror the page vertically.
                context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                context.translateBy(x: -box.origin.x, y: -box.origin.y)
                context.drawPDFPage(page)
                return true
            }
            guard ok else {
                throw SheetMusicError.malformedScore(ScoreFault(
                    code: "pdf.raster", message: "PDFPageRasterizer: cannot create a \(width)x\(height) context",
                ))
            }
            return GrayBitmap(pixels: pixels, width: width, height: height, dpi: dpi)
        }
    }
}
