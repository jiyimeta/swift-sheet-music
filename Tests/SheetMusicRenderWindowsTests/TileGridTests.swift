@testable import SheetMusicBridgeCore
@testable import SheetMusicRenderWindows
import Testing

@Suite("TileGrid")
struct TileGridTests {
    /// A4 at 4 px/mm: 840 x 1188 px, so one column and three rows, the last cut to 164 px.
    private let grid = TileGrid(page: EncodablePage(widthMM: 210, heightMM: 297, commands: []), pxPerMM: 4)

    @Test("sizes a page in whole pixels, rounding up")
    func pageSize() {
        #expect(grid.pageWidthPx == 840)
        #expect(grid.pageHeightPx == 1188)
        #expect(grid.columns == 1)
        #expect(grid.rows == 3)
    }

    @Test("cuts the last row and column to the page")
    func lastTileIsCut() {
        #expect(grid.rect(column: 0, row: 2) == PixelRect(x: 0, y: 1024, width: 840, height: 164))
        let wide = TileGrid(page: EncodablePage(widthMM: 700, heightMM: 50, commands: []), pxPerMM: 4)
        #expect(wide.columns == 3) // 2800 px
        #expect(wide.rect(column: 2, row: 0) == PixelRect(x: 2048, y: 0, width: 752, height: 200))
    }

    @Test("a tile's millimetres are its pixels over the scale")
    func tileMillimetres() {
        #expect(grid.rectMM(column: 0, row: 1) == DrawRect(x: 0, y: 128, width: 210, height: 128))
    }

    @Test("finds the tiles a view crosses, and none for a view off the page")
    func visibleTiles() {
        let middle = grid.tiles(intersecting: PixelRect(x: 100, y: 400, width: 300, height: 300))
        #expect(middle.map(\.row) == [0, 1])
        #expect(middle.allSatisfy { $0.column == 0 })
        #expect(grid.tiles(intersecting: PixelRect(x: -500, y: -500, width: 400, height: 400)).isEmpty)
        #expect(grid.tiles(intersecting: PixelRect(x: 0, y: 1188, width: 100, height: 100)).isEmpty)
        // A view larger than the page shows every tile once.
        #expect(grid.tiles(intersecting: PixelRect(x: -10, y: -10, width: 2000, height: 2000)).count == 3)
    }

    @Test("walks only the spans whose frame crosses the tile, or everything without spans")
    func spansCrossing() {
        let spans = [
            SystemSpan(systemIndex: nil, commandRange: 0 ..< 5, frameMM: DrawRect(x: 0, y: 0, width: 210, height: 30)),
            SystemSpan(systemIndex: 0, commandRange: 5 ..< 20, frameMM: DrawRect(x: 0, y: 30, width: 210, height: 60)),
            SystemSpan(
                systemIndex: 1, commandRange: 20 ..< 40, frameMM: DrawRect(x: 0, y: 120, width: 210, height: 60),
            ),
        ]
        let second = grid.rectMM(column: 0, row: 1) // y 128 ..< 256
        #expect(TileGrid.spans(crossing: second, in: spans, commandCount: 40) == [20 ..< 40])
        let first = grid.rectMM(column: 0, row: 0) // y 0 ..< 128
        #expect(TileGrid.spans(crossing: first, in: spans, commandCount: 40) == [0 ..< 5, 5 ..< 20, 20 ..< 40])
        #expect(TileGrid.spans(crossing: first, in: [], commandCount: 40) == [0 ..< 40])
    }

    @Test("the scale key finds a zoom that came back")
    func scaleKey() {
        #expect(TileKey.scaleKey(3.7795275590551185) == TileKey.scaleKey(3.779527559055118))
        #expect(TileKey.scaleKey(3.78) != TileKey.scaleKey(3.779))
    }
}

@Suite("TileLRU")
struct TileLRUTests {
    private func key(_ row: Int) -> TileKey {
        TileKey(page: 0, column: 0, row: row, scale: 4000)
    }

    @Test("evicts the least recently used over the budget")
    func evictsOldest() {
        var cache = TileLRU<Int>(capacityBytes: 300)
        #expect(cache.insert(key(0), 0, bytes: 100).isEmpty)
        #expect(cache.insert(key(1), 1, bytes: 100).isEmpty)
        #expect(cache.insert(key(2), 2, bytes: 100).isEmpty)
        _ = cache.use(key(0)) // 1 is now the oldest
        #expect(cache.insert(key(3), 3, bytes: 100) == [1])
        #expect(cache.count == 3)
        #expect(cache.bytes == 300)
        #expect(!cache.contains(key(1)))
    }

    @Test("never evicts a tile on screen, even over budget")
    func keepsWhatIsShown() {
        var cache = TileLRU<Int>(capacityBytes: 200)
        _ = cache.insert(key(0), 0, bytes: 100)
        _ = cache.insert(key(1), 1, bytes: 100)
        let evicted = cache.insert(key(2), 2, bytes: 100, keep: [key(0), key(1)])
        #expect(evicted.isEmpty)
        #expect(cache.bytes == 300)
    }

    @Test("replacing a key hands back the old value")
    func replaces() {
        var cache = TileLRU<Int>(capacityBytes: 1000)
        _ = cache.insert(key(0), 10, bytes: 100)
        #expect(cache.insert(key(0), 11, bytes: 100) == [10])
        #expect(cache.bytes == 100)
        #expect(cache.use(key(0)) == 11)
    }

    @Test("removes by key")
    func removesWhere() {
        var cache = TileLRU<Int>(capacityBytes: 1000)
        for row in 0 ..< 4 {
            _ = cache.insert(key(row), row, bytes: 100)
        }
        #expect(Set(cache.removeAll { $0.row.isMultiple(of: 2) }) == [0, 2])
        #expect(cache.count == 2)
        #expect(cache.bytes == 200)
    }
}
