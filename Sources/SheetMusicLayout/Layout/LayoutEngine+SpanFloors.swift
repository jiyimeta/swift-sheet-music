#if canImport(CoreGraphics)
    import CoreGraphics
#endif

extension LayoutEngine {
    /// Raises the gap floors so each demand has its room over its tick span (`demands`: the span and the width it
    /// needs). A chord symbol needs its width plus its gap over the element it names; a syllable needs the distance to
    /// the next syllable over the columns up to it (`lyricsPairWidth`). A span of one gap takes the whole width as that
    /// gap's floor; a span crossing other columns shares it out by the gaps' weights, so the gaps together reach the
    /// width however the line is stretched or squeezed. A floor binds only where the symbol or syllable would
    /// otherwise run into the next one, so a bar the line stretches stays spaced by its durations.
    static func applySpanFloors(
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
