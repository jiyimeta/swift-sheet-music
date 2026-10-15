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
}
