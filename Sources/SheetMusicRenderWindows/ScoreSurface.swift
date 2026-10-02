import CDirect2D
import Foundation
import SheetMusicBridgeCore

/// Draws a score's pages (`ScorePages`, via `setPages(_:)`) on screen on Windows: into a composition swap chain the app
/// attaches to its XAML `SwapChainPanel` (`attach`), or into a window (`attach(hwnd:…)`, for probes).
///
/// Pages are rasterized into tiles (`TileGrid`) by walking only the `SystemSpan`s that cross each tile, and kept in a
/// least-recently-drawn cache; each frame blits the visible tiles and draws the overlays (cursor, selection frames)
/// on top. Scrolling therefore costs a blit per frame plus, on frames that needed no new tile, one tile read ahead of
/// the view (`prefetch`), so a row arrives already cached rather than rasterized all in the frame it appears. While a
/// zoom gesture runs (`Frame.isGesture`), the tiles of the last settled scale are drawn scaled, and of the tiles the
/// view uncovers only one per frame is rasterized, the background showing where the others go; 100 ms after the
/// gesture's last frame the visible tiles are rasterized at the new scale, all of them in that one frame.
///
/// Use it on the thread that created it — the app's UI thread. Call `draw` from `CompositionTarget.Rendering` while
/// something moves (playback, a gesture, and until 100 ms after one ends), and otherwise only when the view changed.
/// Design: `docs/superpowers/specs/2026-09-30-ssm-4-c-windows-onscreen-render-design.md` in folino.
public final class ScoreSurface {
    /// How long after the last gesture frame the tiles are rasterized at the new scale.
    static let settleDelay: Duration = .milliseconds(100)
    static let cacheBytes = 64 << 20

    let resources: OpaquePointer
    private(set) var surface: OpaquePointer?
    private(set) var pages: [EncodablePage] = []
    private var spans: [[SystemSpan]] = []
    private(set) var tiles = TileLRU<OpaquePointer>(capacityBytes: ScoreSurface.cacheBytes)
    /// The `fillPath` overlays' shapes, by overlay id.
    var shapes = OverlayShapeCache()
    /// The scale the tiles on screen were rasterized at, while a gesture (and its settle delay) runs.
    private var settledPxPerMM: Double?
    private var lastGestureFrame: ContinuousClock.Instant?
    private var lastOriginY: Double?
    private(set) var widthPx = 1
    private(set) var heightPx = 1
    private let clock = ContinuousClock()

    /// What the last `draw` spent: rasterizing and composing the frame (`workMs`), then in `Present`, which waits for
    /// the display (`presentMs`); how many tiles it rasterized, and how many it left out.
    package private(set) var lastDrawTiming = DrawTiming()

    /// Loads the font files (Bravura, the Edwin faces) every walk draws with. `init()` loads the copies bundled with
    /// this module (`bundledFontFiles`); this is for a host that ships its own.
    public init(fontFiles: [String]) throws {
        var created: OpaquePointer?
        try Self.check(cd2d_resources_create(&created), "creating the Direct2D resources")
        guard let resources = created else { throw Failure(step: "creating the Direct2D resources", hresult: -1) }
        self.resources = resources
        for file in fontFiles {
            try Self.check(withWide(file) { cd2d_resources_add_font_file(resources, $0) }, "adding the font \(file)")
        }
        try Self.check(cd2d_resources_fonts_ready(resources), "building the font collection")
    }

    deinit {
        releaseAllTiles()
        shapes.releaseAll()
        if let surface { cd2d_surface_destroy(surface) }
        cd2d_resources_destroy(resources)
    }

    /// Creates the composition swap chain for a `SwapChainPanel` of `widthDIP` x `heightDIP` at its composition scale,
    /// and returns it with a reference the app releases after `ISwapChainPanelNative::SetSwapChain`.
    public func attach(
        widthDIP: Double, heightDIP: Double, compositionScaleX: Double, compositionScaleY: Double,
    ) throws -> UnsafeMutableRawPointer {
        detach()
        (widthPx, heightPx) = Self.pixels(widthDIP, heightDIP, compositionScaleX, compositionScaleY)
        var created: OpaquePointer?
        var swapChain: UnsafeMutableRawPointer?
        try Self.check(
            cd2d_surface_create_composition(
                &created, resources, UInt32(widthPx), UInt32(heightPx), Float(compositionScaleX),
                Float(compositionScaleY), &swapChain,
            ),
            "creating the swap chain",
        )
        surface = created
        guard let swapChain else { throw Failure(step: "creating the swap chain", hresult: -1) }
        return swapChain
    }

    /// A swap chain for the window `hwnd`, `widthPx` x `heightPx` — for probes that measure without XAML.
    package func attach(hwnd: UnsafeMutableRawPointer, widthPx: Int, heightPx: Int) throws {
        detach()
        (self.widthPx, self.heightPx) = (max(1, widthPx), max(1, heightPx))
        var created: OpaquePointer?
        try Self.check(
            cd2d_surface_create_hwnd(&created, resources, hwnd, UInt32(self.widthPx), UInt32(self.heightPx)),
            "creating the window's swap chain",
        )
        surface = created
    }

    /// The panel's new size or composition scale. Tiles are kept: a changed scale arrives through `Frame.pxPerMM`.
    public func resize(
        widthDIP: Double, heightDIP: Double, compositionScaleX: Double, compositionScaleY: Double,
    ) throws {
        guard let surface else { return }
        (widthPx, heightPx) = Self.pixels(widthDIP, heightDIP, compositionScaleX, compositionScaleY)
        try Self.check(
            cd2d_surface_resize(
                surface, UInt32(widthPx), UInt32(heightPx), Float(compositionScaleX), Float(compositionScaleY),
            ),
            "resizing the swap chain",
        )
    }

    package func resize(widthPx: Int, heightPx: Int) throws {
        guard let surface else { return }
        (self.widthPx, self.heightPx) = (max(1, widthPx), max(1, heightPx))
        try Self.check(
            cd2d_surface_resize(surface, UInt32(self.widthPx), UInt32(self.heightPx), 1, 1), "resizing the swap chain",
        )
    }

    /// Shows `pages`. When they have as many pages as those shown now, each the same size — a selection tint
    /// (`ScorePages.tinted(argb:ids:)`), an edit that kept the pagination — only the tiles crossing a system whose
    /// commands or frame changed are dropped and drawn again; otherwise every tile is.
    public func setPages(_ pages: ScorePages) {
        let sameShape = pages.pages.count == self.pages.count
            && zip(pages.pages, self.pages).allSatisfy { $0.widthMM == $1.widthMM && $0.heightMM == $1.heightMM }
        guard sameShape, !self.pages.isEmpty else {
            setPages(pages.pages, spans: pages.spans)
            return
        }
        for (index, page) in pages.pages.enumerated() {
            let pageSpans = index < pages.spans.count ? pages.spans[index] : []
            guard page != self.pages[index] || pageSpans != spans[index] else { continue }
            replaceCommands(page: index, commands: page.commands, spans: pageSpans)
        }
    }

    /// Replaces the document and drops every tile. `spans[i]` belongs to `pages[i]` (from `LayoutBridge.computePages`);
    /// a page without spans is walked whole for every tile.
    package func setPages(_ pages: [EncodablePage], spans: [[SystemSpan]]) {
        releaseAllTiles()
        self.pages = pages
        self.spans = pages.indices.map { $0 < spans.count ? spans[$0] : [] }
        settledPxPerMM = nil
    }

    /// Replaces one page's commands (a selection tint, an edit) and drops only the tiles the change can reach: those
    /// crossing a span whose commands or frame changed, before or after. The page keeps its size.
    package func replaceCommands(page: Int, commands: [DrawCommand], spans newSpans: [SystemSpan]) {
        guard pages.indices.contains(page) else { return }
        let old = pages[page]
        let oldSpans = spans[page]
        var dirty: [DrawRect] = []
        func bySystem(_ spans: [SystemSpan]) -> [Int: SystemSpan] {
            Dictionary(spans.map { ($0.systemIndex ?? -1, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let oldBySystem = bySystem(oldSpans)
        let newBySystem = bySystem(newSpans)
        for key in Set(oldBySystem.keys).union(newBySystem.keys) {
            switch (oldBySystem[key], newBySystem[key]) {
            case let (before?, after?):
                let changed = before.frameMM != after.frameMM
                    || old.commands[before.commandRange] != commands[after.commandRange]
                if changed {
                    dirty += [before.frameMM, after.frameMM]
                }
            case let (before?, nil): dirty.append(before.frameMM)
            case let (nil, after?): dirty.append(after.frameMM)
            case (nil, nil): break
            }
        }
        pages[page] = EncodablePage(widthMM: old.widthMM, heightMM: old.heightMM, commands: commands)
        spans[page] = newSpans
        if newSpans.isEmpty || oldSpans.isEmpty {
            releaseTiles { $0.page == page }
        } else if !dirty.isEmpty {
            releaseTiles { key in
                guard key.page == page else { return false }
                let grid = TileGrid(page: self.pages[page], pxPerMM: Double(key.scale) / 1000)
                let tile = grid.rectMM(column: key.column, row: key.row)
                return dirty.contains { $0.intersects(tile) }
            }
        }
    }

    /// Draws and presents one frame.
    public func draw(_ frame: Frame) -> DrawOutcome {
        guard let surface else { return .failed(hresult: Int32(bitPattern: 0x8000_FFFF)) } // E_UNEXPECTED
        let now = clock.now
        lastDrawTiming = DrawTiming()
        if frame.isGesture { lastGestureFrame = now }
        let settling = lastGestureFrame.map { now - $0 < Self.settleDelay } ?? false
        let rasterScale = (frame.isGesture || settling) ? (settledPxPerMM ?? frame.pxPerMM) : frame.pxPerMM
        if !frame.isGesture, !settling { settledPxPerMM = frame.pxPerMM } else if settledPxPerMM == nil {
            settledPxPerMM = rasterScale
        }
        let stretch = frame.pxPerMM / rasterScale
        let scaling = rasterScale != frame.pxPerMM
        lastDrawTiming.isScaled = scaling

        // Which tiles show, rasterized first: a band cannot be drawn while a frame is open.
        let placed = placedPages(frame, rasterScale: rasterScale)
        let visible = TilePlacement.visible(pages: placed, widthPx: widthPx, heightPx: heightPx, stretch: stretch)
        let onScreen = Set(visible.map(\.key))
        // While the scale moves — a gesture, and the settle delay after it — the old scale's tiles are drawn
        // stretched, and zooming out uncovers a ring of them at once: rasterizing all of those in one frame is what
        // overran the gesture's frame budget. So a scaled frame rasterizes at most one missing tile, the one nearest
        // the view's center, and leaves the rest to the background until a later frame or the settle. Every other
        // frame (the first, a scroll, the settle itself) rasterizes all it shows, so it is always complete.
        var missing = visible.filter { !tiles.contains($0.key) }
        if scaling, let nearest = nearestToCenter(missing, stretch: stretch) {
            lastDrawTiming.deferredTiles = missing.count - 1
            missing = [nearest]
        }
        for tile in missing {
            if let failure = rasterize(tile.key, grid: tile.page.grid, keep: onScreen) { return failure }
        }
        // Read-ahead only on a frame whose visible tiles were all cached — whatever the frame before it rasterized —
        // so a frame never pays for a tile it shows and one it does not. None while a gesture or its settle delay
        // runs: the tile would be at a scale about to be replaced.
        if missing.isEmpty, !frame.isGesture, !settling,
           let failure = prefetch(frame: frame, placed: placed, stretch: stretch, onScreen: onScreen)
        {
            return failure
        }
        lastOriginY = frame.originMM.y

        var hresult = cd2d_frame_begin(surface, frame.backgroundARGB)
        guard hresult == 0 else { return recover(hresult) }
        for tile in visible {
            guard let band = tiles.use(tile.key) else { continue }
            let rect = tile.rect
            cd2d_frame_draw_band(
                surface, band, Float(tile.page.screenX + Double(rect.x) * stretch),
                Float(tile.page.screenY + Double(rect.y) * stretch), Float(stretch),
            )
        }
        if let canvas = cd2d_frame_canvas(surface) {
            for overlay in frame.overlays {
                drawOverlay(overlay, frame: frame, canvas: canvas)
            }
        }
        shapes.endFrame()
        let presenting = clock.now
        lastDrawTiming.workMs = Self.milliseconds(presenting - now)
        hresult = cd2d_frame_present(surface)
        lastDrawTiming.presentMs = Self.milliseconds(clock.now - presenting)
        return hresult == 0 ? .presented : recover(hresult)
    }

    // MARK: - Private

    /// Rasterizes one tile; returns the outcome to report if the device was lost or drawing failed.
    private func rasterize(_ key: TileKey, grid: TileGrid, keep: Set<TileKey>) -> DrawOutcome? {
        guard let surface else { return nil }
        let rect = grid.rect(column: key.column, row: key.row)
        var band: OpaquePointer?
        var canvas: OpaquePointer?
        var hresult = cd2d_band_begin(surface, UInt32(rect.width), UInt32(rect.height), &band, &canvas)
        guard hresult == 0, let band, let canvas else { return recover(hresult) }
        let page = pages[key.page]
        let tileMM = grid.rectMM(column: key.column, row: key.row)
        let cull = DrawRect(x: 0, y: 0, width: Double(rect.width), height: Double(rect.height))
        for range in TileGrid.spans(crossing: tileMM, in: spans[key.page], commandCount: page.commands.count) {
            var walker = DrawCommandWalker(
                canvas: canvas, pxPerMM: grid.pxPerMM, offset: (Double(-rect.x), Double(-rect.y)), cull: cull,
            )
            walker.paint(page.commands[range])
        }
        hresult = cd2d_band_end(surface, band)
        lastDrawTiming.rasterizedTiles += 1
        guard hresult == 0 else {
            cd2d_band_release(surface, band)
            return recover(hresult)
        }
        for evicted in tiles.insert(key, band, bytes: rect.width * rect.height * 4, keep: keep) {
            cd2d_band_release(surface, evicted)
        }
        return nil
    }

    /// Every page the frame places, with its grid at `rasterScale` and its top-left on the surface.
    private func placedPages(_ frame: Frame, rasterScale: Double) -> [PlacedPage] {
        var placed: [PlacedPage] = []
        for (index, page) in pages.enumerated() where index < frame.pageOrigins.count {
            let (screenX, screenY) = Self.pageOffsetPx(index, frame)
            let grid = TileGrid(page: page, pxPerMM: rasterScale)
            placed.append(PlacedPage(index: index, grid: grid, screenX: screenX, screenY: screenY))
        }
        return placed
    }

    /// The candidate whose center lies nearest the view's, on screen; nil when there is none.
    private func nearestToCenter(_ candidates: [PlacedTile], stretch: Double) -> PlacedTile? {
        let centerX = Double(widthPx) / 2
        let centerY = Double(heightPx) / 2
        func distance(_ tile: PlacedTile) -> Double {
            let rect = tile.rect
            let dx = tile.page.screenX + (Double(rect.x) + Double(rect.width) / 2) * stretch - centerX
            let dy = tile.page.screenY + (Double(rect.y) + Double(rect.height) / 2) * stretch - centerY
            return dx * dx + dy * dy
        }
        return candidates.min { distance($0) < distance($1) }
    }

    /// Reads one tile ahead, so the cost of a row scrolling into view is spread over the frames before it instead of
    /// landing whole — every column, and at a page's end the next page's first row too — on the frame it appears.
    /// The tile is the first missing one of `TilePlacement.nextBand`: one tile height past the view's edge in the
    /// scroll direction (down when the origin did not move), nearest that edge, then left to right. It evicts no tile
    /// on screen or in that band, and is skipped when the cache could not hold it beside them within its cap. `draw`
    /// calls this only on a frame that rasterized nothing visible, outside a gesture and its settle delay.
    private func prefetch(
        frame: Frame, placed: [PlacedPage], stretch: Double, onScreen: Set<TileKey>,
    ) -> DrawOutcome? {
        let downward = frame.originMM.y >= (lastOriginY ?? frame.originMM.y)
        let band = TilePlacement.nextBand(
            pages: placed, widthPx: widthPx, heightPx: heightPx, stretch: stretch, downward: downward,
        )
        guard let next = band.first(where: { !tiles.contains($0.key) }) else { return nil }
        let keep = onScreen.union(band.map(\.key))
        guard tiles.fits(next.rect.width * next.rect.height * 4, keeping: keep) else { return nil }
        lastDrawTiming.prefetchedTiles += 1
        return rasterize(next.key, grid: next.page.grid, keep: keep)
    }

    /// After a failed draw: on device loss, a new device and swap chain, and every tile dropped.
    private func recover(_ hresult: Int32) -> DrawOutcome {
        guard hresult == CD2D_E_RECREATE, let surface else { return .failed(hresult: hresult) }
        releaseAllTiles()
        var swapChain: UnsafeMutableRawPointer?
        let rebuilt = cd2d_surface_recreate(surface, &swapChain)
        guard rebuilt == 0 else { return .failed(hresult: rebuilt) }
        return .deviceRecreated(newSwapChain: swapChain)
    }

    private func releaseTiles(where shouldRelease: (TileKey) -> Bool) {
        let released = tiles.removeAll(where: shouldRelease)
        guard let surface else { return }
        for band in released {
            cd2d_band_release(surface, band)
        }
    }

    private func releaseAllTiles() {
        releaseTiles { _ in true }
    }

    private func detach() {
        releaseAllTiles()
        if let surface {
            cd2d_surface_destroy(surface)
            self.surface = nil
        }
    }

    /// Where `frame` puts page `page`'s top-left on the surface, in whole pixels. The page's tiles, its overlays and
    /// `referencePixels` all place it from this one rounding, so they share a pixel grid.
    static func pageOffsetPx(_ page: Int, _ frame: Frame) -> (x: Double, y: Double) {
        (
            ((frame.pageOrigins[page].x - frame.originMM.x) * frame.pxPerMM).rounded(),
            ((frame.pageOrigins[page].y - frame.originMM.y) * frame.pxPerMM).rounded(),
        )
    }

    private static func pixels(_ width: Double, _ height: Double, _ scaleX: Double, _ scaleY: Double) -> (Int, Int) {
        (max(1, Int((width * scaleX).rounded(.up))), max(1, Int((height * scaleY).rounded(.up))))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func check(_ hresult: Int32, _ step: String) throws {
        guard hresult == 0 else { throw Failure(step: step, hresult: hresult) }
    }
}
