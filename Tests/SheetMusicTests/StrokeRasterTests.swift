import SheetMusicBridgeCore
import Testing

/// `StrokeRaster`: a stroke drawn as MuseScore's Qt draws it — at its own width, and one pixel wide at its width's
/// opacity when thinner — never raised to a floor (folino owner's QA, 2026-11-20: Windows drew staff lines ~1.7 times
/// their width at 100%, more zoomed out). 96 dpi is ~3.78 px/mm at zoom 100%, ~0.945 at 25%; a staff line is
/// ~0.23 mm, a staff space ~1.75 mm.
@Suite("Stroke raster")
struct StrokeRasterTests {
    private let screen100 = 96 / 25.4
    private let staffLineMM = 0.23

    @Test("a stroke a pixel wide or wider is drawn at its own width, fully opaque")
    func wideStrokesKeepTheirWidth() {
        #expect(StrokeRaster.pen(widthMM: 0.4, pxPerMM: screen100) == .init(widthPx: 0.4 * screen100, opacity: 1))
        #expect(StrokeRaster.pen(widthMM: 1, pxPerMM: 2.5) == .init(widthPx: 2.5, opacity: 1))
        // Exactly one pixel: Qt's cosmetic stroker (`penWidth * txscale <= 1`) and the stroke at its own width agree.
        #expect(StrokeRaster.pen(widthMM: 0.5, pxPerMM: 2) == .init(widthPx: 1, opacity: 1))
    }

    @Test("a staff line at 96 dpi and 100% is one pixel at its own width's opacity, not the old 1.5 px")
    func staffLineAtOneHundredPercent() {
        let pen = StrokeRaster.pen(widthMM: staffLineMM, pxPerMM: screen100)
        #expect(pen.widthPx == 1)
        #expect(abs(pen.opacity - staffLineMM * screen100) < 1e-12)
        // The ink it puts down per unit of length is its own width (~0.87 px), where the floor put down 1.5.
        #expect(pen.widthPx * pen.opacity < 0.9)
    }

    @Test("zoomed out to 25%, each staff line puts down only its own ink, under the 0.4 mm floor's")
    func staffLineZoomedOut() {
        let pxPerMM = screen100 / 4
        let pen = StrokeRaster.pen(widthMM: staffLineMM, pxPerMM: pxPerMM)
        #expect(pen.widthPx == 1)
        #expect(abs(pen.widthPx * pen.opacity - staffLineMM * pxPerMM) < 1e-12)
        // What the floor drew instead: 0.4 mm, ~0.38 px of ink per line — 1.7 times the line's own ~0.22.
        #expect(pen.widthPx * pen.opacity < 0.6 * 0.4 * pxPerMM)
    }

    @Test("every positive width puts down exactly its own ink")
    func inkIsConserved() {
        for pxPerMM in [0.945, 1.89, screen100, 5.67, 11.3] {
            for widthMM in stride(from: 0.01, through: 1.2, by: 0.01) {
                let pen = StrokeRaster.pen(widthMM: widthMM, pxPerMM: pxPerMM)
                #expect(abs(pen.widthPx * pen.opacity - widthMM * pxPerMM) < 1e-9, "\(widthMM) mm at \(pxPerMM)")
                #expect(pen.widthPx >= 1 && pen.opacity > 0 && pen.opacity <= 1)
            }
        }
    }

    @Test("a width of zero or less, or not a number, is the device's thinnest line: one pixel, fully opaque")
    func nonPositiveWidthIsAHairline() {
        for widthMM in [0, -0.2, Double.nan, Double.infinity] {
            #expect(StrokeRaster.pen(widthMM: widthMM, pxPerMM: screen100) == .init(widthPx: 1, opacity: 1))
        }
    }

    @Test("the pen's opacity multiplies the colour's alpha and leaves its RGB alone")
    func colorScalesAlpha() {
        #expect(StrokeRaster.color(0xFF12_3456, opacity: 1) == 0xFF12_3456)
        #expect(StrokeRaster.color(0xFF12_3456, opacity: 0.5) == 0x8012_3456)
        #expect(StrokeRaster.color(0x8000_0000, opacity: 0.25) == 0x2000_0000)
        #expect(StrokeRaster.color(0xFF00_0000, opacity: 0) == 0x0000_0000)
        // 255 × 0.87 = 221.85, rounded to 222 (0xDE).
        #expect(StrokeRaster.color(0xFFAB_CDEF, opacity: 0.87) == 0xDEAB_CDEF)
    }
}
