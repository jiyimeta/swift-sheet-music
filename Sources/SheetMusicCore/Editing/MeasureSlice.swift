/// One measure column captured across every staff of every part, plus its `SystemMeasure` — the unit that
/// `DeleteMeasure` removes and its inverse restores verbatim.
struct MeasureSlice: Sendable, Equatable {
    /// `staffMeasures[partIndex][staffIndexInPart]`.
    var staffMeasures: [[Measure]]
    var systemMeasure: SystemMeasure
}
