@testable import SheetMusicRenderWindows
import Testing

/// The `fillPath` overlay, as the surface paints it (`ScoreSurface.paint(_:with:)` through `renderOverlayPixels`): its
/// figures fill as one nonzero shape, so a translucent color is laid down once where they overlap.
struct FillPathOverlayTests {
    private static let pxPerMM = 4.0
    private static let sizePx = 120

    /// Two 10 mm squares overlapping by 5 mm, as two figures of one shape.
    private static let squares: [[PagePointMM]] = [
        square(x: 5, y: 5),
        square(x: 10, y: 5),
    ]

    private static func square(x: Double, y: Double) -> [PagePointMM] {
        [
            PagePointMM(x: x, y: y), PagePointMM(x: x + 10, y: y), PagePointMM(x: x + 10, y: y + 10),
            PagePointMM(x: x, y: y + 10),
        ]
    }

    private static func pixel(_ pixels: [UInt8], mmX: Double, mmY: Double) -> [UInt8] {
        let index = (Int(mmY * pxPerMM) * sizePx + Int(mmX * pxPerMM)) * 4
        return Array(pixels[index ..< index + 4])
    }

    @Test
    func `overlapping figures of one shape fill once`() throws {
        let pixels = try Direct2DPageRenderer.renderOverlayPixels(
            [.fillPath(page: 0, id: 1, figures: Self.squares, argb: 0x8000_00FF)],
            widthPx: Self.sizePx, heightPx: Self.sizePx, pxPerMM: Self.pxPerMM,
        )
        let onlyFirst = Self.pixel(pixels, mmX: 7, mmY: 10)
        let overlap = Self.pixel(pixels, mmX: 12, mmY: 10)
        let outside = Self.pixel(pixels, mmX: 25, mmY: 25)
        #expect(onlyFirst == overlap, "the overlap was painted twice: \(overlap) vs \(onlyFirst)")
        #expect(onlyFirst != outside, "nothing was painted: \(onlyFirst)")
        #expect(outside == [255, 255, 255, 255], "outside is not the white canvas: \(outside)")
    }

    @Test
    func `a figure without area draws nothing`() throws {
        let line = [PagePointMM(x: 5, y: 5), PagePointMM(x: 20, y: 20)]
        let pixels = try Direct2DPageRenderer.renderOverlayPixels(
            [.fillPath(page: 0, id: 2, figures: [line], argb: 0xFF00_0000)],
            widthPx: Self.sizePx, heightPx: Self.sizePx, pxPerMM: Self.pxPerMM,
        )
        #expect(pixels.allSatisfy { $0 == 255 })
    }
}
