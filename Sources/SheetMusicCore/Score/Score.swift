import Foundation

/// Root of the parsed MuseScore document. C++: `mu::engraving::MasterScore`/`Score`.
public struct Score: Sendable, Equatable {
    public var division: Int
    public var parts: [Part]
    public var metaTags: [String: String]
    /// Title block (`<VBox>` in MuseScore) above the first system,
    /// when present.
    public var titleFrame: ScoreFrame?
    /// Subset of MuseScore's `<Style>` block.
    public var style: ScoreStyle
    /// Records the format this score was loaded from. Defaults to
    /// `.unknown` for programmatic construction.
    public var source: ScoreSource

    public init(
        division: Int,
        parts: [Part] = [],
        metaTags: [String: String] = [:],
        titleFrame: ScoreFrame? = nil,
        style: ScoreStyle = .museScoreDefaults,
        source: ScoreSource = .unknown,
    ) {
        self.division = division
        self.parts = parts
        self.metaTags = metaTags
        self.titleFrame = titleFrame
        self.style = style
        self.source = source
    }
}
