/// One measure column captured across every staff of every part, plus its `SystemMeasure` — the unit that
/// `DeleteMeasure` removes and its inverse restores verbatim.
struct MeasureSlice: Sendable, Equatable {
    /// `staffMeasures[partIndex][staffIndexInPart]`.
    var staffMeasures: [[Measure]]
    var systemMeasure: SystemMeasure
    /// The captured column's identity. Nil means no source column existed, or this is a new
    /// planned column whose identity will be minted only if it is inserted into the system lane.
    var systemMeasureEID: EID?

    /// Unlike the synthesized initializer, this requires an explicit systemMeasureEID argument,
    /// including nil: optional stored properties otherwise gain an implicit nil default.
    init( // swiftlint:disable:this unneeded_synthesized_initializer
        staffMeasures: [[Measure]], systemMeasure: SystemMeasure, systemMeasureEID: EID?,
    ) {
        self.staffMeasures = staffMeasures
        self.systemMeasure = systemMeasure
        self.systemMeasureEID = systemMeasureEID
    }
}
