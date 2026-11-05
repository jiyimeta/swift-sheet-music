import Foundation
import SheetMusicBridgeCore
@testable import SheetMusicRenderWindows
import Testing

/// A frame's picture (`DrawCommand.drawImage`) on Windows: decoded by WIC and stretched over its rectangle, as the
/// Apple renderer draws it — it used to be skipped, so a score's pictures were missing on Windows.
struct DrawImageTests {
    private static let pxPerMM = 4.0
    private static let sizePx = 120

    /// A 4 × 4 opaque pure-red PNG.
    private static let redPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
        0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x08, 0x02, 0x00, 0x00,
        0x00, 0x26, 0x93, 0x09, 0x29, 0x00, 0x00, 0x00, 0x10, 0x49, 0x44, 0x41, 0x54, 0x78,
        0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x47, 0x0C, 0xC4, 0x71, 0x00, 0xAE, 0x93, 0x0F,
        0xF1, 0xD0, 0x5F, 0x23, 0x9E, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])

    /// BGRA at a millimetre position.
    private static func pixel(_ pixels: [UInt8], mmX: Double, mmY: Double) -> [UInt8] {
        let index = (Int(mmY * pxPerMM) * sizePx + Int(mmX * pxPerMM)) * 4
        return Array(pixels[index ..< index + 4])
    }

    private static func render(_ commands: [DrawCommand]) throws -> [UInt8] {
        try Direct2DPageRenderer.renderPixels(
            commands, widthPx: sizePx, heightPx: sizePx, pxPerMM: pxPerMM, offsetPx: (0, 0), fontFiles: [],
        )
    }

    @Test
    func `a picture fills its rectangle, stretched, and nothing outside it`() throws {
        let pixels = try Self.render([.drawImage(data: Self.redPNG, x: 5, y: 5, w: 15, h: 10)])
        // Well inside: the picture's red (BGRA), however it was stretched from 4 × 4.
        #expect(Self.pixel(pixels, mmX: 12, mmY: 10) == [0, 0, 255, 255])
        #expect(Self.pixel(pixels, mmX: 6, mmY: 6) == [0, 0, 255, 255])
        // Outside the rectangle the canvas is still white.
        #expect(Self.pixel(pixels, mmX: 25, mmY: 25) == [255, 255, 255, 255])
        #expect(Self.pixel(pixels, mmX: 12, mmY: 20) == [255, 255, 255, 255])
    }

    @Test
    func `bytes WIC cannot read draw nothing`() throws {
        let pixels = try Self.render([.drawImage(data: Data([0, 1, 2, 3]), x: 5, y: 5, w: 15, h: 10)])
        #expect(pixels.allSatisfy { $0 == 255 })
    }

    @Test
    func `the same picture twice draws twice from one decode`() throws {
        let pixels = try Self.render([
            .drawImage(data: Self.redPNG, x: 2, y: 2, w: 5, h: 5),
            .drawImage(data: Self.redPNG, x: 20, y: 20, w: 5, h: 5),
        ])
        #expect(Self.pixel(pixels, mmX: 4, mmY: 4) == [0, 0, 255, 255])
        #expect(Self.pixel(pixels, mmX: 22, mmY: 22) == [0, 0, 255, 255])
    }
}

/// `ScoreSurface.replaceCommands` tells spans apart by `SpanKey`: the title block and every frame have no system index,
/// and each must still be its own span, or an edited frame's tiles are never redrawn.
struct SpanKeyTests {
    private static func span(_ system: Int?, _ range: Range<Int>) -> SystemSpan {
        SystemSpan(systemIndex: system, commandRange: range, frameMM: DrawRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test
    func `the title and each frame are keys of their own`() {
        let keyed = SpanKey.keyed([Self.span(nil, 0 ..< 3), Self.span(0, 3 ..< 9), Self.span(nil, 9 ..< 12)])
        #expect(keyed.count == 3)
        #expect(keyed[.unnumbered(0)]?.commandRange == 0 ..< 3)
        #expect(keyed[.unnumbered(1)]?.commandRange == 9 ..< 12)
        #expect(keyed[.system(0)]?.commandRange == 3 ..< 9)
    }
}
