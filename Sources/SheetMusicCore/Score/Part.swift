import Foundation

/// A score part (one instrument). C++: `mu::engraving::Part`.
public struct Part: Sendable, Equatable {
    public var id: String
    public var trackName: String?
    public var instrument: Instrument
    public var staffDeclarations: [StaffDeclaration]

    public init(
        id: String,
        trackName: String? = nil,
        instrument: Instrument,
        staffDeclarations: [StaffDeclaration] = []
    ) {
        self.id = id
        self.trackName = trackName
        self.instrument = instrument
        self.staffDeclarations = staffDeclarations
    }
}
