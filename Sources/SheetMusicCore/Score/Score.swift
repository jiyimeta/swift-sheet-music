import Foundation

/// Root of the parsed MuseScore document. C++: `mu::engraving::MasterScore`/`Score`.
public struct Score: Sendable, Equatable {
    public var division: Int
    public var parts: [Part]
    public var staves: [StaffContent]
    public var metaTags: [String: String]
    /// Title block (`<VBox>` in MuseScore) above the first system,
    /// when present. Holds title / subtitle / composer text with
    /// optional explicit offsets. `nil` for scores without a
    /// leading title frame.
    public var titleFrame: ScoreFrame?

    public init(
        division: Int,
        parts: [Part] = [],
        staves: [StaffContent] = [],
        metaTags: [String: String] = [:],
        titleFrame: ScoreFrame? = nil
    ) {
        self.division = division
        self.parts = parts
        self.staves = staves
        self.metaTags = metaTags
        self.titleFrame = titleFrame
    }
}
