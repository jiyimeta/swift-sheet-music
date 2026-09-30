/// A page's tile grid at the raster scale, and where the page's top-left sits on the surface in whole pixels
/// (`ScoreSurface.pageOffsetPx`, at the frame's scale).
struct PlacedPage {
    var index: Int
    var grid: TileGrid
    var screenX: Double
    var screenY: Double
}

/// One tile of a placed page.
struct PlacedTile {
    var key: TileKey
    var page: PlacedPage

    /// The tile's rectangle in its page's pixels at the raster scale.
    var rect: PixelRect {
        page.grid.rect(column: key.column, row: key.row)
    }
}

/// Which tiles of the placed pages a surface shows, and which lie just beyond it: the geometry `ScoreSurface.draw` and
/// its read-ahead work from, free of Direct2D so it can be tested on its own. Every page is mapped through the same
/// per-page view, so a rectangle that runs off one page's end lands on the next page's grid by its own origin.
///
/// `widthPx` x `heightPx` is the surface; `stretch` is the frame's scale over the raster scale (1 unless a zoom gesture
/// draws the settled tiles scaled).
enum TilePlacement {
    /// The tiles the surface shows, page by page and, within a page, row by row.
    static func visible(pages: [PlacedPage], widthPx: Int, heightPx: Int, stretch: Double) -> [PlacedTile] {
        pages.flatMap { page in
            tiles(of: page, crossing: surfaceRect(on: page, widthPx: widthPx, heightPx: heightPx, stretch: stretch))
        }
    }

    /// The tiles the surface does not show that lie within one tile height (at the raster scale) past its bottom edge
    /// when `downward`, else past its top edge: every column of the next row, and the neighboring page's first (or
    /// last) row when the view is at a page's end. Nearest that edge first, then left to right.
    static func nextBand(
        pages: [PlacedPage], widthPx: Int, heightPx: Int, stretch: Double, downward: Bool,
    ) -> [PlacedTile] {
        var band: [PlacedTile] = []
        for page in pages {
            let view = surfaceRect(on: page, widthPx: widthPx, heightPx: heightPx, stretch: stretch)
            let shown = Set(tiles(of: page, crossing: view).map(\.key))
            let beyond = PixelRect(
                x: view.x, y: downward ? view.y + view.height : view.y - TileGrid.tileHeight,
                width: view.width, height: TileGrid.tileHeight,
            )
            band += tiles(of: page, crossing: beyond).filter { !shown.contains($0.key) }
        }
        /// On the surface: how far past the edge the tile begins, then where its left side is.
        func order(_ tile: PlacedTile) -> (Double, Double) {
            let rect = tile.rect
            let top = tile.page.screenY + Double(rect.y) * stretch
            let bottom = top + Double(rect.height) * stretch
            let left = tile.page.screenX + Double(rect.x) * stretch
            return (downward ? top - Double(heightPx) : -bottom, left)
        }
        return band.sorted { order($0) < order($1) }
    }

    /// The surface in the page's pixels at the raster scale, one pixel wider and taller to cover the rounding.
    private static func surfaceRect(on page: PlacedPage, widthPx: Int, heightPx: Int, stretch: Double) -> PixelRect {
        PixelRect(
            x: Int((-page.screenX / stretch).rounded(.down)), y: Int((-page.screenY / stretch).rounded(.down)),
            width: Int((Double(widthPx) / stretch).rounded(.up)) + 1,
            height: Int((Double(heightPx) / stretch).rounded(.up)) + 1,
        )
    }

    private static func tiles(of page: PlacedPage, crossing rect: PixelRect) -> [PlacedTile] {
        let scale = TileKey.scaleKey(page.grid.pxPerMM)
        return page.grid.tiles(intersecting: rect).map { tile in
            PlacedTile(key: TileKey(page: page.index, column: tile.column, row: tile.row, scale: scale), page: page)
        }
    }
}
