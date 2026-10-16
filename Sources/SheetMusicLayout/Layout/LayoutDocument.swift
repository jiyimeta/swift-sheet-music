#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

public struct LayoutDocument: Sendable, Equatable {
    public let size: CGSize
    public let systems: [LayoutSystem]
    public let metrics: StaffMetrics
    /// Resolved title block for the top of the document, when the
    /// score has a leading `<VBox>`. Renderers draw this above the
    /// first system; PDF pagination treats its height as part of
    /// page 1's content budget.
    public let titleFrame: LayoutTitleFrame?
    /// The score's chord-symbol case style (`Score.style.chordSymbolCase`) this document was laid out with. A host that
    /// measures a chord symbol itself (`HarmonyRendering.runs`, `caretOffsets`) must pass this, or it measures a
    /// different string than the one drawn.
    public let chordSymbolCase: ChordSymbolCaseStyle
    /// The boxes after the leading one (`<VBox>` / `<TBox>` between systems), top to bottom, in document coordinates.
    /// Empty for a score with only a title block.
    public let frames: [LayoutFrame]
    /// The leading box's pictures, in document coordinates (margins included, like the texts of `titleFrame`). They
    /// live here because `LayoutTitleFrame` carries no images.
    public let titleImages: [LayoutFrameImage]

    public init(
        size: CGSize,
        systems: [LayoutSystem],
        metrics: StaffMetrics,
        titleFrame: LayoutTitleFrame? = nil,
        chordSymbolCase: ChordSymbolCaseStyle = .museScoreDefaults,
        frames: [LayoutFrame] = [],
        titleImages: [LayoutFrameImage] = [],
    ) {
        self.size = size
        self.systems = systems
        self.metrics = metrics
        self.titleFrame = titleFrame
        self.chordSymbolCase = chordSymbolCase
        self.frames = frames
        self.titleImages = titleImages
    }

    /// The boxes that touch `range` (document y), in order. A box is included when
    /// `originY + height + 1 >= range.lowerBound && originY <= range.upperBound`: the bounds are inclusive and one
    /// point of slack sits below the box, so a renderer mounting what is on screen never drops a box whose edge lies
    /// on the viewport edge.
    public func frames(inDocumentYRange range: Range<CGFloat>) -> [LayoutFrame] {
        frames.filter { $0.originY + $0.height + 1 >= range.lowerBound && $0.originY <= range.upperBound }
    }
}

extension LayoutDocument {
    /// `systems` cut into pages of `pageHeight` points, the frames taken into account: a frame whose `pageBreakAfter`
    /// is set starts a page at the first system below it (not under `.ignoreAll`, as for a measure's page break), and
    /// frames after the last system that do not fit under it get a page of their own, the empty range
    /// `systems.count ..< systems.count`. See `LayoutPaginator.paginate`, which this feeds. Without frames it is
    /// `LayoutPaginator.paginate(systems:pageHeight:policy:)` exactly. Every page-mode caller cuts through here, so the
    /// bridge, wasm, JNI and PDF pages agree on where a frame lands.
    public func paginate(pageHeight: CGFloat, policy: LayoutBreakPolicy) -> [Range<Int>] {
        LayoutPaginator.paginate(systems: systems, pageHeight: pageHeight, policy: policy)
    }

    /// `subdocument(systems:yOffset:isLastPage:)` for a range that is the last page exactly when it ends at the last
    /// system — true of every cut without a frames-only page. A caller walking `paginate(pageHeight:policy:)`'s
    /// ranges passes `isLastPage` itself, or the frames after the last system land on two pages.
    public func subdocument(systems range: Range<Int>, yOffset: CGFloat) -> LayoutDocument {
        subdocument(systems: range, yOffset: yOffset, isLastPage: range.upperBound == systems.count)
    }

    /// A document containing only `systems[range]`, each system's origin shifted by `yOffset` (a negative value lifts
    /// a page's first system to y ≈ 0 so a page-mode renderer can paint page-local coordinates), and the frames that
    /// page holds, shifted the same way: a frame belongs to the page whose first system follows it, so those in
    /// `[pageTop, lastSystemBottom)`, where `pageTop` is the bottom of the system before the range and
    /// `lastSystemBottom` the bottom of its last system — or `.infinity` when `isLastPage`, so the last page takes the
    /// frames after the last system. An empty range (a frames-only page) holds, as the last page, the frames at or
    /// below `pageTop`. `size.height` is the lowest shifted bottom of those systems and frames. `titleFrame` and
    /// `titleImages` are dropped because only the first page carries them, and that page re-attaches both.
    public func subdocument(systems range: Range<Int>, yOffset: CGFloat, isLastPage: Bool) -> LayoutDocument {
        let slice = systems[range].map { $0.movedBy(dy: yOffset) }
        let height = slice.map { $0.origin.y + $0.size.height }.max() ?? 0
        return LayoutDocument(
            size: CGSize(width: size.width, height: height),
            systems: slice,
            metrics: metrics,
            titleFrame: nil,
            chordSymbolCase: chordSymbolCase,
        )
    }
}
