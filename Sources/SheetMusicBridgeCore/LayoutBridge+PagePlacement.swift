import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat`, clashing with SheetMusicLayout's stub. Anchor
    /// to the Layout definition.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

extension LayoutBridge {
    /// Where `encodePagesWithSpans` draws a document's points, and back. In `.page` mode each page shows the document
    /// lifted by where that page starts and moved in by the leading and top margins; `.vertical` and `.horizontal`
    /// draw one page with neither.
    ///
    /// For a host that puts its own marks on the pages — ink, a playback cursor, a selection outline it computed from
    /// the `LayoutDocument` — rather than having the draw program carry them.
    public struct PagePlacement: Sendable, Equatable {
        /// Each page's top in document points: what its music was lifted by. Page 0's is 0, so the title frame stays
        /// on it.
        public let pageTopsPt: [Double]
        /// From a page's top-left corner to its music's, in millimetres: the margins in `.page` mode, else zero.
        public let contentOffsetXMM: Double
        public let contentOffsetYMM: Double

        public init(pageTopsPt: [Double], contentOffsetXMM: Double, contentOffsetYMM: Double) {
            self.pageTopsPt = pageTopsPt
            self.contentOffsetXMM = contentOffsetXMM
            self.contentOffsetYMM = contentOffsetYMM
        }

        public var pageCount: Int {
            pageTopsPt.count
        }

        /// The page a document `y` (points) falls on: the last one whose top is at or above it — page 0 for anything
        /// above every top — or `nil` when there are no pages.
        public func page(containingDocumentY y: Double) -> Int? {
            guard !pageTopsPt.isEmpty else { return nil }
            return pageTopsPt.lastIndex { $0 <= y } ?? 0
        }

        /// A document point (points) in page `page`'s millimetres. `page` must be below `pageCount`.
        public func pageMM(fromDocumentX x: Double, y: Double, page: Int) -> (x: Double, y: Double) {
            (x * Self.ptToMM + contentOffsetXMM, (y - pageTopsPt[page]) * Self.ptToMM + contentOffsetYMM)
        }

        /// A point in page `page`'s millimetres, in document points. The inverse of `pageMM(fromDocumentX:y:page:)`.
        public func documentPoint(fromPage page: Int, xMM: Double, yMM: Double) -> (x: Double, y: Double) {
            ((xMM - contentOffsetXMM) / Self.ptToMM, (yMM - contentOffsetYMM) / Self.ptToMM + pageTopsPt[page])
        }

        private static let ptToMM = 25.4 / 72.0
    }

    /// The placement `encodePagesWithSpans` uses for these arguments — the same pagination, page tops and margins.
    public static func pagePlacement(
        document: LayoutDocument,
        options optionsWire: LayoutOptionsWire,
        pageHeightMM: Double,
        margins: PageMargins = .zero,
    ) -> PagePlacement {
        guard optionsWire.mode == .page else {
            return PagePlacement(pageTopsPt: [0], contentOffsetXMM: 0, contentOffsetYMM: 0)
        }
        let ranges = pageRanges(document: document, options: optionsWire, pageHeightMM: pageHeightMM, margins: margins)
        return PagePlacement(
            pageTopsPt: ranges.map { pageTop(of: $0, in: document) },
            contentOffsetXMM: margins.leading,
            contentOffsetYMM: margins.top,
        )
    }

    /// `.page` mode's cut: the systems each page holds, by the printable height.
    static func pageRanges(
        document: LayoutDocument, options optionsWire: LayoutOptionsWire, pageHeightMM: Double, margins: PageMargins,
    ) -> [Range<Int>] {
        // `.zero` subtracts nothing, so the edge-to-edge page is cut at `pageHeightMM` exactly as before margins.
        let pageHeightPt = CGFloat(margins.printableHeightMM(pageHeightMM: pageHeightMM) * (72.0 / 25.4))
        return LayoutPaginator.paginate(
            systems: document.systems, pageHeight: pageHeightPt, policy: optionsWire.breakPolicy,
        )
    }

    /// Where a page's music starts in the document, in points. The first page keeps y = 0 (so the title frame stays
    /// visible); later pages start at the previous system's bottom, so the gap above the page's first system renders
    /// on it. `Double`, not `CGFloat`: off Apple this file's `CGFloat` is a private alias an internal signature cannot
    /// name.
    static func pageTop(of range: Range<Int>, in document: LayoutDocument) -> Double {
        guard range.lowerBound > 0 else { return 0 }
        let previous = document.systems[range.lowerBound - 1]
        return Double(previous.origin.y + previous.size.height)
    }
}
