#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

extension LayoutEngine {
    /// Where a figure's continuation lines end (`TLayout::layoutLines`, `tlayout.cpp:2078-2180`): 1.5 sp past the
    /// last chord or rest that starts within the figure's printed length, here within its measure; with no length,
    /// 3 sp past the figure's own column.
    static func figuredBassLineEnd(
        _ figuredBass: FiguredBass, tick: Int, columnX: CGFloat, division: Int, tickColumns: [Int: CGFloat],
        sp: CGFloat,
    ) -> CGFloat {
        guard let length = figuredBass.ticks else { return columnX + 3 * sp }
        let end = tick + length.ticks(division: division)
        let last = tickColumns.keys.filter { $0 >= tick && $0 < end }.max()
        return (last.flatMap { tickColumns[$0] } ?? columnX) + 1.5 * sp
    }

    /// MuseScore lays a figure out at `figuredBassYOffset` whatever its placement and lets autoplace carry one placed
    /// above over the staff (`Autoplace::autoplaceSegmentElement`). Here it starts `figuredBassMinDistance` (0.5 sp)
    /// above the top line on the above side, and the skyline pass clears it from the staff and anything higher, as it
    /// does a text above — a space above the top line over an empty staff, where MuseScore 4.7 draws it too. One below
    /// stays where it was laid out, autoplace off.
    static func placedFiguredBass(
        _ figure: LayoutFigure, _ figuredBass: FiguredBass, staffTopY: CGFloat, sp: CGFloat,
    ) -> (LayoutFigure, TextPlacementMetadata) {
        guard figuredBass.elementProperties.placement == .above, !figure.ink.isEmpty else {
            return (figure, TextPlacementMetadata(side: .below, autoplace: false))
        }
        let lifted = figure.translated(dx: 0, dy: staffTopY - 0.5 * sp - figure.ink.maxY)
        return (lifted, TextPlacementMetadata(side: .above, autoplace: figuredBass.elementProperties.autoplace ?? true))
    }
}
