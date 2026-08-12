#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

extension LayoutDocument {
    /// Bounding rectangles (document coords) for a loop region spanning
    /// measures `[fromMeasureIndex, toMeasureExclusive)`. Returns one
    /// rect per system whose measures fall in the range: x covers the
    /// included measures' left edges to right edges, y covers every
    /// staff in that system.
    ///
    /// Returns an empty array when the range is empty
    /// (`fromMeasureIndex >= toMeasureExclusive`) or no measure
    /// indices fall in it.
    public func loopHighlightRects(
        fromMeasureIndex: Int,
        toMeasureExclusive: Int,
    ) -> [CGRect] {
        guard fromMeasureIndex < toMeasureExclusive else { return [] }
        var rects: [CGRect] = []
        for system in systems {
            let inRange = system.measures.filter { measure in
                measure.measureIndex >= fromMeasureIndex
                    && measure.measureIndex < toMeasureExclusive
            }
            guard let firstM = inRange.first,
                  let lastM = inRange.last else { continue }
            // Same span as the system's left-edge vertical and the
            // playback cursor — the end staves' drawn extent, with
            // MuseScore's ±2 sp one-line case, rather than the
            // five-line reference height.
            guard let span = system.systemStartBarLine else { continue }
            let topY = system.origin.y + span.top
            let bottomY = system.origin.y + span.bottom
            let xStart = system.origin.x + firstM.origin.x
            let xEnd = system.origin.x + lastM.origin.x + lastM.width
            rects.append(CGRect(
                x: xStart,
                y: topY,
                width: xEnd - xStart,
                height: bottomY - topY,
            ))
        }
        return rects
    }
}
