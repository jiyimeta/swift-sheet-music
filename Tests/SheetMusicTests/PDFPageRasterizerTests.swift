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

        /// A one-page PDF written by hand, because `CGContext(consumer:
        /// mediaBox:)` cannot produce one: the PDF-context page dictionary
        /// takes box keys only, and there is no `kCGPDFContextRotate`. So the
        /// `/Rotate` entry — the whole subject of the tests below — is
        /// unreachable through CoreGraphics' own writer.
        ///
        /// `inkRect` is in ABSOLUTE page coordinates, like the content stream
        /// it is written into.
        static func handBuiltPDF(box: CGRect, rotate: Int, inkRect: CGRect) throws -> CGPDFPage {
            let content = "0 g \(inkRect.minX) \(inkRect.minY) "
                + "\(inkRect.width) \(inkRect.height) re f\n"
            let objects = [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /Resources << >> /Contents 4 0 R"
                    + " /MediaBox [\(box.minX) \(box.minY) \(box.maxX) \(box.maxY)]"
                    + " /Rotate \(rotate) >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            ]
            var pdf = "%PDF-1.4\n"
            var offsets: [Int] = []
            for (index, object) in objects.enumerated() {
                offsets.append(pdf.utf8.count)
                pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
            }
            let startxref = pdf.utf8.count
            pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
            for offset in offsets {
                pdf += String(format: "%010d 00000 n \n", offset)
            }
            pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
                + "startxref\n\(startxref)\n%%EOF\n"
            // swiftlint:disable:next force_unwrapping
            let provider = CGDataProvider(data: Data(pdf.utf8) as CFData)!
            // swiftlint:disable:next force_unwrapping
            return CGPDFDocument(provider)!.page(at: 1)!
        }

        /// 72x72pt page, ink in the page's own lower-left quarter, and the
        /// `/Rotate` under test. Every rotation expectation below is stated
        /// against THIS one rectangle, so a rotation is read as "where did
        /// the page's lower-left corner go".
        static func rotatedPDF(_ rotate: Int) throws -> CGPDFPage {
            try handBuiltPDF(
                box: CGRect(x: 0, y: 0, width: 72, height: 72),
                rotate: rotate,
                inkRect: CGRect(x: 0, y: 0, width: 36, height: 36),
            )
        }

        /// The unrotated control for the three below: without it a rotation
        /// test that passed for the wrong reason (say, a rasterizer that
        /// rotates everything) would look identical.
        @Test func rotateZeroLeavesTheLowerLeftAtTheBitmapsLowerLeft() throws {
            let bitmap = try PDFPageRasterizer.bitmap(page: Self.rotatedPDF(0), dpi: 72)
            #expect(bitmap[18, 54] == 0)
            #expect(bitmap[18, 18] == 255)
        }

        /// `/Rotate 90` displays the page turned a quarter-turn CLOCKWISE, so
        /// its lower-left corner is shown at the TOP-left. Scanned PDFs are
        /// this entry's main source: a page rasterized without it is fed to
        /// the detector sideways, which reads as "the model is bad".
        @Test func rotate90TurnsThePageClockwise() throws {
            let bitmap = try PDFPageRasterizer.bitmap(page: Self.rotatedPDF(90), dpi: 72)
            #expect(bitmap[18, 18] == 0, "the page's lower-left belongs at the top-left")
            #expect(bitmap[18, 54] == 255)
            #expect(bitmap[54, 18] == 255)
        }

        @Test func rotate180TurnsThePageHalfway() throws {
            let bitmap = try PDFPageRasterizer.bitmap(page: Self.rotatedPDF(180), dpi: 72)
            #expect(bitmap[54, 18] == 0, "the page's lower-left belongs at the top-right")
            #expect(bitmap[18, 54] == 255)
        }

        @Test func rotate270TurnsThePageCounterClockwise() throws {
            let bitmap = try PDFPageRasterizer.bitmap(page: Self.rotatedPDF(270), dpi: 72)
            #expect(bitmap[54, 54] == 0, "the page's lower-left belongs at the bottom-right")
            #expect(bitmap[18, 18] == 255)
        }

        /// A quarter turn swaps the raster's dimensions. Getting this wrong
        /// does not merely mis-place ink: it crops the page, and on a portrait
        /// scan that is the entire right-hand side of the music.
        @Test func aQuarterTurnSwapsTheRastersDimensions() throws {
            let portrait = CGRect(x: 0, y: 0, width: 72, height: 144)
            let ink = CGRect(x: 0, y: 0, width: 36, height: 36)
            let upright = try PDFPageRasterizer.bitmap(
                page: Self.handBuiltPDF(box: portrait, rotate: 0, inkRect: ink), dpi: 72,
            )
            #expect(upright.width == 72)
            #expect(upright.height == 144)
            let turned = try PDFPageRasterizer.bitmap(
                page: Self.handBuiltPDF(box: portrait, rotate: 90, inkRect: ink), dpi: 72,
            )
            #expect(turned.width == 144)
            #expect(turned.height == 72)
        }

        /// The mediaBox origin has to be subtracted BEFORE the rotation, not
        /// after: rotating first turns the offset itself, which slides the
        /// page off the raster by twice the origin.
        @Test func theBoxOriginIsSubtractedBeforeTheRotation() throws {
            let bitmap = try PDFPageRasterizer.bitmap(
                page: Self.handBuiltPDF(
                    box: CGRect(x: 36, y: 36, width: 72, height: 72),
                    rotate: 90,
                    inkRect: CGRect(x: 36, y: 36, width: 36, height: 36),
                ),
                dpi: 72,
            )
            #expect(bitmap[18, 18] == 0, "the box's lower-left belongs at the top-left")
            #expect(bitmap[54, 54] == 255)
        }

        /// `/Rotate` is defined as a multiple of 90 but is not required to be
        /// in [0, 360): a negative or over-full value must normalize rather
        /// than fall through to "no rotation".
        @Test func anOutOfRangeRotationNormalizes() throws {
            let negative = try PDFPageRasterizer.bitmap(page: Self.rotatedPDF(-90), dpi: 72)
            #expect(negative[54, 54] == 0, "-90 is 270")
            let overFull = try PDFPageRasterizer.bitmap(page: Self.rotatedPDF(450), dpi: 72)
            #expect(overFull[18, 18] == 0, "450 is 90")
        }
    }
#endif
