import Foundation

/// A single staff inside a `Part`. Unifies what was previously split
/// across `StaffDeclaration` (rendering hints, defaultClef) and
/// `StaffContent` (measures). Lives nested under its owning `Part`,
/// so order in `Part.staves` defines display order and identity.
///
/// C++: combines `mu::engraving::Staff` and the per-staff measure
/// chain that hangs off `Score`. The mscx file format keeps these
/// physically separated (`<Part><Staff id="N">` declares; top-level
/// `<Staff id="N">` carries measures). They are paired by id in the
/// decoder; the model collapses the split.
public struct Staff: Sendable, Equatable {
    /// MuseScore `<StaffType><name>` (e.g. "stdNormal").
    public var staffType: String
    /// MuseScore `<StaffType group="…">` (e.g. "pitched", "percussion").
    public var group: String
    /// MuseScore `<defaultClef>` (e.g. "G", "F", "PERC"). Layout
    /// engines synthesize the opening clef from this when the first
    /// content measure lacks an explicit `<Clef>`.
    public var defaultClefType: String?
    public var measures: [Measure]

    public init(
        staffType: String = "stdNormal",
        group: String = "pitched",
        defaultClefType: String? = nil,
        measures: [Measure] = []
    ) {
        self.staffType = staffType
        self.group = group
        self.defaultClefType = defaultClefType
        self.measures = measures
    }
}
