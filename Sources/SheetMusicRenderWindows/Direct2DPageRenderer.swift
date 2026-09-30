import CDirect2D
import SheetMusicBridgeCore

/// One page to a PNG, through Direct2D and DirectWrite, in software (WIC): a thumbnail or an image export for a host,
/// and how the parity probe compares the Windows renderer with the Mac's pixel for pixel. The walk itself is
/// `DrawCommandWalker`, the one `ScoreSurface` draws the screen with.
public enum Direct2DPageRenderer {
    /// The Kotlin renderer's `coerceAtLeast(1.5f)`, `canvas.ts`'s `MIN_STROKE_PX`, `DrawProgramCGRenderer.minStrokePx`.
    public static let minStrokePx = DrawCommandWalker.minStrokePx

    public struct Failure: Error, CustomStringConvertible {
        public let step: String
        public let hresult: Int32

        public var description: String {
            "\(step) failed (HRESULT 0x\(String(UInt32(bitPattern: hresult), radix: 16, uppercase: true)))"
        }
    }

    /// Renders page `page` of `pages` whole onto a white canvas at `pxPerMM` — the page's size in pixels, rounded up —
    /// and writes it to `pngPath`. `fontFiles` are those `ScoreSurface(fontFiles:)` takes. A `.vertical` page is as
    /// tall as the music, and so is its image. Throws for a page outside `pages`.
    public static func renderPNG(
        pages: ScorePages, page: Int, pxPerMM: Double, fontFiles: [String], to pngPath: String,
    ) throws {
        guard pages.pages.indices.contains(page) else {
            let invalidArgument = Int32(bitPattern: 0x8007_0057) // E_INVALIDARG
            throw Failure(step: "rendering page \(page + 1) of \(pages.pageCount)", hresult: invalidArgument)
        }
        let size = pages.pageSizeMM(page)
        try renderPNG(
            pages.pages[page].commands,
            widthPx: max(1, Int((size.width * pxPerMM).rounded(.up))),
            heightPx: max(1, Int((size.height * pxPerMM).rounded(.up))),
            pxPerMM: pxPerMM, offsetPx: (0, 0), fontFiles: fontFiles, to: pngPath,
        )
    }

    /// Renders `commands` onto a white `widthPx` x `heightPx` canvas, offset by `offsetPx`, and writes it to
    /// `pngPath` — the parity probe's canvas, which the Mac's walk chose.
    package static func renderPNG(
        _ commands: [DrawCommand], widthPx: Int, heightPx: Int, pxPerMM: Double, offsetPx: (x: Double, y: Double),
        fontFiles: [String], to pngPath: String,
    ) throws {
        var created: OpaquePointer?
        try check(cd2d_create(&created, UInt32(widthPx), UInt32(heightPx)), "creating the canvas")
        guard let canvas = created else { throw Failure(step: "creating the canvas", hresult: -1) }
        defer { cd2d_destroy(canvas) }
        for file in fontFiles {
            try check(withWide(file) { cd2d_add_font_file(canvas, $0) }, "adding the font \(file)")
        }
        try check(cd2d_fonts_ready(canvas), "building the font collection")

        var walker = DrawCommandWalker(canvas: canvas, pxPerMM: pxPerMM, offset: offsetPx)
        walker.paint(commands[...])
        try check(withWide(pngPath) { cd2d_write_png(canvas, $0) }, "writing \(pngPath)")
    }

    /// `renderPNG`, returning the pixels (BGRA premultiplied, top-down) instead, for tests that read what this path
    /// drew. With no font files only the installed fonts draw (the system face). The onscreen probe does not compare
    /// against it: WIC rasterizes in software, so its antialiasing differs from the surface's hardware device.
    package static func renderPixels(
        _ commands: [DrawCommand], widthPx: Int, heightPx: Int, pxPerMM: Double, offsetPx: (x: Double, y: Double),
        fontFiles: [String],
    ) throws -> [UInt8] {
        var created: OpaquePointer?
        try check(cd2d_create(&created, UInt32(widthPx), UInt32(heightPx)), "creating the canvas")
        guard let canvas = created else { throw Failure(step: "creating the canvas", hresult: -1) }
        defer { cd2d_destroy(canvas) }
        for file in fontFiles {
            try check(withWide(file) { cd2d_add_font_file(canvas, $0) }, "adding the font \(file)")
        }
        // No private collection at all rather than an empty one: a family then resolves in the installed fonts alone.
        if !fontFiles.isEmpty {
            try check(cd2d_fonts_ready(canvas), "building the font collection")
        }
        var walker = DrawCommandWalker(canvas: canvas, pxPerMM: pxPerMM, offset: offsetPx)
        walker.paint(commands[...])
        var pixels = [UInt8](repeating: 0, count: widthPx * heightPx * 4)
        try check(
            pixels.withUnsafeMutableBufferPointer {
                cd2d_copy_pixels(canvas, $0.baseAddress, UInt32(widthPx), UInt32(heightPx))
            },
            "reading the pixels",
        )
        return pixels
    }

    static func check(_ hresult: Int32, _ step: String) throws {
        guard hresult == 0 else { throw Failure(step: step, hresult: hresult) }
    }
}
