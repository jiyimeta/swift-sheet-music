/// One measure column captured across every staff of every part, plus its `SystemMeasure` — the unit that
/// `DeleteMeasure` removes and its inverse restores verbatim.
public struct MeasureSlice: Sendable, Equatable {
    /// `staffMeasures[partIndex][staffIndexInPart]`.
    public var staffMeasures: [[Measure]]
    public var systemMeasure: SystemMeasure

    public init(staffMeasures: [[Measure]], systemMeasure: SystemMeasure) {
        self.staffMeasures = staffMeasures
        self.systemMeasure = systemMeasure
    }
}
