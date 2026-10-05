import CDirect2D
import SheetMusicBridgeCore

/// A PDF's pages on the surface: drawn by the OS's PDF engine (`ScorePDF`) on a thread of its own
/// (`PDFPageWorker`), cached a page at a time, and blitted by every frame.
///
/// A PDF page costs what its content costs however little of it is drawn — up to 300 ms for a dense page on folino's QA
/// machine — so it is cached by the page rather than by the tile (`PDFPageRaster`): each page the view shows is drawn
/// whole once per settled scale, past the cap the part around the view. And it is never drawn in a frame: each frame
/// asks the worker for the pages it lacks, nearest the view's center first and one page ahead in the scroll direction
/// last, uploads what the worker has finished, and shows the rest as best it can — the page at another scale it has,
/// stretched, else the background. A host keeps drawing while `isDrawingPDFPages` is true, so the pages arrive.
///
/// A page Windows cannot draw (damaged content) is not asked for again: it shows blank, and `unreadablePDFPages`
/// names it. A lost device is the worker's own business (it makes a new one) or the surface's (`recover`, which drops
/// every page drawn; the worker draws them again).
extension ScoreSurface {
    /// One PDF page a frame shows: its placement, and what of it the view needs drawn (`PDFPageRaster.needed`).
    struct ShownPDFPage {
        var key: TileKey
        var page: PlacedPage
        var needed: PixelRect
    }

    /// Shows `pdf`'s pages at their own sizes where `setPages` shows a score's: the same `Frame`, the same page
    /// placement (millimetres from each paper's top-left) and the same overlays. Replaces whatever was shown before.
    /// The pages are drawn off the UI thread: keep drawing frames while `isDrawingPDFPages` is true.
    public func setPDF(_ pdf: ScorePDF) {
        let pages = (0 ..< pdf.pageCount).map { page in
            let size = pdf.pageSizeMM(page)
            return EncodablePage(widthMM: size.width, heightMM: size.height, commands: [])
        }
        setPages(pages, spans: [])
        self.pdf = pdf
        pdfWorker = PDFPageWorker(pdf: pdf)
    }

    /// Whether PDF pages the last frame asked for are still being drawn, or are drawn and not yet shown. While it is
    /// true a host keeps calling `draw` — from `CompositionTarget.Rendering` — so they appear; a score's pages never
    /// wait like this (every frame draws all of them that show).
    public var isDrawingPDFPages: Bool {
        pdfWorker?.isBusy ?? false
    }

    /// The PDF's pages for `frame`: uploads what the worker finished, asks it for what is missing, and lists for the
    /// frame to blit what there is.
    func preparePDF(
        _: ScorePDF, frame: Frame, placed: [PlacedPage], stretch: Double, moving: Bool, into blits: inout [Blit],
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
        if let failure = uploadFinishedPDFPages(keep: onScreen) { return failure }

        let missing = shown.filter { item in
            guard !unreadablePDFPages.contains(item.key.page) else { return false }
            guard let raster = pdfRasters.use(item.key) else { return true }
            return !PDFPageRaster.covers(raster.rect, item.needed)
        }
        lastDrawTiming.deferredTiles = missing.count
        var jobs = missing.sorted { distanceToCenter($0, stretch: stretch) < distanceToCenter($1, stretch: stretch) }
            .map { item in
                let grid = item.page.grid
                let rect = PDFPageRaster.drawn(
                    needed: item.needed, pageWidthPx: grid.pageWidthPx, pageHeightPx: grid.pageHeightPx,
                )
                return PDFPageWorker.Job(key: item.key, rect: rect, pxPerMM: grid.pxPerMM)
            }
        // None while the scale moves: the page would be at a scale about to be replaced.
        if !moving, let ahead = readAheadJob(frame: frame, placed: placed, shown: shown, onScreen: onScreen) {
            jobs.append(ahead)
        }
        pdfWorker?.want(jobs)

        for item in shown {
            if let raster = pdfRasters.use(item.key) {
                blits.append(Blit(band: raster.band, page: item.page, rect: raster.rect, stretch: stretch))
            } else if let (other, raster) = pdfRasters.latest(where: { $0.page == item.key.page }) {
                // The page at another scale, stretched to this frame's, until this scale's arrives.
                let otherStretch = frame.pxPerMM / (Double(other.scale) / 1000)
                blits.append(Blit(band: raster.band, page: item.page, rect: raster.rect, stretch: otherStretch))
            }
        }
        return nil
    }

    /// Uploads every page the worker finished into a band and caches it, evicting nothing in `keep`. A page Windows
    /// could not draw is recorded and never asked for again: retried every frame, it would fail every frame.
    private func uploadFinishedPDFPages(keep: Set<TileKey>) -> DrawOutcome? {
        guard let surface, let worker = pdfWorker else { return nil }
        for done in worker.takeFinished() {
            switch done.outcome {
            case .failed:
                unreadablePDFPages.insert(done.job.key.page)
            case let .drawn(pixels):
                let rect = done.job.rect
                var band: OpaquePointer?
                let hresult = pixels.withUnsafeBufferPointer { buffer in
                    cd2d_band_from_pixels(surface, UInt32(rect.width), UInt32(rect.height), buffer.baseAddress, &band)
                }
                guard hresult == 0, let band else { return recover(hresult) }
                lastDrawTiming.rasterizedTiles += 1
                let raster = PDFRaster(band: band, rect: rect)
                let bytes = rect.width * rect.height * 4
                for evicted in pdfRasters.insert(done.job.key, raster, bytes: bytes, keep: keep) {
                    cd2d_band_release(surface, evicted.band)
                }
            }
        }
        return nil
    }

    /// The page after the last one shown (before the first when the view moved up), whole — only when it fits the cap,
    /// is neither drawn at this scale nor unreadable, and fits the cache beside the pages on screen.
    private func readAheadJob(
        frame: Frame, placed: [PlacedPage], shown: [ShownPDFPage], onScreen: Set<TileKey>,
    ) -> PDFPageWorker.Job? {
        guard let first = shown.first, let last = shown.last else { return nil }
        let downward = frame.originMM.y >= (lastOriginY ?? frame.originMM.y)
        let index = downward ? last.page.index + 1 : first.page.index - 1
        guard let next = placed.first(where: { $0.index == index }), !unreadablePDFPages.contains(index) else {
            return nil
        }
        let width = next.grid.pageWidthPx
        let height = next.grid.pageHeightPx
        let key = TileKey(page: index, column: 0, row: 0, scale: TileKey.scaleKey(next.grid.pxPerMM))
        guard PDFPageRaster.fitsWhole(width, height), !pdfRasters.contains(key),
              pdfRasters.fits(width * height * 4, keeping: onScreen.union([key]))
        else { return nil }
        return PDFPageWorker.Job(
            key: key, rect: PixelRect(x: 0, y: 0, width: width, height: height), pxPerMM: next.grid.pxPerMM,
        )
    }

    /// How far, squared, the middle of what `item` needs lies from the view's center, on screen.
    private func distanceToCenter(_ item: ShownPDFPage, stretch: Double) -> Double {
        let rect = item.needed
        let dx = item.page.screenX + (Double(rect.x) + Double(rect.width) / 2) * stretch - Double(widthPx) / 2
        let dy = item.page.screenY + (Double(rect.y) + Double(rect.height) / 2) * stretch - Double(heightPx) / 2
        return dx * dx + dy * dy
    }
}
