@_spi(Testing) @testable import SheetMusicRenderWindows
import Testing

/// The `clippedFillPath` overlay: `fillPath`'s shape kept only inside its clip, intersected once and filled like any
/// shape — pixel-erased ink.
struct ClippedFillPathOverlayTests {
    private static let pxPerMM = 4.0
    private static let sizePx = 120
    private static let white: [UInt8] = [255, 255, 255, 255]

    private static func square(x: Double, y: Double, side: Double) -> [PagePointMM] {
        [
            PagePointMM(x: x, y: y), PagePointMM(x: x + side, y: y), PagePointMM(x: x + side, y: y + side),
            PagePointMM(x: x, y: y + side),
        ]
    }

    /// The stroke: a 20 mm square at (5, 5).
    private static let stroke = [square(x: 5, y: 5, side: 20)]

    private static func pixel(_ pixels: [UInt8], mmX: Double, mmY: Double) -> [UInt8] {
        let index = (Int(mmY * pxPerMM) * sizePx + Int(mmX * pxPerMM)) * 4
        return Array(pixels[index ..< index + 4])
    }

    private static func render(_ overlays: [ScoreSurface.Overlay]) throws -> [UInt8] {
        try Direct2DPageRenderer.renderOverlayPixels(overlays, widthPx: sizePx, heightPx: sizePx, pxPerMM: pxPerMM)
    }

    @Test
    func `the stroke is drawn only inside the clip`() throws {
        let clip = ScoreSurface.OverlayClip(figures: [Self.square(x: 10, y: 10, side: 8)], evenOdd: false)
        let pixels = try Self.render([
            .clippedFillPath(page: 0, id: 1, figures: Self.stroke, argb: 0xFF00_0000, clip: clip),
        ])
        #expect(Self.pixel(pixels, mmX: 14, mmY: 14) != Self.white, "inside both: not painted")
        #expect(Self.pixel(pixels, mmX: 7, mmY: 7) == Self.white, "inside the stroke, outside the clip: painted")
        #expect(Self.pixel(pixels, mmX: 28, mmY: 28) == Self.white, "outside the stroke: painted")
    }

    /// A ring — a 16 mm square around a 6 mm one, wound the same way — keeps its hole only under even-odd.
    @Test
    func `an even-odd clip leaves its hole empty, and a nonzero one fills it`() throws {
        let ring = [Self.square(x: 7, y: 7, side: 16), Self.square(x: 12, y: 12, side: 6)]
        let evenOdd = try Self.render([
            .clippedFillPath(
                page: 0, id: 1, figures: Self.stroke, argb: 0xFF00_0000,
                clip: ScoreSurface.OverlayClip(figures: ring, evenOdd: true),
            ),
        ])
        #expect(Self.pixel(evenOdd, mmX: 15, mmY: 15) == Self.white, "the hole was painted under even-odd")
        #expect(Self.pixel(evenOdd, mmX: 9, mmY: 9) != Self.white, "the ring itself was not painted")
        let nonzero = try Self.render([
            .clippedFillPath(
                page: 0, id: 1, figures: Self.stroke, argb: 0xFF00_0000,
                clip: ScoreSurface.OverlayClip(figures: ring, evenOdd: false),
            ),
        ])
        #expect(Self.pixel(nonzero, mmX: 15, mmY: 15) != Self.white, "the hole stayed empty under nonzero")
    }

    @Test
    func `a clip that misses the stroke draws nothing`() throws {
        let clip = ScoreSurface.OverlayClip(figures: [Self.square(x: 26, y: 26, side: 3)], evenOdd: false)
        let pixels = try Self.render([
            .clippedFillPath(page: 0, id: 1, figures: Self.stroke, argb: 0xFF00_0000, clip: clip),
        ])
        #expect(pixels.allSatisfy { $0 == 255 })
    }

    /// The same id with the same figures but a new clip — an eraser narrowed the mask — must be rebuilt, not drawn
    /// with the old intersection. Drawn red under clip A, then blue under clip B: B's own corner shows blue only if
    /// the shape was built again.
    @Test
    func `a cached shape is rebuilt when only its clip changes`() throws {
        let clipA = ScoreSurface.OverlayClip(figures: [Self.square(x: 5, y: 5, side: 8)], evenOdd: false)
        let clipB = ScoreSurface.OverlayClip(figures: [Self.square(x: 16, y: 16, side: 8)], evenOdd: false)
        let drawn = try Direct2DPageRenderer.renderOverlayShapePixels(
            [
                .clippedFillPath(page: 0, id: 7, figures: Self.stroke, argb: 0xFFFF_0000, clip: clipA),
                .clippedFillPath(page: 0, id: 7, figures: Self.stroke, argb: 0xFF00_00FF, clip: clipB),
            ],
            widthPx: Self.sizePx, heightPx: Self.sizePx, pxPerMM: Self.pxPerMM,
        )
        // BGRA: blue is the first byte.
        let inB = Self.pixel(drawn.pixels, mmX: 20, mmY: 20)
        #expect(inB[0] > 200 && inB[2] < 50, "clip B's corner is not blue: \(inB)")
        #expect(drawn.shapes == 1)
    }

    /// The surface's cached path and the uncached one paint the same pixels (an opaque color, since the cached render
    /// draws each overlay twice).
    @Test
    func `the cached and the uncached path paint the same pixels`() throws {
        let clip = ScoreSurface.OverlayClip(
            figures: [Self.square(x: 7, y: 7, side: 16), Self.square(x: 12, y: 12, side: 6)], evenOdd: true,
        )
        let overlay = ScoreSurface.Overlay.clippedFillPath(
            page: 0, id: 3, figures: Self.stroke, argb: 0xFF20_4060, clip: clip,
        )
        let uncached = try Self.render([overlay])
        let cached = try Direct2DPageRenderer.renderOverlayShapePixels(
            [overlay], widthPx: Self.sizePx, heightPx: Self.sizePx, pxPerMM: Self.pxPerMM,
        )
        #expect(uncached == cached.pixels)
    }

    /// The SPI face folino's tests read through draws what the surface does.
    @Test
    func `rasterizeOverlays is the surface's own painting`() throws {
        let overlay = ScoreSurface.Overlay.clippedFillPath(
            page: 0, id: 3, figures: Self.stroke, argb: 0xFF20_4060,
            clip: ScoreSurface.OverlayClip(figures: [Self.square(x: 10, y: 10, side: 8)], evenOdd: false),
        )
        let viaSPI = try ScoreSurface.rasterizeOverlays(
            [overlay], widthPx: Self.sizePx, heightPx: Self.sizePx, pxPerMM: Self.pxPerMM,
        )
        #expect(try viaSPI == (Self.render([overlay])))
    }
}
