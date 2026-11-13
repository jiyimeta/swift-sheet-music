import CDirect2D
import SheetMusicBridgeCore

/// An offscreen canvas a host draws frame after frame on — a score video's frames — through Direct2D and DirectWrite in
/// software (WIC), the walk `ScoreSurface` draws the screen with. Made once, with its fonts loaded once; each frame
/// starts with `clear(argb:)`, paints as many command lists and overlays as it shows (one per system, at each one's
/// place), and ends with `copyPixels(into:)`. Creating a canvas per frame would load the fonts per frame
/// (`Direct2DPageRenderer.renderPixels` does, for a single picture).
///
/// Not thread-safe: one thread draws on one canvas, as Direct2D's factory is single-threaded.
public final class Direct2DFrameCanvas {
    public let widthPx: Int
    public let heightPx: Int
    private let canvas: OpaquePointer

    /// A white `widthPx` x `heightPx` canvas with `fontFiles` (those `ScoreSurface(fontFiles:)` takes; the bundled ones
    /// are `ScoreSurface.bundledFontFiles`) loaded. With no font files only the installed fonts draw.
    public init(widthPx: Int, heightPx: Int, fontFiles: [String]) throws {
        guard widthPx > 0, heightPx > 0 else {
            let invalidArgument = Int32(bitPattern: 0x8007_0057) // E_INVALIDARG
            throw Direct2DPageRenderer.Failure(
                step: "creating a \(widthPx) x \(heightPx) canvas", hresult: invalidArgument,
            )
        }
        var created: OpaquePointer?
        try Direct2DPageRenderer.check(cd2d_create(&created, UInt32(widthPx), UInt32(heightPx)), "creating the canvas")
        guard let made = created else { throw Direct2DPageRenderer.Failure(step: "creating the canvas", hresult: -1) }
        do {
            for file in fontFiles {
                let added = withWide(file) { cd2d_add_font_file(made, $0) }
                try Direct2DPageRenderer.check(added, "adding the font \(file)")
            }
            // No private collection at all rather than an empty one: a family then resolves in the installed fonts.
            if !fontFiles.isEmpty {
                try Direct2DPageRenderer.check(cd2d_fonts_ready(made), "building the font collection")
            }
        } catch {
            cd2d_destroy(made)
            throw error
        }
        canvas = made
        self.widthPx = widthPx
        self.heightPx = heightPx
    }

    deinit {
        cd2d_destroy(canvas)
    }

    /// Starts a frame: the whole canvas filled with `argb` (0xAARRGGBB), whatever the last frame drew.
    public func clear(argb: UInt32) throws {
        try Direct2DPageRenderer.check(cd2d_clear(canvas, argb), "clearing the canvas")
    }

    /// Paints `commands` at `pxPerMM`, their origin at `offsetPx` on the canvas, over what is there. Commands that
    /// certainly fall outside the canvas are skipped (paths are always walked).
    public func paint(_ commands: ArraySlice<DrawCommand>, pxPerMM: Double, offsetPx: (x: Double, y: Double)) {
        var walker = DrawCommandWalker(canvas: canvas, pxPerMM: pxPerMM, offset: offsetPx, cull: bounds)
        walker.paint(commands)
    }

    /// `paint(_:pxPerMM:offsetPx:)` for a whole list.
    public func paint(_ commands: [DrawCommand], pxPerMM: Double, offsetPx: (x: Double, y: Double)) {
        paint(commands[...], pxPerMM: pxPerMM, offsetPx: offsetPx)
    }

    /// Paints `overlays` the way `ScoreSurface` paints them, in their order, at `pxPerMM` with their page's origin at
    /// `offsetPx` (an overlay's `page` is not read: the caller places it).
    public func paint(_ overlays: [ScoreSurface.Overlay], pxPerMM: Double, offsetPx: (x: Double, y: Double)) {
        for overlay in overlays {
            var walker = DrawCommandWalker(canvas: canvas, pxPerMM: pxPerMM, offset: offsetPx, cull: bounds)
            ScoreSurface.paint(overlay, with: &walker)
        }
    }

    /// The frame's pixels — BGRA premultiplied, top-down, `widthPx * 4` bytes a row — into `pixels`, which holds at
    /// least `widthPx * heightPx * 4` bytes. Ends the frame; the next `clear(argb:)` starts another.
    public func copyPixels(into pixels: UnsafeMutableRawBufferPointer) throws {
        let needed = widthPx * heightPx * 4
        guard pixels.count >= needed, let base = pixels.baseAddress else {
            let invalidArgument = Int32(bitPattern: 0x8007_0057) // E_INVALIDARG
            throw Direct2DPageRenderer.Failure(
                step: "reading \(needed) bytes into \(pixels.count)", hresult: invalidArgument,
            )
        }
        try Direct2DPageRenderer.check(
            cd2d_copy_pixels(canvas, base.assumingMemoryBound(to: UInt8.self), UInt32(widthPx), UInt32(heightPx)),
            "reading the pixels",
        )
    }

    /// The frame's pixels as a new array — `copyPixels(into:)` for a test or a single picture.
    public func pixels() throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: widthPx * heightPx * 4)
        try pixels.withUnsafeMutableBytes { try copyPixels(into: $0) }
        return pixels
    }

    private var bounds: DrawRect {
        DrawRect(x: 0, y: 0, width: Double(widthPx), height: Double(heightPx))
    }
}
