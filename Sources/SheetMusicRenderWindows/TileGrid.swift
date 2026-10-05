import SheetMusicBridgeCore

/// Pure geometry of the tiles `ScoreSurface` rasterizes a page into: which tiles a view shows, where each sits, which
/// spans cross it. No Direct2D here, so it can be tested on its own.
///
/// A tile is `width` x `height` pixels of a page at one scale, with its origin at whole pixels (so blitting it 1:1
/// never resamples, and tiles meet without seams). The last column and row are cut to the page.
struct TileGrid {
    /// Wide enough that a vertical-mode page at a reading zoom is one or two columns — every system on a tile row is
    /// walked once per column — and short enough that a scroll step rasterizes little at a time.
    static let tileWidth = 1024
    static let tileHeight = 512

    /// The page's size in pixels at the grid's scale.
    let pageWidthPx: Int
    let pageHeightPx: Int
    let pxPerMM: Double

    init(page: EncodablePage, pxPerMM: Double) {
        self.pxPerMM = pxPerMM
        pageWidthPx = max(1, Int((page.widthMM * pxPerMM).rounded(.up)))
        pageHeightPx = max(1, Int((page.heightMM * pxPerMM).rounded(.up)))
    }

    var columns: Int {
        (pageWidthPx + Self.tileWidth - 1) / Self.tileWidth
    }

    var rows: Int {
        (pageHeightPx + Self.tileHeight - 1) / Self.tileHeight
    }

    /// The tile's rectangle in page pixels.
    func rect(column: Int, row: Int) -> PixelRect {
        let x = column * Self.tileWidth
        let y = row * Self.tileHeight
        return PixelRect(
            x: x, y: y, width: min(Self.tileWidth, pageWidthPx - x), height: min(Self.tileHeight, pageHeightPx - y),
        )
    }

    /// The tile's rectangle in page millimetres.
    func rectMM(column: Int, row: Int) -> DrawRect {
        let pixels = rect(column: column, row: row)
        return DrawRect(
            x: Double(pixels.x) / pxPerMM, y: Double(pixels.y) / pxPerMM,
            width: Double(pixels.width) / pxPerMM, height: Double(pixels.height) / pxPerMM,
        )
    }

    /// The tiles that intersect `visible` (page pixels), row by row.
    func tiles(intersecting visible: PixelRect) -> [(column: Int, row: Int)] {
        let left = max(0, visible.x)
        let top = max(0, visible.y)
        let right = min(pageWidthPx, visible.x + visible.width)
        let bottom = min(pageHeightPx, visible.y + visible.height)
        guard left < right, top < bottom else { return [] }
        var tiles: [(column: Int, row: Int)] = []
        for row in (top / Self.tileHeight) ... ((bottom - 1) / Self.tileHeight) {
            for column in (left / Self.tileWidth) ... ((right - 1) / Self.tileWidth) {
                tiles.append((column, row))
            }
        }
        return tiles
    }

    /// The spans a tile has to walk: those whose frame crosses it. A page without spans is one span of everything.
    static func spans(crossing tile: DrawRect, in spans: [SystemSpan], commandCount: Int) -> [Range<Int>] {
        guard !spans.isEmpty else { return [0 ..< commandCount] }
        return spans.filter { $0.frameMM.intersects(tile) }.map(\.commandRange)
    }
}

/// A rectangle in whole pixels.
struct PixelRect: Hashable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

/// Which tile, at which scale. The scale is kept to a thousandth of a pixel per millimetre, so a zoom that returns to
/// where it was finds its tiles again.
struct TileKey: Hashable {
    var page: Int
    var column: Int
    var row: Int
    var scale: Int64

    static func scaleKey(_ pxPerMM: Double) -> Int64 {
        Int64((pxPerMM * 1000).rounded())
    }
}

/// Least-recently-drawn eviction over a byte budget. `Value` is what the caller frees on eviction.
struct TileLRU<Value> {
    private struct Entry {
        var value: Value
        var bytes: Int
        var lastUse: UInt64
    }

    let capacityBytes: Int
    private var entries: [TileKey: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var bytes = 0

    init(capacityBytes: Int) {
        self.capacityBytes = capacityBytes
    }

    var count: Int {
        entries.count
    }

    /// The value, marked as just used.
    mutating func use(_ key: TileKey) -> Value? {
        guard entries[key] != nil else { return nil }
        clock += 1
        entries[key]?.lastUse = clock
        return entries[key]?.value
    }

    func contains(_ key: TileKey) -> Bool {
        entries[key] != nil
    }

    /// The most recently used entry whose key matches, left unmarked; nil when none does.
    func latest(where matches: (TileKey) -> Bool) -> (key: TileKey, value: Value)? {
        entries.filter { matches($0.key) }.max { $0.value.lastUse < $1.value.lastUse }.map { ($0.key, $0.value.value) }
    }

    /// Whether `extra` more bytes stay within the budget once everything outside `keep` has been evicted for them.
    func fits(_ extra: Int, keeping keep: Set<TileKey>) -> Bool {
        keep.reduce(extra) { $0 + (entries[$1]?.bytes ?? 0) } <= capacityBytes
    }

    /// Inserts `value` and returns what had to go to stay within the budget — never the value just inserted, and
    /// never a key in `keep` (the tiles on screen now, and for a read-ahead its band), even if that leaves the cache
    /// over budget.
    mutating func insert(_ key: TileKey, _ value: Value, bytes: Int, keep: Set<TileKey> = []) -> [Value] {
        clock += 1
        var evicted: [Value] = []
        if let old = entries.removeValue(forKey: key) {
            self.bytes -= old.bytes
            evicted.append(old.value)
        }
        entries[key] = Entry(value: value, bytes: bytes, lastUse: clock)
        self.bytes += bytes
        while self.bytes > capacityBytes {
            let candidates = entries.filter { $0.key != key && !keep.contains($0.key) }
            guard let oldest = candidates.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            self.bytes -= oldest.value.bytes
            entries.removeValue(forKey: oldest.key)
            evicted.append(oldest.value.value)
        }
        return evicted
    }

    /// Removes and returns every value whose key matches.
    mutating func removeAll(where shouldRemove: (TileKey) -> Bool) -> [Value] {
        let doomed = entries.keys.filter(shouldRemove)
        return doomed.compactMap { key in
            guard let entry = entries.removeValue(forKey: key) else { return nil }
            bytes -= entry.bytes
            return entry.value
        }
    }
}
