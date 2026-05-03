import Foundation

/// A score part (one instrument). Owns its staves directly.
/// C++: `mu::engraving::Part`.
public struct Part: Sendable, Equatable {
    public var id: String
    public var trackName: String?
    public var instrument: Instrument
    public var staves: [Staff]

    public init(
        id: String,
        trackName: String? = nil,
        instrument: Instrument,
        staves: [Staff] = []
    ) {
        self.id = id
        self.trackName = trackName
        self.instrument = instrument
        self.staves = staves
    }
}
