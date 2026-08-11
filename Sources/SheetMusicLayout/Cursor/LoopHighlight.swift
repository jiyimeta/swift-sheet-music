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
            let topY = system.origin.y
                + (system.staffOrigins.first?.y ?? 0)
            // The band ends at the LAST staff's own bottom line, not at
            // the five-line reference height — over a one-line
            // percussion staff the reference overshoots by 4 sp.
            let bottomY = system.origin.y + system.staffStackBottomY
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
