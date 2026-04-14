import Foundation

/// Root of the parsed MuseScore document. C++: `mu::engraving::MasterScore`/`Score`.
public struct Score: Sendable, Equatable {
    public var division: Int
    public var parts: [Part]
    public var staves: [StaffContent]
    public var metaTags: [String: String]

    public init(
        division: Int,
        parts: [Part] = [],
        staves: [StaffContent] = [],
        metaTags: [String: String] = [:]
    ) {
        self.division = division
        self.parts = parts
        self.staves = staves
        self.metaTags = metaTags
    }
}
