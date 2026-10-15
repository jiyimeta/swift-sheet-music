#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// The north (above-staff) and south (below-staff) silhouettes of
/// everything already placed on one staff of one system.
///
/// Mirrors `mu::engraving::Skyline` / `SkylineLine`
/// (`src/engraving/infrastructure/skyline.{h,cpp}`). The staff-line
/// filter in `add` is what keeps the rect count small: an element that
/// stays between the outer staff lines cannot push an annotation
/// further away from the staff, so it is never recorded.
///
/// **Each line is indexed by column of X**, so a query reads only the rects that can be near it. Autoplace asks
/// once per element, and a system's skyline holds every rect placed on that staff so far — so measuring every
/// rect each time made the pass grow with the square of the system's length. A horizontally engraved score is one
/// system: on a 508-measure score that was nearly half of laying it out.
public struct Skyline: Sendable {
    /// Rects poking ABOVE `staffTop`, ordered by insertion.
    public private(set) var north: LayoutShape
    /// Rects poking BELOW `staffBottom`, ordered by insertion.
    public private(set) var south: LayoutShape
    public let staffTop: CGFloat
    public let staffBottom: CGFloat
    private var northColumns = SkylineColumns()
    private var southColumns = SkylineColumns()

    public init(staffTop: CGFloat, staffBottom: CGFloat) {
        self.staffTop = staffTop
        self.staffBottom = staffBottom
        north = LayoutShape()
        south = LayoutShape()
    }

    /// Record `shape`, dropping rects that stay inside the staff.
    /// `.staff` rects are exempt — they ARE the reference edges.
    public mutating func add(_ shape: LayoutShape) {
        for r in shape.rects {
            let isStaff = r.item.kind == .staff
            if isStaff || r.rect.minY < staffTop {
                appendNorth(r)
            }
            if isStaff || r.rect.maxY > staffBottom {
                appendSouth(r)
            }
        }
    }

    private mutating func appendNorth(_ r: ShapeRect) {
        northColumns.insert(r.rect, at: north.rects.count)
        north.rects.append(r)
    }

    private mutating func appendSouth(_ r: ShapeRect) {
        southColumns.insert(r.rect, at: south.rects.count)
        south.rects.append(r)
    }

    /// Copy with every rect whose item satisfies `predicate` removed.
    /// Used to drop the rects an item being placed must ignore.
    ///
    /// Mirrors `Skyline::getFilteredCopy`.
    public func filtered(
        ignoring predicate: (ShapeItem) -> Bool,
    ) -> Skyline {
        var copy = Skyline(staffTop: staffTop, staffBottom: staffBottom)
        for r in north.rects where !predicate(r.item) {
            copy.appendNorth(r)
        }
        for r in south.rects where !predicate(r.item) {
            copy.appendSouth(r)
        }
        return copy
    }

    /// How far `shape` — which sits ABOVE the staff — overlaps into the
    /// north skyline. Positive = overlap; negative = clearance;
    /// `-infinity` = no horizontal interaction.
    public func overlapAbove(
        _ shape: LayoutShape, clearance: CGFloat,
    ) -> CGFloat {
        overlapAbove(shape, clearance: clearance) { _ in false }
    }

    /// How far `shape` — which sits BELOW the staff — overlaps into the
    /// south skyline. Same sign convention as `overlapAbove`.
    public func overlapBelow(
        _ shape: LayoutShape, clearance: CGFloat,
    ) -> CGFloat {
        overlapBelow(shape, clearance: clearance) { _ in false }
    }

    /// `overlapAbove(_:clearance:)` against this skyline with the rects whose item satisfies `ignoring` left out —
    /// the answer `filtered(ignoring:)` followed by `overlapAbove` gives, without copying the skyline to get it.
    ///
    /// Exactly `shape.minVerticalDistance(north, minHorizontalClearance:)` over the rects not ignored, with
    /// `shape` the upper side, evaluated by the same comparisons; the columns only decide which rects are worth
    /// comparing, and a rect they skip has no X in common with the query, so it could not have counted.
    func overlapAbove(
        _ shape: LayoutShape, clearance: CGFloat, ignoring: (ShapeItem) -> Bool,
    ) -> CGFloat {
        var result = -CGFloat.infinity
        for upper in shape.rects {
            let a = upper.rect
            northColumns.forEachCandidate(
                near: a.minX - clearance, a.maxX + clearance, count: north.rects.count,
            ) { index in
                let lower = north.rects[index]
                let b = lower.rect
                guard b.maxX >= a.minX - clearance,
                      b.minX <= a.maxX + clearance,
                      !ignoring(lower.item)
                else { return }
                result = max(result, a.maxY - b.minY)
            }
        }
        return result
    }

    /// `overlapBelow(_:clearance:)` with the rects whose item satisfies `ignoring` left out — the counterpart of
    /// `overlapAbove(_:clearance:ignoring:)`, with the south line as the upper side, as in
    /// `south.minVerticalDistance(shape, minHorizontalClearance:)`.
    func overlapBelow(
        _ shape: LayoutShape, clearance: CGFloat, ignoring: (ShapeItem) -> Bool,
    ) -> CGFloat {
        var result = -CGFloat.infinity
        for lower in shape.rects {
            let b = lower.rect
            southColumns.forEachCandidate(
                near: b.minX - clearance, b.maxX + clearance, count: south.rects.count,
            ) { index in
                let upper = south.rects[index]
                let a = upper.rect
                guard b.maxX >= a.minX - clearance,
                      b.minX <= a.maxX + clearance,
                      !ignoring(upper.item)
                else { return }
                result = max(result, a.maxY - b.minY)
            }
        }
        return result
    }
}

/// Which rects of one skyline line cover each column of X.
///
/// A rect is listed under every column its X range touches; a query visits the columns its own range touches,
/// widened by a point so a pair the caller's comparison would accept is never lost to rounding at a column
/// edge. A rect may be visited more than once — the callers take a maximum, which repeats leave unchanged. A rect
/// with no finite X range, or one spanning more columns than `maxColumns`, is visited by every query instead.
struct SkylineColumns: Sendable {
    /// Points of X per column — a few note columns at a typical staff size.
    static let width: CGFloat = 32
    /// Widest rect, in columns, still listed column by column.
    static let maxColumns = 4096

    private var columns: [Int: [Int32]] = [:]
    private var everywhere: [Int32] = []

    mutating func insert(_ rect: CGRect, at index: Int) {
        guard let span = Self.columns(from: rect.minX, to: rect.maxX) else {
            everywhere.append(Int32(index))
            return
        }
        for column in span {
            columns[column, default: []].append(Int32(index))
        }
    }

    /// Calls `body` with the index of every rect that can reach X from `lower` to `upper`, and possibly others.
    /// `count` is how many rects there are, for a query too wide or not finite to answer by column.
    func forEachCandidate(near lower: CGFloat, _ upper: CGFloat, count: Int, _ body: (Int) -> Void) {
        guard let span = Self.columns(from: lower - 1, to: upper + 1) else {
            for index in 0 ..< count {
                body(index)
            }
            return
        }
        for index in everywhere {
            body(Int(index))
        }
        for column in span {
            for index in columns[column] ?? [] {
                body(Int(index))
            }
        }
    }

    private static func columns(from lower: CGFloat, to upper: CGFloat) -> ClosedRange<Int>? {
        // Kept well inside a 32-bit `Int` once divided by `width` — WebAssembly's `Int` is 32 bits, and a
        // conversion that does not fit traps there.
        let bound: CGFloat = 1e9
        guard lower.isFinite, upper.isFinite, lower <= upper, abs(lower) < bound, abs(upper) < bound
        else { return nil }
        let first = Int((lower / width).rounded(.down))
        let last = Int((upper / width).rounded(.down))
        guard last - first < maxColumns else { return nil }
        return first ... last
    }
}
