#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// The north (above-staff) and south (below-staff) silhouettes of
/// everything already placed on one staff of one system.
///
/// Mirrors `mu::engraving::Skyline` / `SkylineLine`
/// (`src/engraving/infrastructure/skyline.{h,cpp}`). The staff-line
/// filter in `add` is what keeps the rect count small: an element that
/// stays between the outer staff lines cannot push an annotation
/// further away from the staff, so it is never recorded.
public struct Skyline: Sendable {
    /// Rects poking ABOVE `staffTop`, ordered by insertion.
    public private(set) var north: LayoutShape
    /// Rects poking BELOW `staffBottom`, ordered by insertion.
    public private(set) var south: LayoutShape
    public let staffTop: CGFloat
    public let staffBottom: CGFloat

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
                north.rects.append(r)
            }
            if isStaff || r.rect.maxY > staffBottom {
                south.rects.append(r)
            }
        }
    }

    /// Copy with every rect whose item satisfies `predicate` removed.
    /// Used to drop the rects an item being placed must ignore.
    ///
    /// Mirrors `Skyline::getFilteredCopy`.
    public func filtered(
        ignoring predicate: (ShapeItem) -> Bool,
    ) -> Skyline {
        var copy = Skyline(staffTop: staffTop, staffBottom: staffBottom)
        copy.north = LayoutShape(
            rects: north.rects.filter { !predicate($0.item) },
        )
        copy.south = LayoutShape(
            rects: south.rects.filter { !predicate($0.item) },
        )
        return copy
    }

    /// How far `shape` — which sits ABOVE the staff — overlaps into the
    /// north skyline. Positive = overlap; negative = clearance;
    /// `-infinity` = no horizontal interaction.
    public func overlapAbove(
        _ shape: LayoutShape, clearance: CGFloat,
    ) -> CGFloat {
        shape.minVerticalDistance(north, minHorizontalClearance: clearance)
    }

    /// How far `shape` — which sits BELOW the staff — overlaps into the
    /// south skyline. Same sign convention as `overlapAbove`.
    public func overlapBelow(
        _ shape: LayoutShape, clearance: CGFloat,
    ) -> CGFloat {
        south.minVerticalDistance(shape, minHorizontalClearance: clearance)
    }
}
