import CDirect2D
import SheetMusicBridgeCore

/// A PDF's pages on the surface: drawn by the OS's PDF renderer (`ScorePDF`) into bands, a page at a time.
///
/// A PDF page costs what its content costs however little of it is drawn, so it is cached by the page rather than by
/// the tile (`PDFPageRaster`): each page the view shows is drawn whole once per settled scale — past the cap, the part
/// around the view — and every frame blits what is cached. The rest follows the score's tiles: while the scale moves
/// the settled scale's pages are drawn stretched and at most one missing page is drawn per frame; any other frame draws
/// every page it shows; and a frame that drew nothing reads one page ahead in the scroll direction.
extension ScoreSurface {
    /// One PDF page a frame shows: its placement, and what of it the view needs drawn (`PDFPageRaster.needed`).
    struct ShownPDFPage {
        var key: TileKey
        var page: PlacedPage
        var needed: PixelRect
    }

    /// Shows `pdf`'s pages at their own sizes where `setPages` shows a score's: the same `Frame`, the same page
    /// placement (millimetres from each paper's top-left) and the same overlays. Replaces whatever was shown before.
    public func setPDF(_ pdf: ScorePDF) {
        let pages = (0 ..< pdf.pageCount).map { page in
            let size = pdf.pageSizeMM(page)
            return EncodablePage(widthMM: size.width, heightMM: size.height, commands: [])
        }
        setPages(pages, spans: [])
        self.pdf = pdf
    }

    /// The PDF's pages for `frame`: draws those it needs, then lists the visible ones for the frame to blit.
    func preparePDF(
        _ pdf: ScorePDF, frame: Frame, placed: [PlacedPage], stretch: Double, moving: Bool, into blits: inout [Blit],
    ) -> DrawOutcome? {
        let shown = placed.compactMap { page -> ShownPDFPage? in
            let view = TilePlacement.surfaceRect(on: page, widthPx: widthPx, heightPx: heightPx, stretch: stretch)
            guard let needed = PDFPageRaster.needed(
                view: view, pageWidthPx: page.grid.pageWidthPx, pageHeightPx: page.grid.pageHeightPx,
            ) else { return nil }
            let key = TileKey(page: page.index, column: 0, row: 0, scale: TileKey.scaleKey(page.grid.pxPerMM))
            return ShownPDFPage(key: key, page: page, needed: needed)
        }
        let onScreen = Set(shown.map(\.key))
        var missing = shown.filter { item in
            guard let raster = pdfRasters.use(item.key) else { return true }
            return !PDFPageRaster.covers(raster.rect, item.needed)
        }
        // The score's rule, a page for a tile (`prepareTiles`): one page per frame while the scale moves, nearest the
        // view's center; every page it shows on any other frame.
        if lastDrawTiming.isScaled,
           let nearest = nearestToCenter(missing, stretch: stretch, placement: { ($0.page, $0.needed) })
        {
            lastDrawTiming.deferredTiles = missing.count - 1
            missing = [nearest]
        }
        for item in missing {
            let grid = item.page.grid
            let rect = PDFPageRaster.drawn(
                needed: item.needed, pageWidthPx: grid.pageWidthPx, pageHeightPx: grid.pageHeightPx,
            )
            if let failure = drawPDFPage(pdf, key: item.key, rect: rect, pxPerMM: grid.pxPerMM, keep: onScreen) {
                return failure
            }
        }
        if missing.isEmpty, !moving,
           let failure = prefetchPDFPage(pdf, frame: frame, placed: placed, shown: shown, onScreen: onScreen)
        {
            return failure
        }
        for item in shown {
            // A page drawn at the settled scale but not around where the view went: the part it has, until the next
            // frame draws the rest.
            guard let raster = pdfRasters.use(item.key) else { continue }
            blits.append(Blit(band: raster.band, page: item.page, rect: raster.rect, stretch: stretch))
        }
        return nil
    }

    /// Draws `rect` (page pixels at `pxPerMM`) of page `key.page` into a new band and caches it under `key`, replacing
    /// what the key held; returns the outcome to report if the device was lost or drawing failed.
    private func drawPDFPage(
        _ pdf: ScorePDF, key: TileKey, rect: PixelRect, pxPerMM: Double, keep: Set<TileKey>,
    ) -> DrawOutcome? {
        guard let surface else { return nil }
        var band: OpaquePointer?
        var canvas: OpaquePointer?
        var hresult = cd2d_band_begin(surface, UInt32(rect.width), UInt32(rect.height), &band, &canvas)
        guard hresult == 0, let band else { return recover(hresult) }
        let drawn = cd2d_band_draw_pdf(
            surface, pdf.handle, UInt32(key.page), Float(pxPerMM * ScorePDF.mmPerDIP), Float(rect.x), Float(rect.y),
        )
        hresult = cd2d_band_end(surface, band)
        if drawn != 0 { hresult = drawn }
        lastDrawTiming.rasterizedTiles += 1
        guard hresult == 0 else {
            cd2d_band_release(surface, band)
            return recover(hresult)
        }
        let raster = PDFRaster(band: band, rect: rect)
        for evicted in pdfRasters.insert(key, raster, bytes: rect.width * rect.height * 4, keep: keep) {
            cd2d_band_release(surface, evicted.band)
        }
        return nil
    }

    /// Reads one page ahead, as `prefetch` reads a tile: the page after the last one shown (before the first when the
    /// view moved up), whole — only when it fits the cap, is not drawn at this scale yet, and fits the cache beside
    /// the pages on screen.
    private func prefetchPDFPage(
        _ pdf: ScorePDF, frame: Frame, placed: [PlacedPage], shown: [ShownPDFPage], onScreen: Set<TileKey>,
    ) -> DrawOutcome? {
        guard let first = shown.first, let last = shown.last else { return nil }
        let downward = frame.originMM.y >= (lastOriginY ?? frame.originMM.y)
        let index = downward ? last.page.index + 1 : first.page.index - 1
        guard let next = placed.first(where: { $0.index == index }) else { return nil }
        let width = next.grid.pageWidthPx
        let height = next.grid.pageHeightPx
        let key = TileKey(page: index, column: 0, row: 0, scale: TileKey.scaleKey(next.grid.pxPerMM))
        let keep = onScreen.union([key])
        guard PDFPageRaster.fitsWhole(width, height), !pdfRasters.contains(key),
              pdfRasters.fits(width * height * 4, keeping: keep)
        else { return nil }
        lastDrawTiming.prefetchedTiles += 1
        let rect = PixelRect(x: 0, y: 0, width: width, height: height)
        return drawPDFPage(pdf, key: key, rect: rect, pxPerMM: next.grid.pxPerMM, keep: keep)
    }
}
