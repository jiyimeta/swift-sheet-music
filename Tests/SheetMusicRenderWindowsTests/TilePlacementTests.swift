@testable import SheetMusicBridgeCore
@testable import SheetMusicRenderWindows
import Testing

@Suite("TilePlacement")
struct TilePlacementTests {
    /// Two 400 x 500 mm pages at 4 px/mm — 1600 x 2000 px each: two columns, four rows, the last 464 px — stacked
    /// 40 px apart, under a 1600 x 700 px surface scrolled `y` px down from the first page's top.
    private func pages(scrolledTo y: Double) -> [PlacedPage] {
        let grid = TileGrid(page: EncodablePage(widthMM: 400, heightMM: 500, commands: []), pxPerMM: 4)
        return [
            PlacedPage(index: 0, grid: grid, screenX: 0, screenY: -y),
            PlacedPage(index: 1, grid: grid, screenX: 0, screenY: 2040 - y),
        ]
    }

    /// Each tile as [page, column, row], in the order given.
    private func ids(_ tiles: [PlacedTile]) -> [[Int]] {
        tiles.map { [$0.key.page, $0.key.column, $0.key.row] }
    }

    private func band(scrolledTo y: Double, downward: Bool) -> [[Int]] {
        ids(TilePlacement.nextBand(
            pages: pages(scrolledTo: y), widthPx: 1600, heightPx: 700, stretch: 1, downward: downward,
        ))
    }

    @Test("the surface shows the tiles of both pages where it straddles the gap")
    func visibleAcrossPages() {
        // Page 0 px 1700 ..< 2401 (row 3), page 1 px -340 ..< 361 (row 0).
        let visible = TilePlacement.visible(pages: pages(scrolledTo: 1700), widthPx: 1600, heightPx: 700, stretch: 1)
        #expect(ids(visible) == [[0, 0, 3], [0, 1, 3], [1, 0, 0], [1, 1, 0]])
        #expect(visible.allSatisfy { $0.key.scale == TileKey.scaleKey(4) })
    }

    @Test("the next band is every column of the row below the view")
    func nextRowBothColumns() {
        // Shows rows 0 and 1 (px 0 ..< 701); the band is px 701 ..< 1213, of which only row 2 is not shown.
        #expect(band(scrolledTo: 0, downward: true) == [[0, 0, 2], [0, 1, 2]])
    }

    @Test("at a page's last row the band crosses into the next page")
    func crossesIntoNextPage() {
        // Shows page 0's rows 2 and 3 (px 1289 ..< 1990) and nothing of page 1, which starts 51 px below the surface.
        #expect(band(scrolledTo: 1289, downward: true) == [[1, 0, 0], [1, 1, 0]])
    }

    @Test("nearest the edge first: the page's last row, then the next page's first")
    func nearestFirst() {
        // Shows rows 1 and 2 (px 834 ..< 1535); row 3 starts 2 px below the surface, page 1 506 px below it.
        #expect(band(scrolledTo: 834, downward: true) == [[0, 0, 3], [0, 1, 3], [1, 0, 0], [1, 1, 0]])
    }

    @Test("scrolling up, the band lies above the view and crosses back into the page before")
    func upward() {
        // Page 1's top is at the view's top: the band is page 0's px 1528 ..< 2040, rows 3 then 2.
        #expect(band(scrolledTo: 2040, downward: false) == [[0, 0, 3], [0, 1, 3], [0, 0, 2], [0, 1, 2]])
        // Mid-page, only the row above the view.
        #expect(band(scrolledTo: 834, downward: false) == [[0, 0, 0], [0, 1, 0]])
    }

    @Test("nothing past the document's ends")
    func documentEnds() {
        #expect(band(scrolledTo: 0, downward: false).isEmpty)
        // Page 1's rows 2 and 3 fill the view's bottom (px 1340 ..< 2041 of page 1).
        #expect(band(scrolledTo: 3380, downward: true).isEmpty)
    }
}
