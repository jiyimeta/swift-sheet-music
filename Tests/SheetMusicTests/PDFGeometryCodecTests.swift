#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicPDF
    import Testing

    struct PDFGeometryCodecTests {
        @Test func rectRoundTrips() throws {
            let wire = PdfRectWire(pageIndex: 2, x: 10, y: 20, width: 30, height: 40)
            let decoded = try PdfRectWire(decoding: wire.encodeToData())
            #expect(decoded == wire)
        }

        /// PDF user space is y-up from the bottom-left; the wire is top-left, y-down.
        @Test func encodeTopLeftFlipsY() throws {
            let rect = PDFElementRect(pageIndex: 0, rect: CGRect(x: 5, y: 100, width: 10, height: 20))
            let decoded = try PdfRectWire(decoding: PDFGeometryCodecs.encodeTopLeft(rect, pageHeight: 500))
            #expect(decoded.pageIndex == 0)
            #expect(decoded.x == 5)
            // pageHeight - rect.maxY == 500 - 120
            #expect(decoded.y == 380)
            #expect(decoded.width == 10)
            #expect(decoded.height == 20)
        }

        @Test func parseResultRoundTripsWithDiagnostics() throws {
            let wire = PdfParseResultWire(
                scoreHandle: 7,
                geometryHandle: 9,
                diagnostics: [PdfDiagnosticWire(severity: 1, location: "page 3", message: "unreadable beam")],
            )
            let decoded = try PdfParseResultWire(decoding: wire.encodeToData())
            #expect(decoded == wire)
        }

        @Test func pageSizesRoundTrip() throws {
            let wire = PdfPageSizesWire(widths: [595.2, 595.2], heights: [841.8, 841.8])
            let decoded = try PdfPageSizesWire(decoding: wire.encodeToData())
            #expect(decoded == wire)
        }
    }
#endif
