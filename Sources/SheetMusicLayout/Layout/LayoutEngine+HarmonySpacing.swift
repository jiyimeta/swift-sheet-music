#if canImport(CoreGraphics)
    import CoreGraphics
#endif

extension LayoutEngine {
    /// Raises the gap floors so each chord symbol has its room over the element it names (`demands`: that element's
    /// tick span and the symbol's width plus its gap). A span of one gap takes the whole width as that gap's floor; a
    /// span crossing other voices' columns shares it out by the gaps' weights, so the gaps together reach the width
    /// however the line is stretched or squeezed. A floor binds only where the symbol would otherwise run into the
    /// next one, so a bar the line stretches stays spaced by its durations.
    static func applyHarmonyFloors(
        _ demands: [(startTick: Int, endTick: Int, width: CGFloat)], sortedTicks: [Int], gapWeights: [CGFloat],
        to gapFloors: inout [CGFloat],
    ) {
        for demand in demands {
            let span = sortedTicks.indices.filter {
                sortedTicks[$0] >= demand.startTick && sortedTicks[$0] < demand.endTick
            }
            guard !span.isEmpty else { continue }
            let spanWeight = span.reduce(0) { $0 + gapWeights[$1] }
            for index in span {
                let share = spanWeight > 0 ? gapWeights[index] / spanWeight : 1 / CGFloat(span.count)
                gapFloors[index] = max(gapFloors[index], demand.width * share)
            }
        }
    }
}
