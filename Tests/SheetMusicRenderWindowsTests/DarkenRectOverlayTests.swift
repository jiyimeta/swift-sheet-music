@_spi(Testing) @testable import SheetMusicRenderWindows
import Testing

/// The `darkenRect` overlay: its color, opaque, kept only where it is darker than what is there — so it tints white
/// paper and leaves black ink black, where a translucent `fillRect` over the same ink lightens it with the band's
/// color.
struct DarkenRectOverlayTests {
    private static let pxPerMM = 4.0
    private static let sizePx = 120

    /// BGRA, as `rasterizeOverlays` reads.
    private static func pixel(_ pixels: [UInt8], mmX: Double, mmY: Double) -> [UInt8] {
        let index = (Int(mmY * pxPerMM) * sizePx + Int(mmX * pxPerMM)) * 4
        return Array(pixels[index ..< index + 4])
    }

    private static func render(_ overlays: [ScoreSurface.Overlay]) throws -> [UInt8] {
        try Direct2DPageRenderer.renderOverlayPixels(overlays, widthPx: sizePx, heightPx: sizePx, pxPerMM: pxPerMM)
    }

    /// Black "ink" from 10 to 20 mm; the band over all of it from 5 to 25 mm.
    private static let ink = ScoreSurface.Overlay.fillRect(
        page: 0, rect: PageRectMM(x: 10, y: 10, width: 10, height: 10), argb: 0xFF00_0000,
    )
    private static let band = PageRectMM(x: 5, y: 5, width: 20, height: 20)
    /// A light yellow (R 0xFF, G 0xF0, B 0x99), as a 20 % band of a strong yellow shows on white.
    private static let tint: UInt32 = 0xFFFF_F099

    @Test
    func `on white the band is its color, and over black ink the ink stays black`() throws {
        let pixels = try Self.render([Self.ink, .darkenRect(page: 0, rect: Self.band, argb: Self.tint)])
        #expect(Self.pixel(pixels, mmX: 7, mmY: 7) == [0x99, 0xF0, 0xFF, 0xFF], "the paper does not show the tint")
        #expect(Self.pixel(pixels, mmX: 15, mmY: 15) == [0x00, 0x00, 0x00, 0xFF], "the ink is no longer black")
        #expect(Self.pixel(pixels, mmX: 28, mmY: 28) == [0xFF, 0xFF, 0xFF, 0xFF], "outside the band: painted")
    }

    /// The alpha it is given is ignored under the blend: the color is laid down opaque, so a band handed over with its
    /// translucency still shows the same color on white.
    @Test
    func `the color is laid down opaque whatever its alpha`() throws {
        let translucent = 0x3300_0000 | (Self.tint & 0x00FF_FFFF)
        let pixels = try Self.render([.darkenRect(page: 0, rect: Self.band, argb: translucent)])
        #expect(Self.pixel(pixels, mmX: 7, mmY: 7) == [0x99, 0xF0, 0xFF, 0xFF])
    }

    /// After it, the next overlay blends as before: a half black over white is mid grey, where the minimum blend left
    /// switched on would compare its premultiplied black with the white and lay down black.
    @Test
    func `source-over is back for the overlay after it`() throws {
        let after = ScoreSurface.Overlay.fillRect(
            page: 0, rect: PageRectMM(x: 26, y: 26, width: 4, height: 4), argb: 0x8000_0000,
        )
        let pixels = try Self.render([.darkenRect(page: 0, rect: Self.band, argb: Self.tint), after])
        let grey = Self.pixel(pixels, mmX: 28, mmY: 28)
        #expect(grey[0] > 0x60 && grey[0] < 0xA0, "a half black over white is not mid grey: \(grey)")
    }
}
