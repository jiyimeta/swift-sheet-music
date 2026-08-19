import SheetMusicCore
import SheetMusicFoundation

extension LayoutDocument {
    /// Document-space reference point for the `(measure, tick, staff)` part of a musical anchor: the x of the tick
    /// column (looked up / interpolated in the measure's `tickColumns`) at the y of the staff's top line, plus the
    /// layout's `sp`. The caller adds the anchor's `dxSp` / `verticalOffsetSp` (× `sp`) to reach the final ink origin.
    /// Returns `nil` when the measure or the staff is absent from this layout (out-of-range index, hidden staff) — the
    /// caller drops anchors that fail to resolve. Inverse: `resolveAnchor(at:)`.
    public func anchorReferencePoint(
        measureIndex: Int,
        tickInMeasure: Int,
        partIndex: Int,
        staffIndexInPart: Int,
    ) -> (point: CGPoint, sp: CGFloat)? {
        let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndexInPart)
        for system in systems {
            guard let measure = system.measures.first(where: { $0.measureIndex == measureIndex }) else {
                continue
            }
            guard let flat = system.flatIndex(for: address), flat < system.staffOrigins.count else {
                return nil
            }
            let localX = Self.measureLocalX(forTick: tickInMeasure, in: measure)
            let point = CGPoint(
                x: system.origin.x + measure.origin.x + localX,
                y: system.origin.y + system.staffOrigins[flat].y,
            )
            return (point, system.sp)
        }
        return nil
    }

    /// Measure-local x for a tick: exact `tickColumns` hit, else linear interpolation between the bracketing columns,
    /// else `0` (measure left edge) when the measure has no timed content. Mirrors the playback cursor's
    /// `beatXInMeasure` bracket logic so anchors and the cursor agree.
    static func measureLocalX(forTick tick: Int, in measure: LayoutMeasure) -> CGFloat {
        let columns = measure.tickColumns
        if let exact = columns[tick] { return exact }
        let sorted = columns.keys.sorted()
        guard let firstTick = sorted.first else { return 0 }
        var leftTick = firstTick
        var rightTick: Int?
        for t in sorted {
            if t <= tick { leftTick = t } else { rightTick = t; break }
        }
        guard let leftX = columns[leftTick] else { return 0 }
        if let rightTick, let rightX = columns[rightTick], rightTick > leftTick {
            let frac = CGFloat(tick - leftTick) / CGFloat(rightTick - leftTick)
            return leftX + frac * (rightX - leftX)
        }
        return leftX
    }
}
