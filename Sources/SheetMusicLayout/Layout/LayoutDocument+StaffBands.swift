#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// One staff's horizontal band in one system — the area a host shades to mark a staff as "mine".
public struct StaffBand: Sendable, Equatable {
    /// The staff, in the addressing of the score the document was laid out from.
    public let staff: StaffAddress
    /// In document coordinates.
    public let rect: CGRect

    public init(staff: StaffAddress, rect: CGRect) {
        self.staff = staff
        self.rect = rect
    }
}

extension LayoutDocument {
    /// Every staff's bands, system by system in display order: one over each run of the staff's lines
    /// (`BarLineGeometry.staffLineSegments(for:startX:staffEndX:)`) — from the staff's start to the end of the
    /// system's staff lines, broken where an `<HBox>`'s room breaks the lines, as MuseScore draws no highlight in a
    /// box — and vertically over the staff's barline span — its lines, or ±2 sp about a one-line staff's single line —
    /// widened by `verticalPaddingSp` staff spaces above and below. A band with no area is left out.
    ///
    /// The one implementation of the band math, so every host shades the same rectangles: a host keeps the bands
    /// whose `staff` it highlights and fills them in its own color.
    public func staffBands(verticalPaddingSp: CGFloat) -> [StaffBand] {
        let sp = metrics.sp
        let padding = sp * verticalPaddingSp
        var bands: [StaffBand] = []
        for system in systems {
            let endX = BarLineGeometry.staffLineEndX(for: system)
            for (index, address) in system.staffAddresses.enumerated() {
                guard system.staffOrigins.indices.contains(index) else { continue }
                let start = system.staffOrigins[index]
                let span = system.geometry(atFlatIndex: index).barLineSpanY(sp: sp)
                for run in BarLineGeometry.staffLineSegments(for: system, startX: start.x, staffEndX: endX) {
                    let rect = CGRect(
                        x: system.origin.x + run.lowerBound,
                        y: system.origin.y + start.y + span.top - padding,
                        width: run.upperBound - run.lowerBound,
                        height: span.bottom - span.top + 2 * padding,
                    )
                    guard rect.width > 0, rect.height > 0 else { continue }
                    bands.append(StaffBand(staff: address, rect: rect))
                }
            }
        }
        return bands
    }
}
