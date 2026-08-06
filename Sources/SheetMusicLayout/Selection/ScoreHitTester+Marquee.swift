#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

@available(macOS 15.0, *)
extension ScoreHitTester {
    /// All chord/rest ids whose layout bbox intersects `rect`
    /// (in `LayoutDocument` coords, same space as `hitTest(at:)`).
    /// Result preserves visit order: systems top-to-bottom, then
    /// `EventColumn.centerX` ascending within each system.
    ///
    /// A zero-size rect (zero width or height) always returns
    /// empty because `CGRect.intersects` requires a non-degenerate
    /// intersection. To hit-test a single point use `itemID(at:)`.
    ///
    /// O(systems_intersecting_rect · (log E + k)).
    public func itemIDs(in rect: CGRect) -> [ScoreItemID] {
        var result: [ScoreItemID] = []
        for system in document.systems {
            // Y-band prefilter: a system whose vertical extent
            // doesn't intersect `rect` contributes nothing.
            let sysMinY = system.origin.y
            let sysMaxY = sysMinY + system.size.height
            guard sysMaxY >= rect.minY,
                  sysMinY <= rect.maxY
            else { continue }

            let columns = system.eventColumns
            guard !columns.isEmpty else { continue }
            // Translate query rect into system-relative coords for
            // bbox tests (which are stored system-relative).
            let localRect = rect.offsetBy(
                dx: -system.origin.x, dy: -system.origin.y,
            )
            let tol = system.maxBBoxHalfWidth

            // Binary-search the X window: skip columns whose
            // (centerX + tol) is still left of localRect.minX.
            let lo = lowerBoundCenterX(
                columns: columns,
                value: localRect.minX - tol,
            )
            let hi = upperBoundCenterX(
                columns: columns,
                value: localRect.maxX + tol,
            )
            guard lo < hi else { continue }

            for i in lo ..< hi {
                let col = columns[i]
                if col.bbox.intersects(localRect) {
                    result.append(col.id)
                }
            }
        }
        return result
    }

    /// First index in `columns` whose `centerX >= value`. Returns
    /// `columns.count` if none exists.
    private func lowerBoundCenterX(
        columns: [EventColumn], value: CGFloat,
    ) -> Int {
        var lo = 0
        var hi = columns.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if columns[mid].centerX < value {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// First index in `columns` whose `centerX > value`. Returns
    /// `columns.count` if all are `<= value`.
    private func upperBoundCenterX(
        columns: [EventColumn], value: CGFloat,
    ) -> Int {
        var lo = 0
        var hi = columns.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if columns[mid].centerX <= value {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
