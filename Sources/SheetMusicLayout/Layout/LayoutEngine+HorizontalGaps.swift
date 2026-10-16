#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// An `<HBox>` is horizontal room inside a system, before the measure it sits before. The room lives in that measure's
/// slot of the widths `packSystems` hands `buildSystem` (and keys the system cache on): every fit test counts it, no
/// stretch scales it (a justified system gives its measures the available width minus the room, as MuseScore's
/// `justifySystem` does), it joins the slot after stretching, and `buildSystem` takes it out again before laying the
/// measure out. Every walk over the measures' x advances by it before the measure.
extension LayoutEngine {
    /// MuseScore's HBox width when `<width>` is absent, in spatium (`box.cpp:593-603`).
    static let defaultHorizontalFrameWidthSp: CGFloat = 5

    /// `RenderContext.horizontalGaps`: the room in points the HBoxes of `score.frameStream` leave before measure `m` —
    /// `(widthSp ?? 5) + (topGapSp ?? 0) + (bottomGapSp ?? 0)` spatium each (MS `box.cpp:71-74`), summed over the boxes
    /// at one index. Only for `m` in `1 ..< measureCount`: before the first measure or after the last there is nothing
    /// to put room between. A box at a collapsed multi-measure-rest run's interior index has no measure of its own and
    /// takes no room; one at the run's start sits before the run. Unlike frames, wrap and horizontal mode both get it.
    static func horizontalGapIndexes(
        score: Score, measureCount: Int, plan: MultiMeasureRestPlan, sp: CGFloat,
    ) -> [Int: CGFloat] {
        var gaps: [Int: CGFloat] = [:]
        for positioned in score.frameStream {
            guard case let .horizontalFrame(frame) = positioned.block else { continue }
            let index = positioned.beforeMeasureIndex
            guard index >= 1, index < measureCount, !plan.isInteriorOfRun(index) else { continue }
            // Each converted before `??`: off Apple Core's `CGFloat?` is Foundation's, not this module's `Double`.
            let widthSp = frame.widthSp.map { CGFloat($0) } ?? defaultHorizontalFrameWidthSp
            let topGapSp = frame.topGapSp.map { CGFloat($0) } ?? 0
            let bottomGapSp = frame.bottomGapSp.map { CGFloat($0) } ?? 0
            let roomSp = widthSp + topGapSp + bottomGapSp
            guard roomSp > 0 else { continue }
            gaps[index, default: 0] += roomSp * sp
        }
        return gaps
    }

    /// The room before `measure` in a system whose first measure is `systemStart`: none for the first measure, which
    /// drops the room of a box before it.
    static func roomBefore(_ measure: Int, systemStart: Int, in gaps: [Int: CGFloat]) -> CGFloat {
        measure > systemStart ? gaps[measure] ?? 0 : 0
    }

    /// The room inside a system that holds `range`: every box's but the one before its first measure, summed in measure
    /// order.
    static func roomInside(_ range: Range<Int>, gaps: [Int: CGFloat]) -> CGFloat {
        guard !gaps.isEmpty else { return 0 }
        return range.dropFirst().reduce(0) { sum, measure in sum + (gaps[measure] ?? 0) }
    }

    /// `widths` — one per measure of the system that starts at `systemStart`, already stretched — with each measure's
    /// room added to its slot. The first slot takes none.
    static func slotsWithRoom(_ widths: [CGFloat], systemStart: Int, gaps: [Int: CGFloat]) -> [CGFloat] {
        guard !gaps.isEmpty else { return widths }
        return widths.indices.map { j in
            widths[j] + roomBefore(systemStart + j, systemStart: systemStart, in: gaps)
        }
    }

    /// Per measure of `range`, the room `buildSystem` advances by before it: its slot minus this is the measure's own
    /// width.
    static func roomsBefore(_ range: Range<Int>, gaps: [Int: CGFloat]) -> [CGFloat] {
        range.map { roomBefore($0, systemStart: range.lowerBound, in: gaps) }
    }

    /// The `LayoutSystem.staffLineGaps` entry for `room` before the measure that starts at `measureX`, `nil` without
    /// room. MuseScore's staff lines belong to measures, so they stop where `previous`'s barline stroke ends — the
    /// `staffLineEndX` rule at a system's end, short of `previous`'s right edge by the gutter after its barline — and
    /// start again at `measureX`. A `previous` that draws no barline gives the room alone.
    static func staffLineGap(
        after previous: LayoutMeasure?, room: CGFloat, endingAt measureX: CGFloat, sp: CGFloat,
    ) -> Range<CGFloat>? {
        guard room > 0 else { return nil }
        let barEnd = previous.flatMap { BarLineGeometry.barLineEndX(of: $0, sp: sp) } ?? measureX - room
        return min(barEnd, measureX) ..< measureX
    }
}
