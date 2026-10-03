#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// The bar a point falls in, as `LayoutDocument.editingMeasureHit(at:)` answers it.
public struct EditingMeasureHit: Hashable, Sendable {
    /// The staff whose own band holds the point, in the RENDERED document's addressing. A staff-filtered rendition
    /// renumbers it, and the caller re-addresses it exactly as it does `editingHitTest`'s answer.
    public let staff: StaffAddress
    /// Every source bar the drawn bar stands for: the bar itself, or the whole run of a collapsed multi-measure rest.
    /// The layout draws such a run as ONE `LayoutMeasure` numbered after its first bar and carrying the run's length
    /// in `multiMeasureRest`, so this is the only place a point can learn the interior bars are there.
    public let measures: ClosedRange<Int>

    /// The drawn bar's own index, the first of `measures`.
    public var measureIndex: Int {
        measures.lowerBound
    }

    public init(staff: StaffAddress, measures: ClosedRange<Int>) {
        self.staff = staff
        self.measures = measures
    }
}

extension LayoutDocument {
    /// How far outside its own drawn lines a staff still owns a point, in staff spaces.
    ///
    /// The boundary between "this bar" and "nothing" is invisible either way, so the number is a judgement about
    /// which mistake is worse. Reaching too far is worse: the paper above a staff holds lyrics, chord symbols and the
    /// previous system's descenders, and a click there that selects the bar below reads as the app missing the point
    /// (folino user report, 2026-09-12). One staff space allows for a click that meant the top line, and no more.
    static let editingMeasureStaffBandMargin: CGFloat = 1

    /// The bar `point` (document coordinates) lies in: the geometry half of "a tap on empty space inside a bar
    /// selects the bar".
    ///
    /// **Ask `editingHitTest(at:activeVoice:nearMissTolerance:)` first, and this only when it answers nothing.** That
    /// policy answers "which ELEMENT did you mean", with a slop box, and is allowed to answer nothing so that a tap on
    /// empty paper can put an editing pad away. This one asks "which BAR were you inside". Asked first, it would turn
    /// every near miss of a note into a whole-bar selection.
    ///
    /// `nil` when the point is outside every staff's own band (its drawn lines, `editingMeasureStaffBandMargin` staff
    /// spaces clear on each side, measured per staff through `StaffLineGeometry.barLineSpanY(sp:)`), past the last bar
    /// of the system it is level with, or in a system with no staves. Bars are half-open in x
    /// (`origin.x ..< origin.x + width`), so the bars either side of a barline never both claim it.
    ///
    /// Moved from folino's `MeasureHitTest` in 4.2.0 so the Apple and Android editors run one rule, the move
    /// `editingHitTest` made in 1.11.0.
    public func editingMeasureHit(at point: CGPoint) -> EditingMeasureHit? {
        for system in systems {
            let local = CGPoint(x: point.x - system.origin.x, y: point.y - system.origin.y)
            guard let measure = system.measures.first(where: {
                local.x >= $0.origin.x && local.x < $0.origin.x + $0.width
            }) else { continue }
            guard let staff = Self.measureHitStaff(owning: local.y, in: system, sp: metrics.sp) else { continue }
            let run = max(1, measure.multiMeasureRest ?? 1)
            return EditingMeasureHit(staff: staff, measures: measure.measureIndex ... measure.measureIndex + run - 1)
        }
        return nil
    }

    /// The staff of `system` whose own band contains `y` (system-local), or `nil` for paper between or outside them.
    ///
    /// **Containment, not "nearest".** The system box is much taller than its staves, since it holds the space a
    /// title, lyrics, chord symbols and ottava brackets are engraved into. Measured on a single-staff system at
    /// staffSize 14, it ran from 5 sp above the top line to 3 sp below the bottom one. Bands this far apart cannot
    /// normally overlap; the nearest centre settles the tie if two ever do.
    private static func measureHitStaff(owning y: CGFloat, in system: LayoutSystem, sp: CGFloat) -> StaffAddress? {
        var best: (distance: CGFloat, address: StaffAddress)?
        for (flatIndex, origin) in system.staffOrigins.enumerated() {
            guard system.staffAddresses.indices.contains(flatIndex) else { continue }
            let span = system.geometry(atFlatIndex: flatIndex).barLineSpanY(sp: sp)
            let top = origin.y + span.top - editingMeasureStaffBandMargin * sp
            let bottom = origin.y + span.bottom + editingMeasureStaffBandMargin * sp
            guard y >= top, y <= bottom else { continue }
            let distance = abs(y - (top + bottom) / 2)
            if let best, best.distance <= distance { continue }
            best = (distance, system.staffAddresses[flatIndex])
        }
        return best?.address
    }
}
