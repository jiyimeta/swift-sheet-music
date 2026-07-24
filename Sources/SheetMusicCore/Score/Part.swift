import Foundation

/// A score part (one instrument). Owns its staves directly.
/// C++: `mu::engraving::Part`.
public struct Part: Sendable, Equatable {
    public var id: String
    public var trackName: String?
    public var instrument: Instrument
    public var staves: [Staff]
    /// Whether this part is shown in the main score. Mirrors MuseScore's
    /// `<Part><show>` flag (C++ `Part::show()`): the "hide instrument in
    /// score" toggle in the Instruments panel. `false` means every staff of
    /// this part should be omitted from the rendered main score (the part is
    /// still present in the model — hosts hide it at display time and can
    /// reveal it). Absent `<show>` or `<show>1</show>` decodes as `true`.
    public var isVisibleInScore: Bool

    public init(
        id: String,
        trackName: String? = nil,
        instrument: Instrument,
        staves: [Staff] = [],
        isVisibleInScore: Bool = true,
    ) {
        self.id = id
        self.trackName = trackName
        self.instrument = instrument
        self.staves = staves
        self.isVisibleInScore = isVisibleInScore
    }
}
