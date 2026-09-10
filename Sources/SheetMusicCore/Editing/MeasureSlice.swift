/// One measure column captured across every staff of every part, plus its `SystemMeasure` — the unit that
/// `DeleteMeasure` removes and its inverse restores verbatim.
struct MeasureSlice: Sendable, Equatable {
    /// `staffMeasures[partIndex][staffIndexInPart]`.
    var staffMeasures: [[Measure]]
    var systemMeasure: SystemMeasure
    /// The captured column's identity, or, for a planned column, the identity of the old column in its run that
    /// it takes over. Nil means the run grew past its old count or no source column existed; whoever inserts the
    /// column into the system lane mints one.
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
