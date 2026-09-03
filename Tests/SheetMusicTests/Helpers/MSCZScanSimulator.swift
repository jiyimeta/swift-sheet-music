#if !os(Android) && !os(WASI)
    import CoreGraphics
    import Foundation
    import PDFKit
    @testable import SheetMusicPDF

    /// Turns a typeset PDF into what a scan of it would look like to the
    /// importer: every page rasterized and re-wrapped as an image, so the
    /// vector walker finds nothing and the raster fallback is the only path
    /// that can read the document.
    ///
    /// This is the one step that makes a `.mscz` corpus measurable end to
    /// end. MuseScore's own PDF export is vector, and pointing the importer
    /// at it measures the VECTOR front-end no matter how the options are set
    /// — `applyRasterFallback` is keyed on a page having produced no glyphs
    /// and no paths. Rasterizing here is therefore not a convenience: it is
    /// what puts the document in the class the fallback exists for.
    ///
    /// NOT a substitute for a real scan. A re-rasterized export carries no
    /// sensor noise, no skew, no bleed-through and no JPEG ringing, so a
    /// number measured here is an upper bound on the same page scanned. The
    /// axis it DOES cover — real MuseScore engraving rather than the
    /// training generator's — is the one the synthetic corpus cannot.
    enum MSCZScanSimulator {
        enum Failure: Error {
            case cannotOpenPDF(URL)
            case cannotBuildImage
            case cannotBuildPDF
        }

        /// Rasterize every page of `url` at `dpi` and re-emit them as a
        /// one-image-per-page PDF, at the SAME point size as the source so
        /// the document's own page geometry survives the round trip.
        static func imageOnlyPDF(of url: URL, dpi: Double) throws -> Data {
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                throw Failure.cannotOpenPDF(url)
            }
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data) else { throw Failure.cannotBuildPDF }
            // A PDF context needs a mediaBox up front; per-page boxes are
            // passed to `beginPDFPage` below, so a document whose pages
            // differ in size still round-trips.
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                throw Failure.cannotBuildPDF
            }
            for index in 0 ..< document.pageCount {
                guard let page = document.page(at: index)?.pageRef else { continue }
                try autoreleasepool {
                    try drawPageAsImage(page, dpi: dpi, into: context)
                }
            }
            context.closePDF()
            return data as Data
        }

        /// One page: rasterize, then draw the raster back at the page's
        /// displayed size. `PDFPageRasterizer` already honors `/Rotate`, so
        /// the size used here is the TURNED one — taking it from the
        /// mediaBox instead would squash a rotated page into the wrong
        /// aspect.
        private static func drawPageAsImage(
            _ page: CGPDFPage, dpi: Double, into context: CGContext,
        ) throws {
            let bitmap = try PDFPageRasterizer.bitmap(page: page, dpi: dpi)
            let size = CGSize(
                width: CGFloat(bitmap.width) * 72 / CGFloat(dpi),
                height: CGFloat(bitmap.height) * 72 / CGFloat(dpi),
            )
            let pageBox = CGRect(origin: .zero, size: size)
            // `kCGPDFContextMediaBox` takes a CFData holding the CGRect
            // itself — not an NSValue, which is what the AppKit-shaped
            // spelling of this would reach for and which has no iOS twin.
            var boxBytes = pageBox
            let info = [
                kCGPDFContextMediaBox as String: Data(
                    bytes: &boxBytes, count: MemoryLayout<CGRect>.size,
                ) as CFData,
            ] as CFDictionary
            context.beginPDFPage(info)
            try draw(bitmap, in: pageBox, into: context)
            context.endPDFPage()
        }

        static func draw(_ bitmap: GrayBitmap, in rect: CGRect, into context: CGContext) throws {
            let bytes = Data(bitmap.pixels)
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let image = CGImage(
                      width: bitmap.width, height: bitmap.height,
                      bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bitmap.width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false,
                      intent: .defaultIntent,
                  )
            else {
                throw Failure.cannotBuildImage
            }
            context.interpolationQuality = .none
            context.draw(image, in: rect)
        }
    }
#endif
