import CoreGraphics
import SheetMusicCore

/// Continuous musical position resolved from a document-space point — the inverse of `anchorReferencePoint`. Unlike
/// `nearestCursor`, it never snaps to a playable event and never returns `nil` for empty measures: it yields the
/// nearest tick column (or tick 0 at the measure's left edge in an empty measure) plus the sub-column residual in
/// `dxSp`, and a vertical offset from the staff top in `verticalOffsetSp`. The Reader maps it to a Domain
/// `MusicalAnchor`.
public struct ResolvedAnchor: Hashable, Sendable {
    public let measureIndex: Int
    public let tickInMeasure: Int
    public let partIndex: Int
    public let staffIndexInPart: Int
    public let dxSp: CGFloat
    public let verticalOffsetSp: CGFloat

    public init(
        measureIndex: Int, tickInMeasure: Int, partIndex: Int, staffIndexInPart: Int,
        dxSp: CGFloat, verticalOffsetSp: CGFloat,
    ) {
        self.measureIndex = measureIndex
        self.tickInMeasure = tickInMeasure
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.dxSp = dxSp
        self.verticalOffsetSp = verticalOffsetSp
    }
}

extension LayoutDocument {
    /// Resolve a document-space point to a continuous `ResolvedAnchor`. Picks the nearest system (by y), the staff
    /// whose centerline is nearest (by y), and the nearest measure (by x); snaps the tick to the nearest tick column
    /// and stores the leftover horizontal distance in `dxSp` and the vertical distance from the staff top in
    /// `verticalOffsetSp`. Returns `nil` only when the layout has no systems / staves / measures. Forward:
    /// `anchorReferencePoint(...)`.
    public func resolveAnchor(at point: CGPoint) -> ResolvedAnchor? {
        guard let system = Self.chooseSystem(forY: point.y, in: systems) else { return nil }
        let sp = system.sp
        guard let flat = Self.chooseStaffIndex(forY: point.y, system: system, sp: sp),
              flat < system.staffAddresses.count, flat < system.staffOrigins.count else { return nil }
        let address = system.staffAddresses[flat]
        let staffTopY = system.origin.y + system.staffOrigins[flat].y
        let verticalOffsetSp = sp > 0 ? (point.y - staffTopY) / sp : 0
        guard let measure = Self.chooseMeasure(forX: point.x, system: system) else { return nil }
        let localX = point.x - system.origin.x - measure.origin.x
        let (tick, columnX) = Self.nearestTickColumn(toLocalX: localX, in: measure)
        let dxSp = sp > 0 ? (localX - columnX) / sp : 0
        return ResolvedAnchor(
            measureIndex: measure.measureIndex,
            tickInMeasure: tick,
            partIndex: address.partIndex,
            staffIndexInPart: address.staffIndexInPart,
            dxSp: dxSp,
            verticalOffsetSp: verticalOffsetSp,
        )
    }

    /// Tick column whose x is nearest `localX`; `(0, 0)` for an empty measure (anchor at the measure left edge).
    static func nearestTickColumn(
        toLocalX localX: CGFloat, in measure: LayoutMeasure,
    ) -> (tick: Int, columnX: CGFloat) {
        var best: (tick: Int, columnX: CGFloat, d: CGFloat)?
        for (tick, columnX) in measure.tickColumns {
            let d = abs(columnX - localX)
            if best.map({ d < $0.d }) ?? true { best = (tick, columnX, d) }
        }
        if let best { return (best.tick, best.columnX) }
        return (0, 0)
    }

    /// Selection helpers mirror NearestCursor.swift (scoped as static methods to avoid touching that file).
    static func chooseSystem(forY y: CGFloat, in systems: [LayoutSystem]) -> LayoutSystem? {
        guard !systems.isEmpty else { return nil }
        if let containing = systems.first(where: { y >= $0.origin.y && y <= $0.origin.y + $0.size.height }) {
            return containing
        }
        return systems.min { systemVerticalDistance(y, $0) < systemVerticalDistance(y, $1) }
    }

    static func systemVerticalDistance(_ y: CGFloat, _ system: LayoutSystem) -> CGFloat {
        if y < system.origin.y { return system.origin.y - y }
        let bottom = system.origin.y + system.size.height
        if y > bottom { return y - bottom }
        return 0
    }

    static func chooseStaffIndex(forY y: CGFloat, system: LayoutSystem, sp: CGFloat) -> Int? {
        guard !system.staffOrigins.isEmpty else { return nil }
        return system.staffOrigins.indices.min { lhs, rhs in
            let midL = system.origin.y + system.staffOrigins[lhs].y + 2 * sp
            let midR = system.origin.y + system.staffOrigins[rhs].y + 2 * sp
            return abs(y - midL) < abs(y - midR)
        }
    }

    static func chooseMeasure(forX x: CGFloat, system: LayoutSystem) -> LayoutMeasure? {
        guard !system.measures.isEmpty else { return nil }
        if let containing = system.measures.first(where: { measure in
            let lo = system.origin.x + measure.origin.x
            return x >= lo && x <= lo + measure.width
        }) {
            return containing
        }
        return system.measures.min {
            measureHorizontalDistance(x, system, $0) < measureHorizontalDistance(x, system, $1)
        }
    }

    static func measureHorizontalDistance(_ x: CGFloat, _ system: LayoutSystem, _ measure: LayoutMeasure) -> CGFloat {
        let lo = system.origin.x + measure.origin.x
        let hi = lo + measure.width
        if x < lo { return lo - x }
        if x > hi { return x - hi }
        return 0
    }
}
