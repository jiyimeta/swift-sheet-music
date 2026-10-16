#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

extension LayoutEngine {
    /// A frame-stream box laid out (`originY` still 0), with its gaps in spatium and the index of the system it sits
    /// before (`packed.count` when it trails them all).
    private struct StreamEntry {
        let frame: LayoutFrame
        let topGap: CGFloat?
        let bottomGap: CGFloat?
        let systemIndex: Int
    }

    /// Whether boxes after the title are laid out at all: the switches that gate the title block, in wrap mode only.
    /// Horizontal mode and `includeTitleFrame: false` get no frames and no frame breaks.
    static func laysOutFrames(_ options: ScoreViewOptions) -> Bool {
        options.includeTitleFrame && options.wrapToViewWidth
    }

    /// `RenderContext.frameBreaks`: the measure index every VBox / TBox of `score.frameStream` sits before, when it
    /// falls between two measures (`1 ..< measureCount`). An HBox is room inside a system, not a break, and an opaque
    /// box has no layout.
    static func frameBreakIndexes(
        score: Score, measureCount: Int, plan: MultiMeasureRestPlan, options: ScoreViewOptions,
    ) -> Set<Int> {
        guard laysOutFrames(options) else { return [] }
        var breaks: Set<Int> = []
        for positioned in score.frameStream where gaps(of: positioned.block) != nil {
            let index = streamIndex(positioned.beforeMeasureIndex, plan: plan)
            if index >= 1, index < measureCount { breaks.insert(index) }
        }
        return breaks
    }

    /// A VBox's or TBox's gaps in spatium (`nil` = the 7 sp default); `nil` for the blocks that are not frames.
    ///
    /// Each gap is converted explicitly: on Android and Windows `SheetMusicCore`'s `CGFloat` is Foundation's struct
    /// while this module's is `Double` (`CGTypes+Android.swift`), and the implicit `CGFloat` ↔ `Double` conversion
    /// reaches a bare value but not one inside an optional or a tuple.
    private static func gaps(of block: ScoreBlock) -> (top: CGFloat?, bottom: CGFloat?)? {
        switch block {
        case let .verticalFrame(frame):
            (top: frame.topGapSp.map { CGFloat($0) }, bottom: frame.bottomGapSp.map { CGFloat($0) })
        case let .textFrame(frame):
            (top: frame.topGapSp.map { CGFloat($0) }, bottom: frame.bottomGapSp.map { CGFloat($0) })
        case .horizontalFrame, .opaqueFrame: nil
        }
    }

    /// The measure index a box breaks and attaches at: inside a multi-measure-rest run it moves to the run's start
    /// (the planner does not know about boxes; MuseScore would end the run there instead).
    private static func streamIndex(_ index: Int, plan: MultiMeasureRestPlan) -> Int {
        plan.run(containing: index)?.lowerBound ?? index
    }

    /// The leading box: `buildTitleFrame`'s legacy height (`max(4 sp, <height>, text needs)`), raised to the lowest
    /// bottom of its pictures so a picture taller than the box cannot overlap system 0. The pictures are fitted to the
    /// box as written, like a later VBox's. A title without pictures is `buildTitleFrame` unchanged. Both come back
    /// unshifted: title-local y, music x.
    static func buildTitleBlock(
        source: ScoreFrame,
        style: ScoreStyle,
        metrics: StaffMetrics,
        docWidth: CGFloat,
        pictures: [String: Data],
    ) -> (frame: LayoutTitleFrame, images: [LayoutFrameImage]) {
        let images = layoutImages(
            of: source, pictures: pictures, docWidth: docWidth, fitHeight: source.heightSp * metrics.sp, sp: metrics.sp,
        )
        let imageBottom = images.map(\.rect.maxY).max() ?? 0
        let frame = buildTitleFrame(
            source: source, style: style, metrics: metrics, docWidth: docWidth, minHeight: imageBottom,
        )
        return (frame, images)
    }

    /// `image` moved by `(dx, dy)`.
    static func moved(_ image: LayoutFrameImage, dx: CGFloat, dy: CGFloat) -> LayoutFrameImage {
        LayoutFrameImage(data: image.data, format: image.format, rect: image.rect.offsetBy(dx: dx, dy: dy))
    }

    /// The frame stream (`Score.frameStream`'s VBoxes and TBoxes) laid out against the packed systems: the frames in
    /// final document coordinates, top to bottom, and per packed system the distance it moves down to make room for
    /// them (`FrameStreamPlacer`), on top of the title's shift.
    ///
    /// `title` is the built title block (unshifted; `nil` when there is none or it is not laid out) and `docWidth` the
    /// width its texts were placed against, which the frames share. The placer runs in final coordinates: the title's
    /// bottom is the top margin plus its height, and a packed system's top is its origin moved by the same shift
    /// `layout` gives it (`title.height + topMargin`), so the title's baked distance to system 0 is kept.
    static func frameStream(
        context: RenderContext,
        packed: [LayoutSystem],
        title: LayoutTitleFrame?,
        docWidth: CGFloat,
    ) -> (frames: [LayoutFrame], systemShifts: [CGFloat]) {
        let zeros = [CGFloat](repeating: 0, count: packed.count)
        guard laysOutFrames(context.options) else { return ([], zeros) }
        let entries = streamEntries(context: context, packed: packed, docWidth: docWidth)
        guard !entries.isEmpty else { return ([], zeros) }
        let sp = context.metrics.sp
        let margins = context.options.spacing.margins
        let topMargin = sp * margins.top
        let yShift = (title?.height ?? 0) + topMargin
        // Stream order: the boxes before system `s`, then `s`; the trailing boxes last.
        var items: [FrameStreamPlacer.Item] = []
        var order: [Int] = []
        for systemIndex in 0 ... packed.count {
            for (entryIndex, entry) in entries.enumerated() where entry.systemIndex == systemIndex {
                let kind = FrameStreamPlacer.Item.Kind.frame(
                    topGap: entry.topGap, bottomGap: entry.bottomGap, height: entry.frame.height,
                )
                items.append(FrameStreamPlacer.Item(kind: kind))
                order.append(entryIndex)
            }
            guard systemIndex < packed.count else { continue }
            let system = packed[systemIndex]
            let top = system.origin.y + yShift
            items.append(FrameStreamPlacer.Item(kind: .system(top: top, bottom: top + system.size.height)))
        }
        // Converted explicitly, as in `gaps(of:)`: Core's `CGFloat?` is not this module's off Apple.
        let titleBottomGap = context.score.titleFrame?.bottomGapSp.map { CGFloat($0) }
        let titleEdge = title.map { (bottom: topMargin + $0.height, bottomGap: titleBottomGap) }
        let placed = FrameStreamPlacer.place(title: titleEdge, items: items, sp: sp, top: topMargin)
        let leadingMargin = sp * margins.leading
        let honorsPageBreaks = context.options.breakPolicy != .ignoreAll
        let frames = zip(order, placed.frameOriginY).map { entryIndex, originY in
            finished(entries[entryIndex].frame, originY: originY, dx: leadingMargin, honorsPageBreaks: honorsPageBreaks)
        }
        return (frames, placed.systemShift)
    }

    /// Every VBox / TBox of the frame stream built against `docWidth`, attached to the first packed system whose first
    /// measure is at or after the box's measure index.
    private static func streamEntries(
        context: RenderContext, packed: [LayoutSystem], docWidth: CGFloat,
    ) -> [StreamEntry] {
        let score = context.score
        let firstMeasures = packed.map { $0.measures.first?.measureIndex ?? Int.max }
        return score.frameStream.compactMap { positioned -> StreamEntry? in
            guard let frameGaps = gaps(of: positioned.block),
                  var frame = layoutFrame(
                      positioned.block, style: score.style, metrics: context.metrics, docWidth: docWidth,
                      pictures: score.pictures,
                  )
            else { return nil }
            frame.beforeMeasureIndex = positioned.beforeMeasureIndex
            let index = streamIndex(positioned.beforeMeasureIndex, plan: context.multiMeasureRestPlan)
            let systemIndex = firstMeasures.firstIndex { $0 >= index } ?? packed.count
            return StreamEntry(
                frame: frame, topGap: frameGaps.top, bottomGap: frameGaps.bottom, systemIndex: systemIndex,
            )
        }
    }

    /// `frame` at its final `originY`, its texts and pictures moved right by the leading margin like the title's
    /// (`shift(_:byX:byY:)`); their y stays frame-local. Its page break is kept only when `honorsPageBreaks` (the
    /// layout's break policy is not `.ignoreAll`), so `LayoutFrame.pageBreakAfter` already says whether it counts.
    private static func finished(
        _ frame: LayoutFrame, originY: CGFloat, dx: CGFloat, honorsPageBreaks: Bool,
    ) -> LayoutFrame {
        LayoutFrame(
            kind: frame.kind,
            beforeMeasureIndex: frame.beforeMeasureIndex,
            originY: originY,
            height: frame.height,
            content: shift(frame.content, byX: dx, byY: 0),
            images: dx == 0 ? frame.images : frame.images.map { moved($0, dx: dx, dy: 0) },
            pageBreakAfter: honorsPageBreaks && frame.pageBreakAfter,
        )
    }
}
