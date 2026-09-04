import SheetMusicFoundation

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
    /// MuseScore `<StaffType><lines>` — how many staff lines are drawn.
    /// 5 for a standard staff, 1 / 3 for percussion, 6 for TAB.
    /// Valid range 1...16; the MSCX decoder clamps and warns.
    ///
    /// Note this does NOT move noteheads: MuseScore's
    /// `Note::updateRelLine` ignores `StaffType::lines()`, so a note's
    /// position stays anchored to the top line regardless. Only the
    /// staff's drawn height and its ledger-line bounds depend on it.
    public var lineCount: Int
    /// MuseScore `<defaultClef>` (e.g. "G", "F", "PERC"). Layout
    /// engines synthesize the opening clef from this when the first
    /// content measure lacks an explicit `<Clef>`.
    public var defaultClefType: String?
    /// MuseScore `<bracket>` children of `<Staff>`, in document order.
    /// Each item anchors one bracket / brace whose span extends
    /// downward from this staff. Empty by default; callers that need
    /// auto-derivation from instrument family must populate this list
    /// themselves before handing the `Score` to the layout engine.
    public var brackets: [BracketItem]
    public var measures: [Measure]
    /// Source markup inside this staff declaration's `<StaffType>`
    /// that the model does not represent.
    public var staffTypePreservedMarkup: [PreservedXML] = []
    /// Source markup under the staff declaration that the model does
    /// not represent, kept so that read → write does not delete it.
    public var preservedMarkup: [PreservedXML] = []

    public init(
        staffType: String = "stdNormal",
        group: String = "pitched",
        lineCount: Int = 5,
        defaultClefType: String? = nil,
        brackets: [BracketItem] = [],
        measures: [Measure] = [],
        staffTypePreservedMarkup: [PreservedXML] = [],
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.staffType = staffType
        self.group = group
        self.lineCount = lineCount
        self.defaultClefType = defaultClefType
        self.brackets = brackets
        self.measures = measures
        self.staffTypePreservedMarkup = staffTypePreservedMarkup
        self.preservedMarkup = preservedMarkup
    }
}
