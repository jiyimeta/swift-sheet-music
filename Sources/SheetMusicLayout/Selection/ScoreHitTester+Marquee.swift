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
    /// A zero-size (degenerate) `rect` does not always return empty: `CGRect.intersects(_:)`'s real edge
    /// behavior is three-way, not "requires a non-degenerate intersection" — two non-degenerate operands need
    /// strict overlap, two degenerate operands need exact coincidence, and when exactly one operand is
    /// degenerate the rule is contains-style (min-inclusive, max-exclusive) membership of that single
    /// coordinate in the other's span. So a degenerate query `rect` can still match an item whose bbox spans
    /// that point. See `CGRect.intersects(_:)`'s own doc comment (`CGTypes+Android.swift`) for the full rule.
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

    /// Chord/rest ids whose layout bbox comes within `tolerance` of `point`, **nearest first**.
    ///
    /// The distance is measured to the bbox, not to its centre, and an `EventColumn`'s bbox is already the
    /// element's own hit target expanded by the radius `ScoreHitTester` accepts (`sp * 1.2` about a notehead,
    /// `sp * 1.8 × sp * 2.5` about a rest). So `tolerance` reads as exactly one thing: **how far past an element's
    /// own target a click may miss and still mean it.** A click inside a bbox is distance 0.
    ///
    /// Ties keep visit order — systems top-to-bottom, then `centerX` ascending — so two voices stacked in one
    /// column resolve the way every other ordered query here does.
    ///
    /// Distinct from `itemIDs(in:)`, which answers a rectangle's contents for marquee selection and has no reason
    /// to rank them. Ranking is the whole point here: a near-miss rescue that returns the FIRST item in document
    /// order rather than the closest one reaches left past the element the user was aiming at.
    public func itemIDs(near point: CGPoint, within tolerance: CGFloat) -> [ScoreItemID] {
        guard tolerance >= 0 else { return [] }
        var ranked: [(distance: CGFloat, order: Int, id: ScoreItemID)] = []
        var order = 0
        for system in document.systems {
            let sysMinY = system.origin.y
            let sysMaxY = sysMinY + system.size.height
            guard sysMaxY >= point.y - tolerance,
                  sysMinY <= point.y + tolerance
            else { continue }

            let columns = system.eventColumns
            guard !columns.isEmpty else { continue }
            let local = CGPoint(
                x: point.x - system.origin.x, y: point.y - system.origin.y,
            )
            let tol = system.maxBBoxHalfWidth

            let lo = lowerBoundCenterX(
                columns: columns,
                value: local.x - tolerance - tol,
            )
            let hi = upperBoundCenterX(
                columns: columns,
                value: local.x + tolerance + tol,
            )
            guard lo < hi else { continue }

            for i in lo ..< hi {
                let column = columns[i]
                order += 1
                let distance = Self.distance(from: local, to: column.bbox)
                guard distance <= tolerance else { continue }
                ranked.append((distance, order, column.id))
            }
        }
        return ranked
            .sorted { ($0.distance, $0.order) < ($1.distance, $1.order) }
            .map(\.id)
    }

    /// Euclidean distance from `point` to the nearest edge of `rect`, and 0 for a point inside it. Written from
    /// the per-axis overshoots so a degenerate (zero-width or zero-height) bbox behaves like the segment it is,
    /// rather than falling into `CGRect.intersects`'s three-way edge rule.
    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
