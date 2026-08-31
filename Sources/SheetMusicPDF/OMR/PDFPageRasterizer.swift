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
    ///
    /// A page's `/Rotate` entry IS honored — see `rotation` below. Scanned
    /// PDFs, this rasterizer's whole reason to exist, are a common source of
    /// rotated pages, and a page handed to the detector sideways reads as a
    /// bad model rather than as a bad transform.
    static func bitmap(page: CGPDFPage, dpi: Double) throws -> GrayBitmap {
        try autoreleasepool {
            let box = page.getBoxRect(.mediaBox)
            let scale = dpi / 72.0
            // Quarter turns swap the page's extent, and the raster has to
            // follow: sizing it from the unturned mediaBox would crop the
            // page's long side away rather than merely mis-place its ink.
            let turned = rotation(of: page) % 180 != 0
            let pointWidth = turned ? box.height : box.width
            let pointHeight = turned ? box.width : box.height
            let width = max(1, Int((pointWidth * CGFloat(scale)).rounded()))
            let height = max(1, Int((pointHeight * CGFloat(scale)).rounded()))
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
                // Below this line everything is in POINTS, and the three
                // transforms compose right-to-left onto a page point: the
                // mediaBox origin is subtracted first, then the page is
                // turned, then the whole thing is scaled to pixels. The
                // origin must go first — turning it too would slide the page
                // off the raster by twice the origin.
                context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                applyRotation(to: context, page: page, box: box)
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

    /// The page's `/Rotate`, normalized to one of 0 / 90 / 180 / 270.
    ///
    /// PDF 32000-1 §7.7.3.3 requires a multiple of 90 but NOT a value in
    /// [0, 360): `/Rotate -90` and `/Rotate 450` are both legal spellings of
    /// a quarter turn, and a writer that accumulates rotations emits them.
    /// Swift's `%` keeps the sign of the dividend, hence the second fold.
    static func rotation(of page: CGPDFPage) -> Int {
        let raw = Int(page.rotationAngle) % 360
        return raw < 0 ? raw + 360 : raw
    }

    /// Turn the context so the page draws the way a viewer would show it.
    ///
    /// Stated as where the page's own lower-left corner ends up, in a y-up
    /// space whose extent is the TURNED page (`w`/`h` are the unturned
    /// page's, so a quarter turn's extent is `h` x `w`):
    ///
    ///   - 90  clockwise: (x, y) -> (y, w - x) — lower-left to the top-left
    ///   - 180:           (x, y) -> (w - x, h - y) — to the top-right
    ///   - 270:           (x, y) -> (h - y, x) — to the bottom-right
    ///
    /// Done by hand rather than through `CGPDFPageGetDrawingTransform`
    /// because that API fits the page into a rect the caller supplies, and a
    /// fit introduces its own rounding and centering. Here the raster is
    /// sized FROM the page, so there is nothing to fit and every pixel is
    /// accounted for.
    private static func applyRotation(to context: CGContext, page: CGPDFPage, box: CGRect) {
        let (w, h) = (box.width, box.height)
        switch rotation(of: page) {
        case 90:
            context.translateBy(x: 0, y: w)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: w, y: h)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: h, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
    }
}
