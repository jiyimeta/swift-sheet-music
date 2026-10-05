import SheetMusicBridgeCore

/// Where a `ScorePages` draws its document's points, and back: a document point's page and its position there in
/// millimetres. In `.page` mode each page shows the document lifted by where that page starts and moved in by the
/// leading and top margins; `.vertical` and `.horizontal` draw one page with neither.
///
/// For a host that puts its own marks on the pages as overlays — ink, a playback cursor, a selection outline it
/// computed from the `LayoutDocument`. The numbers are the ones the drawing used, so the marks cannot drift from the
/// music.
public struct ScorePagePlacement: Sendable, Equatable {
    /// The bridge's placement, which is not a product type: this one is how a Windows host names it.
    let bridge: LayoutBridge.PagePlacement

    init(_ bridge: LayoutBridge.PagePlacement) {
        self.bridge = bridge
    }

    /// Each page's top in document points: what its music was lifted by. Page 0's is 0, so the title block stays on
    /// it.
    public var pageTopsPt: [Double] {
        bridge.pageTopsPt
    }

    /// From a page's top-left corner to its music's, in millimetres: the margins in `.page` mode, else zero.
    public var contentOffsetMM: PagePointMM {
        PagePointMM(x: bridge.contentOffsetXMM, y: bridge.contentOffsetYMM)
    }

    public var pageCount: Int {
        bridge.pageCount
    }

    /// The page a document `y` (points) falls on: the last one whose top is at or above it — page 0 for anything above
    /// every top — or `nil` when there are no pages.
    public func page(containingDocumentY y: Double) -> Int? {
        bridge.page(containingDocumentY: y)
    }

    /// A document point (points) in page `page`'s millimetres. `page` must be below `pageCount`.
    public func pageMM(fromDocumentX x: Double, y: Double, page: Int) -> PagePointMM {
        let point = bridge.pageMM(fromDocumentX: x, y: y, page: page)
        return PagePointMM(x: point.x, y: point.y)
    }

    /// A point in page `page`'s millimetres, in document points. The inverse of `pageMM(fromDocumentX:y:page:)`.
    public func documentPoint(fromPage page: Int, _ point: PagePointMM) -> (x: Double, y: Double) {
        bridge.documentPoint(fromPage: page, xMM: point.x, yMM: point.y)
    }
}
