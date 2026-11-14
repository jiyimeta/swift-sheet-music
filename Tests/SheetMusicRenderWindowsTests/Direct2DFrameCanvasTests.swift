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

    /// A page of three runs: a title block (no system), system 0 at the top left and system 1 at the bottom right.
    private static let page: (commands: [DrawCommand], spans: [SystemSpan]) = {
        let title: [DrawCommand] = [.setColor(argb: 0xFF00_0000), .fillRect(x: 20, y: 2, w: 5, h: 3)]
        let first: [DrawCommand] = [.setColor(argb: 0xFF00_0000), .fillRect(x: 2, y: 10, w: 5, h: 5)]
        let second: [DrawCommand] = [.setColor(argb: 0xFF00_0000), .fillRect(x: 20, y: 20, w: 5, h: 5)]
        let commands = title + first + second
        let spans = [
            SystemSpan(systemIndex: nil, commandRange: 0 ..< 2, frameMM: DrawRect(x: 20, y: 2, width: 5, height: 3)),
            SystemSpan(systemIndex: 0, commandRange: 2 ..< 4, frameMM: DrawRect(x: 2, y: 10, width: 5, height: 5)),
            SystemSpan(systemIndex: 1, commandRange: 4 ..< 6, frameMM: DrawRect(x: 20, y: 20, width: 5, height: 5)),
        ]
        return (commands, spans)
    }()

    @Test
    func `a page's chosen systems paint and nothing else of it does`() throws {
        let canvas = try Direct2DFrameCanvas(widthPx: Self.sizePx, heightPx: Self.sizePx, fontFiles: [])
        try canvas.clear(argb: 0xFFFF_FFFF)
        canvas.paint(
            pageCommands: Self.page.commands, spans: Self.page.spans, systems: [1], pxPerMM: Self.pxPerMM,
            offsetPx: (x: 0, y: 0),
        )
        let pixels = try canvas.pixels()
        #expect(Self.isDark(Self.pixel(pixels, x: 90, y: 90)), "system 1 is missing")
        #expect(Self.pixel(pixels, x: 18, y: 50) == Self.white, "system 0 was painted")
        #expect(Self.pixel(pixels, x: 90, y: 14) == Self.white, "the title block was painted")
    }

    @Test
    func `without systems the whole page paints`() throws {
        let canvas = try Direct2DFrameCanvas(widthPx: Self.sizePx, heightPx: Self.sizePx, fontFiles: [])
        try canvas.clear(argb: 0xFFFF_FFFF)
        canvas.paint(
            pageCommands: Self.page.commands, spans: Self.page.spans, systems: nil, pxPerMM: Self.pxPerMM,
            offsetPx: (x: 0, y: 0),
        )
        let pixels = try canvas.pixels()
        #expect(Self.isDark(Self.pixel(pixels, x: 90, y: 90)))
        #expect(Self.isDark(Self.pixel(pixels, x: 18, y: 50)))
        #expect(Self.isDark(Self.pixel(pixels, x: 90, y: 14)))
    }

    @Test
    func `a clip keeps a paint inside it, and nested clips intersect`() throws {
        let canvas = try Direct2DFrameCanvas(widthPx: Self.sizePx, heightPx: Self.sizePx, fontFiles: [])
        try canvas.clear(argb: 0xFFFF_FFFF)
        let everything: [DrawCommand] = [.setColor(argb: 0xFF00_0000), .fillRect(x: 0, y: 0, w: 30, h: 30)]
        try canvas.pushClip(x: 20, y: 20, width: 60, height: 60)
        try canvas.pushClip(x: 50, y: 0, width: 70, height: 120)
        canvas.paint(everything, pxPerMM: Self.pxPerMM, offsetPx: (x: 0, y: 0))
        try canvas.popClip()
        try canvas.popClip()
        let pixels = try canvas.pixels()
        #expect(Self.isDark(Self.pixel(pixels, x: 65, y: 50)), "inside both clips")
        #expect(Self.pixel(pixels, x: 30, y: 50) == Self.white, "inside the outer clip only")
        #expect(Self.pixel(pixels, x: 100, y: 50) == Self.white, "inside the inner clip only")
        #expect(Self.pixel(pixels, x: 10, y: 10) == Self.white, "outside both")
    }

    @Test
    func `a frame cannot end with a clip still pushed`() throws {
        let canvas = try Direct2DFrameCanvas(widthPx: 8, heightPx: 8, fontFiles: [])
        try canvas.clear(argb: 0xFFFF_FFFF)
        try canvas.pushClip(x: 0, y: 0, width: 4, height: 4)
        #expect(throws: Direct2DPageRenderer.Failure.self) { _ = try canvas.pixels() }
        try canvas.popClip()
        #expect(throws: Direct2DPageRenderer.Failure.self) { try canvas.popClip() }
        _ = try canvas.pixels()
    }

    @Test
    func `a clip left pushed does not reach the next frame`() throws {
        let canvas = try Direct2DFrameCanvas(widthPx: Self.sizePx, heightPx: Self.sizePx, fontFiles: [])
        try canvas.clear(argb: 0xFFFF_FFFF)
        try canvas.pushClip(x: 0, y: 0, width: 10, height: 10)
        #expect(throws: Direct2DPageRenderer.Failure.self) { _ = try canvas.pixels() }

        try canvas.clear(argb: 0xFFFF_FFFF)
        canvas.paint(Self.square, pxPerMM: Self.pxPerMM, offsetPx: (x: 70, y: 60))
        let pixels = try canvas.pixels()
        #expect(Self.isDark(Self.pixel(pixels, x: 80, y: 70)), "the last frame's clip still holds")
    }

    @Test
    func `a picture at half opacity over white reads back mid-gray`() throws {
        let canvas = try Direct2DFrameCanvas(widthPx: Self.sizePx, heightPx: Self.sizePx, fontFiles: [])
        try canvas.clear(argb: 0xFFFF_FFFF)
        // A 4 x 4 opaque black picture, stretched over 40 x 40 px at (40, 40).
        let black: [UInt8] = (0 ..< 4 * 4 * 4).map { $0 % 4 == 3 ? 255 : 0 }
        try black.withUnsafeBytes {
            try canvas.draw(
                pixels: $0, widthPx: 4, heightPx: 4, in: (x: 40, y: 40, width: 40, height: 40), opacity: 0.5,
            )
        }
        let pixels = try canvas.pixels()
        let middle = Self.pixel(pixels, x: 60, y: 60)
        #expect(middle[0 ..< 3].allSatisfy { abs(Int($0) - 128) <= 2 }, "\(middle)")
        #expect(Self.pixel(pixels, x: 20, y: 20) == Self.white, "the picture painted outside its rect")
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
