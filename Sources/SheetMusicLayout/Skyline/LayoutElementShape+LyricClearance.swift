#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutElementShape {
    /// The established lyric stem/flag reservation, queried only while placing lyric rows.
    /// The main chord skyline predates final stem endpoints and does not reserve flags.
    /// Keep this conservative allowance local to lyrics instead of changing all categories.
    static func lyricStemClearance(
        for element: LayoutElement, id: Int, xOffset: CGFloat, metrics: StaffMetrics,
    ) -> LayoutShape? {
        guard case let .chord(notes, duration, direction, beamOrigin, _, _, beamed, _, extra, hidden, mag) = element,
              !hidden, duration != .whole,
              let top = notes.map(\.origin.y).min(), let bottom = notes.map(\.origin.y).max(),
              let minX = notes.map(\.origin.x).min(), let maxX = notes.map(\.origin.x).max()
        else { return nil }
        let length = metrics.defaultStemLength * mag + extra
        let tip: CGFloat = beamed ? beamOrigin.y : (direction == .up ? top - length : bottom + length)
        let flag = !beamed && direction == .down ? LayoutEngine
            .flagSouthExtent(duration: duration, metrics: metrics) * mag : 0
        let rect = CGRect(
            x: minX + xOffset - metrics.sp * 0.6, y: min(top, tip),
            width: maxX - minX + metrics.sp * 1.2, height: max(bottom, tip + flag) - min(top, tip),
        )
        return LayoutShape(rects: [ShapeRect(rect: rect, item: ShapeItem(kind: .chord, id: id))])
    }
}
