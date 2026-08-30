#if canImport(CoreGraphics)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct PDFPageRasterizerTests {
        /// Builds a one-page PDF whose only content is a filled black rect in
        /// the lower-left quarter of a 72x72pt page.
        static func onePagePDF() throws -> CGPDFPage {
            let data = NSMutableData()
            // swiftlint:disable:next force_unwrapping
            let consumer = CGDataConsumer(data: data)!
            var box = CGRect(x: 0, y: 0, width: 72, height: 72)
            // swiftlint:disable:next force_unwrapping
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 36, height: 36))
            context.endPDFPage()
            context.closePDF()
            // swiftlint:disable:next force_unwrapping
            let provider = CGDataProvider(data: data as CFData)!
            // swiftlint:disable:next force_unwrapping
            return CGPDFDocument(provider)!.page(at: 1)!
        }

        /// An unfilled CGContext is all zeros, and 0 is INK. Without an
        /// explicit white fill every page comes out solid black.
        @Test func blankAreasArePaperNotInk() throws {
            let bitmap = try PDFPageRasterizer.bitmap(page: Self.onePagePDF(), dpi: 72)
            // Top-right quarter has nothing drawn in it.
            #expect(bitmap[54, 18] == 255)
        }

        /// y-down from the top-left (GrayBitmap's convention) vs. PDF's
        /// bottom-left origin: the rect drawn at the PDF's lower-left must
        /// appear at the bitmap's LOWER-left.
        @Test func theRasterIsYDownFromTheTopLeft() throws {
            let bitmap = try PDFPageRasterizer.bitmap(page: Self.onePagePDF(), dpi: 72)
            #expect(bitmap[18, 54] == 0, "the PDF's lower-left rect belongs at high y")
            #expect(bitmap[18, 18] == 255, "the PDF's upper-left is blank")
        }

        @Test func dpiScalesThePixelGridAndIsRecorded() throws {
            let bitmap = try PDFPageRasterizer.bitmap(page: Self.onePagePDF(), dpi: 144)
            #expect(bitmap.width == 144)
            #expect(bitmap.height == 144)
            #expect(bitmap.dpi == 144)
        }

        /// Builds a one-page PDF whose mediaBox does NOT start at (0, 0) —
        /// `CGRect(x: 36, y: 36, width: 72, height: 72)` — with the same
        /// lower-left-quarter ink rect drawn in ABSOLUTE PDF coordinates
        /// (`[36, 72] x [36, 72]`, i.e. the box's own lower-left quarter).
        /// `PDFPageRasterizer.bitmap` must subtract `box.origin` before
        /// scaling, or this ink lands in the wrong quadrant.
        static func offsetMediaBoxPDF() throws -> CGPDFPage {
            let data = NSMutableData()
            // swiftlint:disable:next force_unwrapping
            let consumer = CGDataConsumer(data: data)!
            var box = CGRect(x: 36, y: 36, width: 72, height: 72)
            // swiftlint:disable:next force_unwrapping
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 36, y: 36, width: 36, height: 36))
            context.endPDFPage()
            context.closePDF()
            // swiftlint:disable:next force_unwrapping
            let provider = CGDataProvider(data: data as CFData)!
            // swiftlint:disable:next force_unwrapping
            return CGPDFDocument(provider)!.page(at: 1)!
        }

        /// A non-zero mediaBox origin must be subtracted before scaling to
        /// pixels. `box.origin` is (36, 36) here, so if
        /// `translateBy(x: -box.origin.x, y: -box.origin.y)` were dropped —
        /// or applied in the wrong space — the ink would land shifted by a
        /// full quadrant: at bitmap columns [36, 72] / rows [0, 36] instead
        /// of columns [0, 36] / rows [36, 72].
        @Test func nonZeroMediaBoxOriginIsSubtractedBeforeScaling() throws {
            let bitmap = try PDFPageRasterizer.bitmap(page: Self.offsetMediaBoxPDF(), dpi: 72)
            #expect(bitmap[18, 54] == 0, "the box's lower-left rect belongs at high y, low x")
            #expect(bitmap[54, 18] == 255, "the box's upper-right quarter is blank")
        }
    }
#endif
