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
    /// is set ends its page — it stays at the bottom of the page it closes, and the page after starts below it at the
    /// first system that follows (not under `.ignoreAll`, as for a measure's page break) — and frames after the last
    /// system that do not fit under it, or that follow a page break closing the last page, get a page of their own,
    /// the empty range `systems.count ..< systems.count`. See `LayoutPaginator.paginate`, which this feeds. Without
    /// frames it is `LayoutPaginator.paginate(systems:pageHeight:policy:)` exactly. Every page-mode caller cuts through
    /// here, and places each page at `pageTop(ofPageStartingAt:)`, so the bridge, wasm, JNI and PDF pages agree on
    /// where a frame lands.
    ///
    /// Pass the `ScoreViewOptions.breakPolicy` this document was laid out with: a frame's page break was resolved at
    /// layout time (`LayoutFrame.pageBreakAfter`), and `pageTop` and `subdocument` read it without a policy, so a
    /// different `policy` here would cut pages they do not place.
    public func paginate(pageHeight: CGFloat, policy: LayoutBreakPolicy) -> [Range<Int>] {
        LayoutPaginator.paginate(
            systems: systems, pageHeight: pageHeight, policy: policy,
            pageBreaksBefore: pageBreakFrameBottoms, trailingFramesBottom: trailingFramesBottom,
        )
    }

    /// Where, in document y, a page whose first system is `systemIndex` starts — the one definition every paginator and
    /// page consumer uses. `0` for the first page. Otherwise the bottom of the system before it, or, when boxes with a
    /// page break (`LayoutFrame.pageBreakAfter`) sit between that system and this one, the lowest bottom of those
    /// boxes: a box with a page break stays at the bottom of the page it closes and the next page starts below it
    /// (MuseScore `pagelayout.cpp:246`). A plain box between the two belongs to the next page and does not move its
    /// top. For `systems.count` — a frames-only last page — the last system's bottom: no system follows the boxes
    /// after it, so no break of theirs applies.
    ///
    /// No policy argument: the layout sets `pageBreakAfter` only when its `ScoreViewOptions.breakPolicy` honors page
    /// breaks, so under `.ignoreAll` every page starts at the previous system's bottom.
    public func pageTop(ofPageStartingAt systemIndex: Int) -> CGFloat {
        guard systemIndex > 0, let previous = systems.prefix(systemIndex).last else { return 0 }
        let previousBottom = previous.origin.y + previous.size.height
        guard let breakBottom = pageBreakFrameBottoms[systemIndex] else { return previousBottom }
        return max(previousBottom, breakBottom)
    }

    /// The index of the first system at or below `frame`'s bottom: the system the frame sits above. `nil` for a frame
    /// after the last system.
    func systemIndex(below frame: LayoutFrame) -> Int? {
        systems.firstIndex { $0.origin.y >= frame.bottom }
    }

    /// The systems a frame's page break starts a page at, each with where that page starts: system index → the lowest
    /// bottom of the frames with `pageBreakAfter` between it and the system before (or the title block, for system 0).
    /// The frames after the last system have no system below them and are not listed.
    package var pageBreakFrameBottoms: [Int: CGFloat] {
        var bottoms: [Int: CGFloat] = [:]
        for frame in frames where frame.pageBreakAfter {
            guard let below = systemIndex(below: frame) else { continue }
            bottoms[below] = max(bottoms[below] ?? frame.bottom, frame.bottom)
        }
        return bottoms
    }

    /// The systems with a frame between them and the system before (or the title block, for system 0).
    package var systemsBelowFrames: Set<Int> {
        Set(frames.compactMap { systemIndex(below: $0) })
    }

    /// The lowest bottom of the frames after the last system; `nil` when none follows it.
    package var trailingFramesBottom: CGFloat? {
        frames.filter { systemIndex(below: $0) == nil }.map(\.bottom).max()
    }

    /// Where the paginated content ends: the last system's bottom, or the lowest frame's when that is lower. Unlike
    /// `size.height` it leaves out the bottom margin, so a document without frames ends at its last system exactly as
    /// it always has. `nil` without systems.
    package var contentBottom: CGFloat? {
        guard let last = systems.last else { return nil }
        let lastBottom = last.origin.y + last.size.height
        guard let lowest = frames.map(\.bottom).max(), lowest > lastBottom else { return lastBottom }
        return lowest
    }

    /// `subdocument(systems:yOffset:isLastPage:)` for a range that is the last page exactly when it ends at the last
    /// system — true of every cut without a frames-only page. A caller walking `paginate(pageHeight:policy:)`'s
    /// ranges passes `isLastPage` itself, or the frames after the last system land on two pages.
    public func subdocument(systems range: Range<Int>, yOffset: CGFloat) -> LayoutDocument {
        subdocument(systems: range, yOffset: yOffset, isLastPage: range.upperBound == systems.count)
    }

    /// A document containing only `systems[range]`, each system's origin shifted by `yOffset` (a negative value lifts
    /// a page's first system to y ≈ 0 so a page-mode renderer can paint page-local coordinates), and the frames that
    /// page holds, shifted the same way: those whose top lies in `[pageTop(range.lowerBound),
    /// pageTop(range.upperBound))` (`pageTop(ofPageStartingAt:)`) — from `-.infinity` for the first page, to
    /// `.infinity` when `isLastPage`, so the last page takes the frames after the last system. A frame between two
    /// pages' systems is therefore on the page below it, unless it carries a page break: then its top lies above the
    /// next page's top (its bottom), and it stays on the page it closes. An empty range (a frames-only page) holds, as
    /// the last page, the frames at or below the last system's bottom. `size.height` is the lowest shifted bottom of
    /// those systems and frames. `titleFrame` and `titleImages` are dropped because only the first page carries them,
    /// and that page re-attaches both.
    public func subdocument(systems range: Range<Int>, yOffset: CGFloat, isLastPage: Bool) -> LayoutDocument {
        let slice = systems[range].map { $0.movedBy(dy: yOffset) }
        // Half-open bands on the frame's top edge: consecutive pages share their boundary (one page's band ends at
        // the next one's `pageTop`), so every frame lands on exactly one page.
        let bandTop = range.lowerBound > 0 ? pageTop(ofPageStartingAt: range.lowerBound) : -CGFloat.infinity
        let bandBottom = isLastPage ? CGFloat.infinity : pageTop(ofPageStartingAt: range.upperBound)
        let carried = frames.filter { $0.originY >= bandTop && $0.originY < bandBottom }.map { frame in
            var moved = frame
            moved.originY += yOffset
            return moved
        }
        let bottoms = slice.map { $0.origin.y + $0.size.height } + carried.map(\.bottom)
        return LayoutDocument(
            size: CGSize(width: size.width, height: bottoms.max() ?? 0),
            systems: slice,
            metrics: metrics,
            titleFrame: nil,
            chordSymbolCase: chordSymbolCase,
            frames: carried,
        )
    }
}
