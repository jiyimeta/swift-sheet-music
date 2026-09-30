import CDirect2D
import Foundation
import SheetMusicBridgeCore

/// Draws draw-program pages on screen on Windows: into a composition swap chain the app attaches to its XAML
/// `SwapChainPanel` (`attach`), or into a window (`attach(hwnd:…)`, for probes).
///
/// Pages are rasterized into tiles (`TileGrid`) by walking only the `SystemSpan`s that cross each tile, and kept in a
/// least-recently-drawn cache; each frame blits the visible tiles and draws the overlays (cursor, selection frames)
/// on top. Scrolling therefore costs a blit per frame plus, now and then, a new row of tiles. While a zoom gesture runs
/// (`Frame.isGesture`), the tiles of the last settled scale are drawn scaled; 100 ms after the gesture's last frame the
/// visible tiles are rasterized at the new scale.
///
/// Use it on the thread that created it — the app's UI thread. Call `draw` from `CompositionTarget.Rendering` while
/// something moves (playback, a gesture, and until 100 ms after one ends), and otherwise only when the view changed.
/// Design: `docs/superpowers/specs/2026-09-30-ssm-4-c-windows-onscreen-render-design.md` in folino.
public final class ScoreSurface {
    /// How long after the last gesture frame the tiles are rasterized at the new scale.
    static let settleDelay: Duration = .milliseconds(100)
    static let cacheBytes = 64 << 20

    private let resources: OpaquePointer
    private var surface: OpaquePointer?
    private var pages: [EncodablePage] = []
    private var spans: [[SystemSpan]] = []
    private var tiles = TileLRU<OpaquePointer>(capacityBytes: ScoreSurface.cacheBytes)
    /// The scale the tiles on screen were rasterized at, while a gesture (and its settle delay) runs.
    private var settledPxPerMM: Double?
    private var lastGestureFrame: ContinuousClock.Instant?
    private var lastOriginY: Double?
    private var widthPx = 1
    private var heightPx = 1
    private let clock = ContinuousClock()

    /// What the last `draw` spent: rasterizing and composing the frame (`workMs`), then in `Present`, which waits for
    /// the display (`presentMs`), and how many tiles it rasterized.
    package private(set) var lastDrawTiming = DrawTiming()

    package struct DrawTiming {
        package var workMs = 0.0
        package var presentMs = 0.0
        package var rasterizedTiles = 0
    }

    /// Loads the font files (Bravura, the Edwin faces) every walk draws with.
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

    /// Replaces the document. `spans[i]` belongs to `pages[i]` (from `LayoutBridge.computePages`); a page without
    /// spans is walked whole for every tile.
    public func setPages(_ pages: [EncodablePage], spans: [[SystemSpan]]) {
        releaseAllTiles()
        self.pages = pages
        self.spans = pages.indices.map { $0 < spans.count ? spans[$0] : [] }
        settledPxPerMM = nil
    }

    /// Replaces one page's commands (a selection tint, an edit) and drops only the tiles the change can reach: those
    /// crossing a span whose commands or frame changed, before or after.
    public func replaceCommands(page: Int, commands: [DrawCommand], spans newSpans: [SystemSpan]) {
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

        // Which tiles show, rasterized first: a band cannot be drawn while a frame is open.
        var visible: [(key: TileKey, grid: TileGrid, screenX: Double, screenY: Double)] = []
        for (index, page) in pages.enumerated() where index < frame.pageOrigins.count {
            let grid = TileGrid(page: page, pxPerMM: rasterScale)
            let screenX = ((frame.pageOrigins[index].x - frame.originMM.x) * frame.pxPerMM).rounded()
            let screenY = ((frame.pageOrigins[index].y - frame.originMM.y) * frame.pxPerMM).rounded()
            // The screen, in the page's pixels at the raster scale.
            let view = PixelRect(
                x: Int((-screenX / stretch).rounded(.down)), y: Int((-screenY / stretch).rounded(.down)),
                width: Int((Double(widthPx) / stretch).rounded(.up)) + 1,
                height: Int((Double(heightPx) / stretch).rounded(.up)) + 1,
            )
            for tile in grid.tiles(intersecting: view) {
                let key = TileKey(page: index, column: tile.column, row: tile.row, scale: TileKey.scaleKey(rasterScale))
                visible.append((key, grid, screenX, screenY))
            }
        }
        let onScreen = Set(visible.map(\.key))
        for tile in visible where !tiles.contains(tile.key) {
            if let failure = rasterize(tile.key, grid: tile.grid, keep: onScreen) { return failure }
        }
        if let failure = prefetch(frame: frame, visible: visible.map { ($0.key, $0.grid) }, keep: onScreen) {
            return failure
        }
        lastOriginY = frame.originMM.y

        var hresult = cd2d_frame_begin(surface, frame.backgroundARGB)
        guard hresult == 0 else { return recover(hresult) }
        for tile in visible {
            guard let band = tiles.use(tile.key) else { continue }
            let rect = tile.grid.rect(column: tile.key.column, row: tile.key.row)
            cd2d_frame_draw_band(
                surface, band, Float(tile.screenX + Double(rect.x) * stretch),
                Float(tile.screenY + Double(rect.y) * stretch), Float(stretch),
            )
        }
        if let canvas = cd2d_frame_canvas(surface) {
            for overlay in frame.overlays {
                drawOverlay(overlay, frame: frame, canvas: canvas)
            }
        }
        let presenting = clock.now
        lastDrawTiming.workMs = Self.milliseconds(presenting - now)
        hresult = cd2d_frame_present(surface)
        lastDrawTiming.presentMs = Self.milliseconds(clock.now - presenting)
        return hresult == 0 ? .presented : recover(hresult)
    }

    // MARK: - For probes and tests

    /// The next band end or present fails with `hresult` (the device-loss path without losing a device).
    package func failNext(hresult: Int32) {
        if let surface { cd2d_surface_debug_fail_next(surface, hresult) }
    }

    /// The next frame is also copied into `pixels` (BGRA, `width` x `height`, top-down) just before it is presented.
    package func readBackNext(into pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) {
        if let surface { cd2d_surface_debug_read_back_next(surface, pixels, UInt32(width), UInt32(height)) }
    }

    package var tileCount: Int {
        tiles.count
    }

    package var tileBytes: Int {
        tiles.bytes
    }

    package var glyphCacheCount: Int {
        Int(cd2d_resources_glyph_cache_count(resources))
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

    /// One tile beyond the view in the direction of the scroll, when the view needed none: spreads the cost of a new
    /// row over frames that would otherwise be idle.
    private func prefetch(
        frame: Frame, visible: [(key: TileKey, grid: TileGrid)], keep: Set<TileKey>,
    ) -> DrawOutcome? {
        guard !frame.isGesture, let first = visible.first, let last = visible.last else { return nil }
        let downward = frame.originMM.y >= (lastOriginY ?? frame.originMM.y)
        let edge = downward ? last : first
        let row = edge.key.row + (downward ? 1 : -1)
        guard row >= 0, row < edge.grid.rows else { return nil }
        let key = TileKey(page: edge.key.page, column: edge.key.column, row: row, scale: edge.key.scale)
        guard !tiles.contains(key) else { return nil }
        return rasterize(key, grid: edge.grid, keep: keep)
    }

    private func drawOverlay(_ overlay: Overlay, frame: Frame, canvas: OpaquePointer) {
        let page: Int
        switch overlay {
        case let .fillRect(index, _, _), let .strokeRect(index, _, _, _), let .commands(index, _): page = index
        }
        guard frame.pageOrigins.indices.contains(page) else { return }
        let offset = (
            ((frame.pageOrigins[page].x - frame.originMM.x) * frame.pxPerMM).rounded(),
            ((frame.pageOrigins[page].y - frame.originMM.y) * frame.pxPerMM).rounded(),
        )
        var walker = DrawCommandWalker(canvas: canvas, pxPerMM: frame.pxPerMM, offset: offset)
        switch overlay {
        case let .fillRect(_, rect, argb):
            walker.paint([.setColor(argb: argb), .fillRect(x: rect.x, y: rect.y, w: rect.width, h: rect.height)][...])
        case let .strokeRect(_, rect, widthMM, argb):
            walker.paint([
                .setColor(argb: argb),
                .moveTo(x: rect.x, y: rect.y), .lineTo(x: rect.maxX, y: rect.y), .lineTo(x: rect.maxX, y: rect.maxY),
                .lineTo(x: rect.x, y: rect.maxY), .lineTo(x: rect.x, y: rect.y), .stroke(width: widthMM),
            ][...])
        case let .commands(_, commands):
            walker.paint(commands[...])
        }
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

    private static func pixels(_ width: Double, _ height: Double, _ scaleX: Double, _ scaleY: Double) -> (Int, Int) {
        (max(1, Int((width * scaleX).rounded(.up))), max(1, Int((height * scaleY).rounded(.up))))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func check(_ hresult: Int32, _ step: String) throws {
        guard hresult == 0 else { throw Failure(step: step, hresult: hresult) }
    }
}
