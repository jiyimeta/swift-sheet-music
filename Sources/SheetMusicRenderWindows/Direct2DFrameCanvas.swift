import CDirect2D
import SheetMusicBridgeCore
import SheetMusicPages

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
    ///
    /// `package` since 4.39.0 (public in 4.37.0 and 4.38.0): `DrawCommand` is SheetMusicBridgeCore's, which is not a
    /// product, so no host could name it; a host paints a score through `paint(_ pages: ScorePages, …)`.
    package func paint(_ commands: ArraySlice<DrawCommand>, pxPerMM: Double, offsetPx: (x: Double, y: Double)) {
        var walker = DrawCommandWalker(canvas: canvas, pxPerMM: pxPerMM, offset: offsetPx, cull: bounds)
        walker.paint(commands)
    }

    /// `paint(_:pxPerMM:offsetPx:)` for a whole list.
    package func paint(_ commands: [DrawCommand], pxPerMM: Double, offsetPx: (x: Double, y: Double)) {
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

    /// Paints page `page` of `pages` at `pxPerMM`, the page's top-left corner at `offsetPx` on the canvas. With
    /// `systems`, only the runs of those systems (indices into `pages.document.systems`) — neither the title block
    /// nor a box between systems; without, the whole page. Each run is walked as `ScoreSurface` walks a tile's, from
    /// the draw program's default state (`ScorePages.systemCommandRanges(onPage:)`), so a run alone paints what the
    /// page paints there. A `page` outside the pages paints nothing.
    public func paint(
        _ pages: ScorePages, page: Int, systems: Set<Int>? = nil, pxPerMM: Double, offsetPx: (x: Double, y: Double),
    ) {
        guard page >= 0, page < pages.pages.count else { return }
        paint(
            pageCommands: pages.pages[page].commands, spans: page < pages.spans.count ? pages.spans[page] : [],
            systems: systems, pxPerMM: pxPerMM, offsetPx: offsetPx,
        )
    }

    /// One page's `commands`, cut into `spans`: the runs of `systems`, or every command without them.
    package func paint(
        pageCommands commands: [DrawCommand], spans: [SystemSpan], systems: Set<Int>?, pxPerMM: Double,
        offsetPx: (x: Double, y: Double),
    ) {
        guard let systems else {
            paint(commands[...], pxPerMM: pxPerMM, offsetPx: offsetPx)
            return
        }
        for span in spans {
            guard let index = span.systemIndex, systems.contains(index),
                  span.commandRange.upperBound <= commands.count
            else { continue }
            paint(commands[span.commandRange], pxPerMM: pxPerMM, offsetPx: offsetPx)
        }
    }

    /// Clips every later paint to the rectangle, in canvas pixels, inside any clip already pushed, until the matching
    /// `popClip()`. Every clip a frame pushes is popped before its `copyPixels(into:)`, which throws otherwise.
    public func pushClip(x: Double, y: Double, width: Double, height: Double) throws {
        try Direct2DPageRenderer.check(
            cd2d_push_clip(canvas, Float(x), Float(y), Float(width), Float(height)), "pushing a clip",
        )
    }

    /// Ends the innermost `pushClip(x:y:width:height:)`.
    public func popClip() throws {
        try Direct2DPageRenderer.check(cd2d_pop_clip(canvas), "popping a clip")
    }

    /// Draws `pixels` — BGRA premultiplied, `widthPx` x `heightPx`, top-down, `widthPx * 4` bytes a row — stretched
    /// over the rectangle (canvas pixels) at `opacity` (0...1): a picture rasterized once and composited every frame,
    /// such as a wordmark at one opacity over the whole mark.
    public func draw(
        pixels: UnsafeRawBufferPointer, widthPx: Int, heightPx: Int,
        in rect: (x: Double, y: Double, width: Double, height: Double), opacity: Double,
    ) throws {
        let needed = widthPx * heightPx * 4
        guard widthPx > 0, heightPx > 0, pixels.count >= needed, let base = pixels.baseAddress else {
            let invalidArgument = Int32(bitPattern: 0x8007_0057) // E_INVALIDARG
            throw Direct2DPageRenderer.Failure(
                step: "drawing a \(widthPx) x \(heightPx) picture from \(pixels.count) bytes", hresult: invalidArgument,
            )
        }
        try Direct2DPageRenderer.check(
            cd2d_draw_bitmap(
                canvas, base.assumingMemoryBound(to: UInt8.self), UInt32(widthPx), UInt32(heightPx), Float(rect.x),
                Float(rect.y), Float(rect.width), Float(rect.height), Float(opacity),
            ),
            "drawing a picture",
        )
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
