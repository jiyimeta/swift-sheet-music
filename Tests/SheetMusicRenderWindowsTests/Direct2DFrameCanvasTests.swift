import SheetMusicBridgeCore
@testable import SheetMusicRenderWindows
import Testing

/// `Direct2DFrameCanvas`: one canvas drawn on frame after frame — a score video's — with command lists placed at their
/// own offsets, overlays over them, and nothing of the last frame left once `clear(argb:)` starts the next.
struct Direct2DFrameCanvasTests {
    private static let pxPerMM = 4.0
    private static let sizePx = 120
    private static let white: [UInt8] = [255, 255, 255, 255]

    /// A 5 mm black square at the origin, as a command list.
    private static let square: [DrawCommand] = [.setColor(argb: 0xFF00_0000), .fillRect(x: 0, y: 0, w: 5, h: 5)]

    private static func pixel(_ pixels: [UInt8], x: Int, y: Int) -> [UInt8] {
        let index = (y * sizePx + x) * 4
        return Array(pixels[index ..< index + 4])
    }

    private static func isDark(_ pixel: [UInt8]) -> Bool {
        pixel[0] < 64 && pixel[1] < 64 && pixel[2] < 64
    }

    @Test
    func `two command lists at two offsets land where each is placed`() throws {
        let canvas = try Direct2DFrameCanvas(widthPx: Self.sizePx, heightPx: Self.sizePx, fontFiles: [])
        try canvas.clear(argb: 0xFFFF_FFFF)
        canvas.paint(Self.square, pxPerMM: Self.pxPerMM, offsetPx: (x: 10, y: 10))
        canvas.paint(Self.square, pxPerMM: Self.pxPerMM, offsetPx: (x: 70, y: 60))
        let pixels = try canvas.pixels()
        // Each square is 20 px; its middle is 10 px in from its offset.
        #expect(Self.isDark(Self.pixel(pixels, x: 20, y: 20)), "the first square is not at (10, 10)")
        #expect(Self.isDark(Self.pixel(pixels, x: 80, y: 70)), "the second square is not at (70, 60)")
        #expect(Self.pixel(pixels, x: 50, y: 40) == Self.white, "something was drawn between them")
    }

    @Test
    func `the next frame keeps nothing of the last`() throws {
        let canvas = try Direct2DFrameCanvas(widthPx: Self.sizePx, heightPx: Self.sizePx, fontFiles: [])
        try canvas.clear(argb: 0xFFFF_FFFF)
        canvas.paint(Self.square, pxPerMM: Self.pxPerMM, offsetPx: (x: 10, y: 10))
        let first = try canvas.pixels()
        #expect(Self.isDark(Self.pixel(first, x: 20, y: 20)))

        try canvas.clear(argb: 0xFFFF_FFFF)
        canvas.paint(Self.square, pxPerMM: Self.pxPerMM, offsetPx: (x: 70, y: 60))
        let second = try canvas.pixels()
        #expect(Self.pixel(second, x: 20, y: 20) == Self.white, "the first frame's square is still there")
        #expect(Self.isDark(Self.pixel(second, x: 80, y: 70)), "the second frame's square is missing")
    }

    @Test
    func `clear fills with the color given`() throws {
        let canvas = try Direct2DFrameCanvas(widthPx: Self.sizePx, heightPx: Self.sizePx, fontFiles: [])
        try canvas.clear(argb: 0xFF20_4080)
        let pixels = try canvas.pixels()
        // BGRA: blue 0x80, green 0x40, red 0x20.
        #expect(Self.pixel(pixels, x: 60, y: 60) == [0x80, 0x40, 0x20, 0xFF])
    }

    @Test
    func `overlays paint over the commands at their offset`() throws {
        let canvas = try Direct2DFrameCanvas(widthPx: Self.sizePx, heightPx: Self.sizePx, fontFiles: [])
        try canvas.clear(argb: 0xFFFF_FFFF)
        canvas.paint(Self.square, pxPerMM: Self.pxPerMM, offsetPx: (x: 10, y: 10))
        canvas.paint(
            [.fillRect(page: 0, rect: PageRectMM(x: 0, y: 0, width: 5, height: 5), argb: 0xFFFF_0000)],
            pxPerMM: Self.pxPerMM, offsetPx: (x: 10, y: 10),
        )
        let pixels = try canvas.pixels()
        // Red over the black square: BGRA 0, 0, 255.
        #expect(Self.pixel(pixels, x: 20, y: 20) == [0, 0, 255, 255])
    }

    /// The same commands, drawn by the one-shot path and by a frame on the canvas, are the same pixels: the canvas is
    /// that path kept between frames, not another renderer.
    @Test
    func `a frame equals the one-shot render of the same commands`() throws {
        let commands: [DrawCommand] = Self.square + [
            .setColor(argb: 0xFF00_00FF), .moveTo(x: 2, y: 20), .lineTo(x: 25, y: 8), .stroke(width: 0.5),
        ]
        let oneShot = try Direct2DPageRenderer.renderPixels(
            commands, widthPx: Self.sizePx, heightPx: Self.sizePx, pxPerMM: Self.pxPerMM, offsetPx: (x: 4, y: 6),
            fontFiles: [],
        )
        let canvas = try Direct2DFrameCanvas(widthPx: Self.sizePx, heightPx: Self.sizePx, fontFiles: [])
        // A frame drawn and thrown away first, so the compared frame is a second one on a used canvas.
        try canvas.clear(argb: 0xFFFF_FFFF)
        canvas.paint(Self.square, pxPerMM: Self.pxPerMM, offsetPx: (x: 60, y: 60))
        _ = try canvas.pixels()
        try canvas.clear(argb: 0xFFFF_FFFF)
        canvas.paint(commands, pxPerMM: Self.pxPerMM, offsetPx: (x: 4, y: 6))
        #expect(try canvas.pixels() == oneShot)
    }

    @Test
    func `an empty canvas or a short buffer is refused`() throws {
        #expect(throws: Direct2DPageRenderer.Failure.self) {
            _ = try Direct2DFrameCanvas(widthPx: 0, heightPx: 10, fontFiles: [])
        }
        let canvas = try Direct2DFrameCanvas(widthPx: 8, heightPx: 8, fontFiles: [])
        var short = [UInt8](repeating: 0, count: 8 * 8 * 4 - 1)
        #expect(throws: Direct2DPageRenderer.Failure.self) {
            try short.withUnsafeMutableBytes { try canvas.copyPixels(into: $0) }
        }
    }
}
