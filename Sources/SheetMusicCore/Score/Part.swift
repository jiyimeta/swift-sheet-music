import SheetMusicFoundation

/// A score part (one instrument). Owns its staves directly.
/// C++: `mu::engraving::Part`.
public struct Part: Sendable, Equatable {
    public var id: String
    /// The PART name — MuseScore's `<Part><trackName>`, `Part::partName()`: what its Mixer, instrument list and
    /// Parts dialog call the part. Not the instrument's own name, which is `Instrument.trackName`; MuseScore fills an
    /// empty part name from that one. `SetPartNames` keeps it in step with a renamed long name.
    public var trackName: String?
    public var instrument: Instrument
    public var staves: IdentifiedArray<Staff>
    /// Whether this part is shown in the main score. Mirrors MuseScore's
    /// `<Part><show>` flag (C++ `Part::show()`): the "hide instrument in
    /// score" toggle in the Instruments panel. `false` means every staff of
    /// this part should be omitted from the rendered main score (the part is
    /// still present in the model — hosts hide it at display time and can
    /// reveal it). Absent `<show>` or `<show>1</show>` decodes as `true`.
    public var isVisibleInScore: Bool
    /// MuseScore `<Part><hideWhenEmpty>` — whether this part's staves are hidden from a system in which they are
    /// empty: `on` hides them, `off` always shows them, `auto` (the default) follows `ScoreStyle.hideEmptyStaves`. A
    /// staff's own `Staff.hideWhenEmpty` other than `auto` overrides it (`computeHideMode`,
    /// `rendering/score/systemlayout.cpp:572-599`). C++: `Part::hideWhenEmpty()` (`dom/part.h:214`).
    public var hideWhenEmpty: AutoOnOff = .auto
    /// MuseScore `<Part><hideStavesWhenIndividuallyEmpty>` — when the part's staves are hidden, each one goes on its
    /// own once it is empty; false (the default) hides them only together, when the whole part is empty in the
    /// system. C++: `Part::hideStavesWhenIndividuallyEmpty()` (`dom/part.h:217`).
    public var hideStavesWhenIndividuallyEmpty = false
    /// Source markup under this element that the model does not
    /// represent, kept so that read → write does not delete it.
    public var preservedMarkup: [PreservedXML] = []

    public init(
        id: String,
        trackName: String? = nil,
        instrument: Instrument,
        staves: IdentifiedArray<Staff> = [],
        isVisibleInScore: Bool = true,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.id = id
        self.trackName = trackName
        self.instrument = instrument
        self.staves = staves
        self.isVisibleInScore = isVisibleInScore
        self.preservedMarkup = preservedMarkup
    }
}
